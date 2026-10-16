import Foundation

struct GroupRequest: Codable {
  let run: String
  let restore: Bool
  let sampled: Bool
  let resets: Int
}

struct GroupSnapshot: Codable, Equatable {
  let id: String
  let previous: String?
  let decision: String
}

struct GroupResult: Codable {
  let role: String
  let pid: Int32
  let bundle: String
  let group: String
  let container: String
  let initial: GroupSnapshot
  let final: GroupSnapshot
  let samplerCalls: Int
  let resets: Int
  let began: TimeInterval
  let ended: TimeInterval
  let sharedRejected: Bool
}
