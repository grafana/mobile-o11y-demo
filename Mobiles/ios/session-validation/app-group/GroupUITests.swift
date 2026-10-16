import XCTest

final class GroupUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  private enum DiscoveryFailure: Error { case unavailable, cannotDismiss }

  private func dismissShareSheet(_ app: XCUIApplication) throws {
    let done = app.navigationBars["Apps"].buttons["Done"]
    if done.exists, done.isHittable {
      done.tap()
    }
    for name in ["Close", "Cancel"] {
      let button = app.buttons[name].firstMatch
      if button.exists, button.isHittable {
        button.tap()
        return
      }
    }
    let dismiss = app.otherElements["PopoverDismissRegion"]
    if dismiss.exists {
      // Avoid the popover itself, which can cover the center of the dismiss region.
      dismiss.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
      return
    }
    let sheet = app.otherElements["ActivityListView"]
    guard sheet.exists else { throw DiscoveryFailure.cannotDismiss }
    sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05))
      .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
  }

  private func selectExtension(_ app: XCUIApplication, forceMore: Bool = false,
                               retryFirstMatch: Bool = false) throws
  {
    let deadline = ProcessInfo.processInfo.systemUptime + 45
    for attempt in 0 ..< 3 {
      var openedMore = false
      for _ in 0 ..< 12 {
        guard ProcessInfo.processInfo.systemUptime < deadline else { break }
        let share = openedMore ? app.tables.staticTexts["Session 99 Groups"].firstMatch
          : app.cells["Session 99 Groups"].firstMatch
        if !forceMore || openedMore, share.exists, share.isHittable {
          // Exercise the retry branch without depending on OS registration timing.
          if retryFirstMatch, attempt == 0 {
            break
          }
          share.tap()
          return
        }
        let more = app.cells["More"].firstMatch
        if !openedMore, more.exists, more.isHittable {
          more.tap()
          openedMore = true
        } else if openedMore {
          // The extension can also be below the fold in the full Apps list.
          let list = app.tables.firstMatch
          if list.waitForExistence(timeout: 2) {
            list.swipeUp()
          }
        } else {
          let row = app.scrollViews.containing(.cell, identifier: "shareCell").firstMatch
          if row.waitForExistence(timeout: 2) {
            // Remote share-sheet rows can report an empty visible frame to swipeLeft().
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
              .press(forDuration: 0.1, thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)))
          }
        }
      }
      if attempt < 2, ProcessInfo.processInfo.systemUptime < deadline {
        try dismissShareSheet(app)
        let open = app.buttons["open-extension"]
        guard open.wait(for: \.isHittable, toEqual: true, timeout: 5), open.isEnabled else { break }
        open.tap()
      }
    }
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "extension-discovery-failed"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
    throw DiscoveryFailure.unavailable
  }

  private func exercise(run: String, restore: Bool, sampled: Bool, resets: Int,
                        exerciseDiscovery: Bool = false) throws -> [GroupResult]
  {
    let app = XCUIApplication()
    app.launchEnvironment = [
      "SESSION99_RUN": run,
      "SESSION99_RESTORE": String(restore),
      "SESSION99_SAMPLED": String(sampled),
      "SESSION99_RESETS": String(resets),
      "SESSION99_SHARE_FILLERS": String(exerciseDiscovery),
    ]
    app.launch()
    defer { app.terminate() }
    app.buttons["open-extension"].tap()
    let output = app.textViews["group-status"]
    XCTAssertFalse((output.value as? String)?.hasPrefix("ERROR:") == true, String(describing: output.value))
    if exerciseDiscovery {
      XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 5))
      let more = app.cells["More"].firstMatch
      XCTAssertFalse(more.exists && more.isHittable, "Fixture must put More off-screen")
    }
    try selectExtension(app, forceMore: exerciseDiscovery, retryFirstMatch: exerciseDiscovery)
    let done = app.buttons["extension-done"]
    XCTAssertTrue(done.waitForExistence(timeout: 10))
    let status = app.staticTexts["extension-status"]
    let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", "Running"), object: status)
    XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 25), .completed)
    XCTAssertEqual(status.label, "Passed")
    done.tap()
    let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      let value = output.value as? String ?? ""
      return value.hasPrefix("[") || value.hasPrefix("ERROR:")
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
    let text = try XCTUnwrap(output.value as? String)
    let attachment = XCTAttachment(string: text)
    attachment.name = "app-extension-results-restore-\(restore)-sampled-\(sampled)"
    attachment.lifetime = .keepAlways
    add(attachment)
    let rows = try JSONDecoder().decode([GroupResult].self, from: Data(text.utf8))
    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(rows.map(\.role), ["app", "extension"])
    XCTAssertNotEqual(rows[0].pid, rows[1].pid)
    XCTAssertNotEqual(rows[0].bundle, rows[1].bundle)
    XCTAssertFalse(rows[0].container.isEmpty)
    XCTAssertEqual(rows[0].container, rows[1].container)
    XCTAssertEqual(rows[0].group, rows[1].group)
    for row in rows {
      XCTAssertTrue(row.sharedRejected)
      XCTAssertEqual(row.resets, resets)
      XCTAssertFalse(row.initial.id.isEmpty)
      XCTAssertFalse(row.final.id.isEmpty)
    }
    if resets > 0 {
      XCTAssertLessThan(max(rows[0].began, rows[1].began), min(rows[0].ended, rows[1].ended))
    }
    return rows
  }

  func testIndependentChainsRestoreAndColdStartLink() throws {
    try checkChains()
  }

  func testReopeningAndOffscreenMoreKeepOneSessionChain() throws {
    try checkChains(exerciseDiscovery: true)
  }

  private func checkChains(exerciseDiscovery: Bool = false) throws {
    let run = UUID().uuidString
    let first = try exercise(run: run, restore: false, sampled: true, resets: 50, exerciseDiscovery: exerciseDiscovery)
    let restored = try exercise(run: run, restore: true, sampled: false, resets: 0, exerciseDiscovery: exerciseDiscovery)
    let linked = try exercise(run: run, restore: false, sampled: false, resets: 50, exerciseDiscovery: exerciseDiscovery)
    for index in 0 ..< 2 {
      XCTAssertNil(first[index].initial.previous)
      XCTAssertEqual(first[index].initial.decision, "sampled")
      XCTAssertEqual(first[index].final.decision, "sampled")
      XCTAssertEqual(restored[index].initial, first[index].final)
      XCTAssertEqual(restored[index].final, first[index].final)
      XCTAssertEqual(restored[index].samplerCalls, 0)
      XCTAssertEqual(linked[index].initial.previous, first[index].final.id)
      XCTAssertNotEqual(linked[index].initial.id, first[index].final.id)
      XCTAssertEqual(linked[index].initial.decision, "notSampled")
      XCTAssertEqual(linked[index].final.decision, "notSampled")
      XCTAssertEqual(first[index].samplerCalls, 51)
      XCTAssertEqual(linked[index].samplerCalls, 51)
    }
    XCTAssertNotEqual(first[0].final.id, first[1].final.id)
    XCTAssertNotEqual(linked[0].final.id, linked[1].final.id)
  }
}
