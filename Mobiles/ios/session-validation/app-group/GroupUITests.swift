import XCTest

final class GroupUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  private func exercise(run: String, restore: Bool, sampled: Bool, resets: Int) throws -> [GroupResult] {
    let app = XCUIApplication()
    app.launchEnvironment = ["SESSION99_RUN": run, "SESSION99_RESTORE": String(restore),
                             "SESSION99_SAMPLED": String(sampled), "SESSION99_RESETS": String(resets)]
    app.launch()
    defer { app.terminate() }
    app.buttons["open-extension"].tap()
    let output = app.textViews["group-status"]
    XCTAssertFalse((output.value as? String)?.hasPrefix("ERROR:") == true, String(describing: output.value))
    // The system share sheet labels the extension with the containing app's display name.
    let share = app.cells["Session 99 Groups"]
    if !share.waitForExistence(timeout: 3) {
      app.cells["More"].firstMatch.tap()
    }
    XCTAssertTrue(share.waitForExistence(timeout: 5))
    share.tap()
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
    let run = UUID().uuidString
    let first = try exercise(run: run, restore: false, sampled: true, resets: 50)
    let restored = try exercise(run: run, restore: true, sampled: false, resets: 0)
    let linked = try exercise(run: run, restore: false, sampled: false, resets: 50)
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
