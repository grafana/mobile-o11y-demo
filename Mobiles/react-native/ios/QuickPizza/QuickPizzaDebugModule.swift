import Darwin
import Foundation
import React

@objc(QuickPizzaDebug)
class QuickPizzaDebug: NSObject {
  @objc
  static func requiresMainQueueSetup() -> Bool {
    false
  }

  /// Blocks the main run loop for demo frozen-frame injection (Faro CADisplayLink).
  @objc(blockMainThread:resolver:rejecter:)
  func blockMainThread(
    _ durationMs: NSNumber,
    resolver resolve: @escaping RCTPromiseResolveBlock,
    rejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    let clampedMs = min(max(durationMs.doubleValue, 1), 10_000)
    DispatchQueue.main.async {
      let deadline = Date().addingTimeInterval(clampedMs / 1000.0)
      while Date() < deadline {
        sched_yield()
      }
      resolve(nil)
    }
  }
}
