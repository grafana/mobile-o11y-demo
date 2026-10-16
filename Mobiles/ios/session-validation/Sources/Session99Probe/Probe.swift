import Foundation
import GrafanaOpenTelemetryIOS
import OpenTelemetryApi
import Sessions
#if canImport(UIKit)
  import UIKit
#endif

private func argument(_ name: String) -> String {
  let args = ProcessInfo.processInfo.arguments
  guard let index = args.firstIndex(of: name), index + 1 < args.count else {
    fatalError("Missing argument \(name)")
  }
  return args[index + 1]
}

private final class ProbeSampler: SessionSampler, @unchecked Sendable {
  private let lock = NSLock()
  private var decision: Bool
  private var count = 0
  init(_ sampled: Bool) {
    decision = sampled
  }

  var calls: Int {
    lock.withLock { count }
  }

  func set(_ sampled: Bool) {
    lock.withLock { decision = sampled }
  }

  func samplingDecision(for _: String) -> SessionSamplingDecision {
    lock.withLock {
      count += 1
      return decision ? .sampled : .notSampled
    }
  }
}

#if !canImport(UIKit)
  @main
#endif
enum Probe {
  private static func clearTestSession() {
    // This executable has its own defaults domain; never clear an application's domain.
    for suffix in ["record", "id", "previous-id", "expire-time", "start-time", "timeout", "max-lifetime"] {
      UserDefaults.standard.removeObject(forKey: "otel-session-" + suffix)
    }
    UserDefaults.standard.synchronize()
  }

  static func main() throws {
    try run()
    dispatchMain()
  }

  static func run() throws {
    if argument("--clean") == "true" {
      clearTestSession()
    }
    let sampler = ProbeSampler(argument("--sampled") == "true")
    let buffered = argument("--buffered") == "true"
    let config = try GrafanaOtelConfiguration(
      otlpEndpoint: URL(string: argument("--collector"))!, firstPartyHosts: ["127.0.0.1"],
      resourceAttributes: ["service.name": "varanha-session99", "probe.run": argument("--run")],
      sessionInactivityTimeout: Double(argument("--timeout"))!,
      sessionMaxLifetime: Double(argument("--lifetime"))!,
      restorePersistedSession: argument("--restore") == "true",
      diskBuffering: buffered ? .enabled(storageURL: URL(fileURLWithPath: argument("--storage"))) : .disabled,
      instrumentation: .init(metricKitDiagnostics: false)
    )
    let runtime = try GrafanaOtel.initialize(
      configuration: config, experimental: .init(sessionSampler: sampler)
    )
    let backend = argument("--backend")
    let commands = ProcessInfo.processInfo.arguments.contains("--commands") ? argument("--commands") : nil
    DispatchQueue.global().async {
      let manager = SessionManagerProvider.getInstance()
      let tracer = runtime.openTelemetry.tracerProvider.get(instrumentationName: "session99")
      let logger = runtime.openTelemetry.loggerProvider.get(instrumentationScopeName: "session99")
      var held: Span?
      var sequence = 0
      func nextLine() -> String? {
        guard let commands else { return readLine() }
        let file = URL(fileURLWithPath: commands).appendingPathComponent("\(sequence).json")
        while !FileManager.default.fileExists(atPath: file.path) { Thread.sleep(forTimeInterval: 0.05) }
        sequence += 1
        return try! String(contentsOf: file, encoding: .utf8)
      }
      while let line = nextLine() {
        do {
          let command = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
          let op = command["op"] as! String
          let name = command["name"] as? String ?? op
          switch op {
          case "emit":
            tracer.spanBuilder(spanName: name).startSpan().end()
            logger.logRecordBuilder().setBody(.string(name)).emit()
            let done = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: URL(string: backend + "/" + name)!) { _, response, error in
              precondition(error == nil && (response as? HTTPURLResponse)?.statusCode == 200)
              done.signal()
            }.resume()
            precondition(done.wait(timeout: .now() + 10) == .success)
          case "reset":
            sampler.set(command["sampled"] as! Bool)
            manager.resetSession()
          case "hold":
            held = tracer.spanBuilder(spanName: name).startSpan()
          case "endHeld":
            held?.end()
            held = nil
          case "delayed":
            let saved = command["snapshot"] as! [String: Any]
            var attrs: [String: AttributeValue] = [
              SemanticConventions.Session.id.rawValue: .string(saved["id"] as! String),
              SessionConstants.sessionSamplingDecision: .string(saved["decision"] as! String)
            ]
            if let previous = saved["previous"] as? String {
              attrs[SemanticConventions.Session.previousId.rawValue] = .string(previous)
            }
            logger.logRecordBuilder().setBody(.string(name)).setAttributes(attrs).emit()
          case "flush":
            runtime.forceFlush(timeout: 2)
          case "shutdown":
            runtime.shutdown(timeout: 2)
          case "snapshot": break
          default: fatalError("Unknown operation \(op)")
          }
          let session = manager.getSession()
          let result: [String: Any] = [
            "id": session.id, "previous": session.previousId as Any? ?? NSNull(),
            "decision": session.samplingDecision.rawValue, "calls": sampler.calls,
            "pid": ProcessInfo.processInfo.processIdentifier, "op": op, "run": argument("--run")
          ]
          let encoded = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
          if let commands {
            try encoded.write(to: URL(fileURLWithPath: commands).appendingPathComponent("\(sequence - 1).result"), options: .atomic)
          }
          print("RESULT " + String(decoding: encoded, as: UTF8.self))
          fflush(stdout)
          if op == "shutdown" {
            UserDefaults.standard.synchronize()
            if command["clean"] as? Bool == true {
              clearTestSession()
            }
            exit(0)
          }
        } catch {
          fatalError("Probe failed: \(error)")
        }
      }
      runtime.shutdown(timeout: 2)
      exit(1)
    }
  }
}

#if canImport(UIKit)
  @main
  final class ProbeApp: UIResponder, UIApplicationDelegate {
    func application(_: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
      do { try Probe.run() } catch { fatalError("Probe startup failed: \(error)") }
      return true
    }

    func application(_: UIApplication, configurationForConnecting session: UISceneSession,
                     options _: UIScene.ConnectionOptions) -> UISceneConfiguration {
      let configuration = UISceneConfiguration(name: "Validation", sessionRole: session.role)
      configuration.delegateClass = ProbeScene.self
      return configuration
    }
  }

  final class ProbeScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo _: UISceneSession, options _: UIScene.ConnectionOptions) {
      guard let scene = scene as? UIWindowScene else { return }
      let window = UIWindow(windowScene: scene)
      let controller = UIViewController()
      controller.view.backgroundColor = .systemBackground
      window.rootViewController = controller
      window.makeKeyAndVisible()
      self.window = window
    }
  }
#endif
