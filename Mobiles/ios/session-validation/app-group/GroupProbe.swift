import Foundation
import Sessions

extension GroupSnapshot {
  init(_ session: Session) {
    id = session.id
    previous = session.previousId
    decision = session.samplingDecision.rawValue
  }
}

private final class CountingSampler: SessionSampler, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  let sampled: Bool
  init(sampled: Bool) {
    self.sampled = sampled
  }

  var calls: Int {
    lock.withLock { count }
  }

  func samplingDecision(for _: String) -> SessionSamplingDecision {
    lock.withLock { count += 1 }
    return sampled ? .sampled : .notSampled
  }
}

enum ProbeFailure: Error {
  case invalidRequest, unavailableContainer, badHandshake, timeout, brokenChain, persistenceMismatch, sharedAccepted
}

final class GroupProbe {
  let request: GroupRequest
  let role: String
  let directory: URL
  let group: String
  private let defaults: UserDefaults
  private let persistence: UserDefaultsSessionPersistence
  private let manager: SessionManager
  private let sampler: CountingSampler
  private let initial: GroupSnapshot

  init(request: GroupRequest, role: String) throws {
    guard UUID(uuidString: request.run) != nil, (0 ... 100).contains(request.resets),
          ["app", "extension"].contains(role) else { throw ProbeFailure.invalidRequest }
    guard let group = Bundle.main.object(forInfoDictionaryKey: "Session99AppGroup") as? String,
          let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group),
          let defaults = UserDefaults(suiteName: group) else { throw ProbeFailure.unavailableContainer }
    self.group = group
    self.defaults = defaults
    self.request = request
    self.role = role
    directory = container.appendingPathComponent("session99-" + request.run, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    persistence = UserDefaultsSessionPersistence(userDefaults: defaults, namespace: "session99-\(request.run)-\(role)")
    sampler = CountingSampler(sampled: request.sampled)
    manager = try SessionManager(configuration: SessionConfig(sessionTimeout: 900, maxLifetime: 14400,
                                                              restorePersistedSession: request.restore, sampler: sampler), persistence: persistence, persistenceAccess: .exclusive)
    initial = GroupSnapshot(manager.getSession())
  }

  func write<T: Encodable>(_ value: T, name: String) throws {
    try JSONEncoder().encode(value).write(to: directory.appendingPathComponent(name), options: .atomic)
  }

  func read<T: Decodable>(_ type: T.Type, name: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(contentsOf: directory.appendingPathComponent(name)))
  }

  func awaitFile(_ name: String) throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 20
    while !FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
      guard ProcessInfo.processInfo.systemUptime < deadline else { throw ProbeFailure.timeout }
      Thread.sleep(forTimeInterval: 0.02)
    }
  }

  func run() throws -> GroupResult {
    // Each process writes only its own namespace. The files coordinate the test, not SDK ownership.
    if role == "extension" {
      guard try read(String.self, name: "host-token.json") == request.run else { throw ProbeFailure.badHandshake }
      try write(request.run, name: "extension-ready.json")
      try awaitFile("start.json")
    } else {
      try awaitFile("extension-ready.json")
      guard try read(String.self, name: "extension-ready.json") == request.run else { throw ProbeFailure.badHandshake }
      try write(ProcessInfo.processInfo.systemUptime + 0.3, name: "start.json")
    }
    let start = try read(TimeInterval.self, name: "start.json")
    while ProcessInfo.processInfo.systemUptime < start {
      Thread.sleep(forTimeInterval: 0.005)
    }
    let began = ProcessInfo.processInfo.systemUptime
    var previous = manager.getSession()
    for _ in 0 ..< request.resets {
      let next = manager.resetSession()
      guard next.previousId == previous.id, next.id != previous.id else { throw ProbeFailure.brokenChain }
      previous = next
      Thread.sleep(forTimeInterval: 0.01)
    }
    let ended = ProcessInfo.processInfo.systemUptime
    let before = persistence.read()
    do {
      _ = try SessionManager(persistence: persistence, persistenceAccess: .shared)
      throw ProbeFailure.sharedAccepted
    } catch SessionPersistenceConfigurationError.concurrentWritersUnsupported {}
    guard before != nil, before == persistence.read() else { throw ProbeFailure.persistenceMismatch }
    // This is a controlled persistence test, not a power-loss durability claim.
    defaults.synchronize()
    let result = GroupResult(role: role, pid: ProcessInfo.processInfo.processIdentifier,
                             bundle: Bundle.main.bundleIdentifier ?? "", group: group, container: directory.deletingLastPathComponent().path,
                             initial: initial, final: GroupSnapshot(previous), samplerCalls: sampler.calls, resets: request.resets,
                             began: began, ended: ended, sharedRejected: true)
    try write(result, name: "\(role)-result.json")
    return result
  }
}
