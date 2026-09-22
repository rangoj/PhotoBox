import XCTest

@MainActor
final class DecisionGestureUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testB01LeftSwipeMarksDeleteAndAdvances() throws {
        let app = launch()
        let photo = app.descendants(matching: .any).matching(identifier: "decision-b01-photo").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "decision-b01-filmstrip").firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "decision-pending-count").firstMatch.exists)
        drag(photo, to: CGVector(dx: 0.02, dy: 0.5))
        XCTAssertTrue(waitForPosition("第 2 项，共 5 项", app: app))
    }

    func testB01RightSwipeKeepsAndAdvances() throws {
        let app = launch()
        let photo = app.descendants(matching: .any).matching(identifier: "decision-b01-photo").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        photo.swipeRight()
        XCTAssertTrue(waitForPosition("第 2 项，共 5 项", app: app))
    }

    func testB01UpSwipeRequestsFavoriteAndStaysOnPhoto() throws {
        let app = launch()
        let photo = app.descendants(matching: .any).matching(identifier: "decision-b01-photo").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        photo.swipeUp()
        XCTAssertTrue(waitForPosition("第 1 项，共 5 项", app: app))
        let favorite = app.images["decision-favorite-state"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        photo.swipeUp()
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: favorite)], timeout: 5) == .completed)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "decision-b01-photo").firstMatch.exists)
    }

    func testB01DownSwipeOpensAlbumArchiveFlow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-archive"]
        app.launch()
        let photo = app.descendants(matching: .any).matching(identifier: "decision-b01-photo").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        photo.swipeDown()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "album-panel").firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["album-panel-submit"].exists)
        XCTAssertFalse(app.buttons["album-panel-submit"].isEnabled, "Opening drag must not select an album")
    }

    func testB01ArchivePanelSupportsMultiSelection() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-archive"]
        app.launch()
        let photo = app.descendants(matching: .any).matching(identifier: "decision-b01-photo").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        photo.swipeDown()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "album-panel").firstMatch.waitForExistence(timeout: 5))
        let row = app.buttons["album-panel-row-archive-valid"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForHittable(row))
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(waitForAlbumSelection(row))
        let second = app.buttons["album-panel-row-archive-second"]
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        second.tap()
        XCTAssertTrue(waitForAlbumSelection(second))
        let submit = app.buttons["album-panel-submit"]
        XCTAssertEqual(submit.label, "加入（2）")
        XCTAssertTrue(waitForEnabled(submit))
        submit.tap()
        XCTAssertTrue(waitForPosition("第 1 项，共 2 项", app: app))
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: submit)], timeout: 5) == .completed)
        photo.swipeDown()
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "已在相册"), object: row)], timeout: 5) == .completed)
        XCTAssertEqual(second.value as? String, "已在相册")
    }

    func testShortDownDragCancelsPanelAndNextGestureStillWorks() throws {
        let app = launch()
        let photo = app.descendants(matching: .any).matching(identifier: "decision-b01-photo").firstMatch
        let start = photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 60)), withVelocity: .slow, thenHoldForDuration: 0)
        XCTAssertTrue(waitForPosition("第 1 项，共 5 项", app: app))
        let panel = app.descendants(matching: .any).matching(identifier: "album-panel").firstMatch
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: panel)], timeout: 5) == .completed)
        photo.swipeRight()
        XCTAssertTrue(waitForPosition("第 2 项，共 5 项", app: app))
    }

    func testLongDragTriggersOnlyOneDecisionAndUndoRestoresPhoto() throws {
        let app = launch()
        let photo = app.descendants(matching: .any).matching(identifier: "decision-b01-photo").firstMatch
        let start = photo.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        let end = photo.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 1)
        XCTAssertTrue(waitForPosition("第 2 项，共 5 项", app: app))
        app.buttons["decision-undo"].tap()
        XCTAssertTrue(waitForPosition("第 1 项，共 5 项", app: app))
    }

    func testB01PhotoAndPanelFit375And393Points() throws {
        for width in [375, 393] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-testing-archive", "--ui-testing-home-width-\(width)"]
            app.launch()
            let photo = app.descendants(matching: .any).matching(identifier: "decision-b01-photo").firstMatch
            XCTAssertTrue(photo.waitForExistence(timeout: 5))
            let strip = app.descendants(matching: .any).matching(identifier: "decision-b01-filmstrip").firstMatch
            XCTAssertTrue(strip.exists)
            XCTAssertEqual(strip.frame.width, CGFloat(width), accuracy: 1)
            XCTAssertLessThanOrEqual(photo.frame.maxY, strip.frame.minY)
            recordScreenshot("b01-\(width)-rest", app: app)
            photo.swipeDown()
            let submit = app.buttons["album-panel-submit"]
            XCTAssertTrue(submit.waitForExistence(timeout: 5))
            XCTAssertLessThanOrEqual(submit.frame.maxY, strip.frame.minY)
            XCTAssertGreaterThanOrEqual(submit.frame.height, 44)
            recordScreenshot("b09-\(width)-albums", app: app)
            app.terminate()
        }
    }

    func testUnavailablePhotoShowsRetryStateWithoutStartingDecision() throws {
        let app = launch()
        let fifth = app.buttons["第 5 张"]
        XCTAssertTrue(fifth.waitForExistence(timeout: 5))
        fifth.tap()
        let unavailable = app.descendants(matching: .any).matching(identifier: "decision-unavailable").firstMatch
        XCTAssertTrue(unavailable.waitForExistence(timeout: 5))
        let retry = app.descendants(matching: .any).matching(identifier: "decision-photo-retry").firstMatch
        if !retry.waitForExistence(timeout: 5) {
            XCTContext.runActivity(named: "Unavailable B01 hierarchy") { activity in
                activity.add(XCTAttachment(string: app.debugDescription))
            }
            XCTFail("Missing unavailable-photo retry action")
        }
        XCTAssertTrue(waitForPosition("第 5 项，共 5 项", app: app))
        XCTAssertFalse(app.buttons["decision-undo"].isEnabled)
    }

    private func recordScreenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-decision"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "decision-b01").firstMatch.waitForExistence(timeout: 5))
        return app
    }

    private func waitForPosition(_ value: String, app: XCUIApplication) -> Bool {
        let position = app.descendants(matching: .any).matching(identifier: "decision-b01-position").firstMatch
        let predicate = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", value, value)
        let passed = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: position)], timeout: 5) == .completed
        if !passed {
            XCTContext.runActivity(named: "B01 hierarchy after gesture") { activity in
                activity.add(XCTAttachment(string: app.debugDescription))
            }
        }
        return passed
    }

    private func waitForAlbumSelection(_ row: XCUIElement) -> Bool {
        let predicate = NSPredicate(format: "value CONTAINS %@", "已选择")
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: row)], timeout: 3) == .completed
    }

    private func waitForHittable(_ element: XCUIElement) -> Bool {
        let predicate = NSPredicate(format: "hittable == true")
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 3) == .completed
    }

    private func waitForEnabled(_ element: XCUIElement) -> Bool {
        let predicate = NSPredicate(format: "enabled == true")
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 3) == .completed
    }

    private func drag(_ element: XCUIElement, to normalizedOffset: CGVector) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = element.coordinate(withNormalizedOffset: normalizedOffset)
        start.press(forDuration: 0.3, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
    }
}
