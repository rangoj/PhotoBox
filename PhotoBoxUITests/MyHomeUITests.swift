import XCTest

@MainActor
final class MyHomeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testTotalsHistoryAndSettingsAt375() throws {
        let app = launch(["--ui-testing-home-width-375"])
        let deleted = element("my-deleted-total", app)
        XCTAssertEqual(deleted.value as? String, "1 张")
        XCTAssertEqual(element("my-processed-total", app).value as? String, "14 张")
        XCTAssertFalse(app.buttons["登录"].exists)
        screenshot(app, "a03-375")
        element("my-history", app).tap()
        XCTAssertTrue(element("my-history-content", app).waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.buttons["我的"].exists)
        XCTAssertTrue(element("my-history-transaction-my-simulated", app).label.contains("模拟删除"))
        screenshot(app, "a03-history")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.tabBars.buttons["我的"].isSelected)
        element("my-settings", app).tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.buttons["我的"].exists)
    }

    func testFeedbackDraftPersistsAndSupportRoutesReturn() throws {
        let app = launch([])
        element("my-feedback", app).tap()
        XCTAssertFalse(element("my-feedback-share", app).isEnabled)
        let draft = element("my-feedback-draft", app)
        draft.tap()
        draft.typeText("   ")
        XCTAssertFalse(element("my-feedback-share", app).isEnabled)
        draft.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3))
        draft.typeText("PhotoBox feedback")
        XCTAssertTrue(element("my-feedback-share", app).isEnabled)
        element("my-feedback-share", app).tap()
        let closeShare = app.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "关闭", "Cancel", "取消"])).firstMatch
        XCTAssertTrue(closeShare.waitForExistence(timeout: 5))
        closeShare.tap()
        XCTAssertEqual(element("my-feedback-draft", app).value as? String, "PhotoBox feedback")
        app.navigationBars.buttons.firstMatch.tap()
        element("my-feedback", app).tap()
        XCTAssertEqual(element("my-feedback-draft", app).value as? String, "PhotoBox feedback")
        app.navigationBars.buttons.firstMatch.tap()
        element("my-help", app).tap()
        XCTAssertTrue(app.navigationBars["帮助"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        element("my-about", app).tap()
        XCTAssertTrue(app.navigationBars["关于"].exists)
        XCTAssertTrue(app.staticTexts["PhotoBox"].exists)
    }

    func testEmptyHistoryAndLargeTextAt393() throws {
        let app = launch(["--ui-testing-my-empty", "--ui-testing-home-width-393",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertEqual(element("my-deleted-total", app).value as? String, "0 张")
        screenshot(app, "a03-393-accessibility")
        try app.performAccessibilityAudit(for: [.dynamicType, .hitRegion, .textClipped])
        element("my-history", app).tap()
        XCTAssertTrue(element("my-history-empty", app).waitForExistence(timeout: 5))
    }

    func testHomeAndHistoryReadFailureCanRetry() throws {
        var app = launch(["--ui-testing-my-failure"])
        XCTAssertTrue(element("my-home-error", app).waitForExistence(timeout: 5))
        XCTAssertEqual(element("my-deleted-total", app).value as? String, "暂不可用")
        element("my-home-retry", app).tap()
        XCTAssertEqual(element("my-deleted-total", app).value as? String, "1 张")
        XCTAssertFalse(element("my-home-error", app).exists)
        app.terminate()
        app = launch(["--ui-testing-my-history-failure"])
        element("my-history", app).tap()
        XCTAssertTrue(element("my-history-retry", app).waitForExistence(timeout: 5))
        element("my-history-retry", app).tap()
        XCTAssertTrue(element("my-history-transaction-my-live", app).waitForExistence(timeout: 5))
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-my"] + arguments
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["我的"].waitForExistence(timeout: 5))
        app.tabBars.buttons["我的"].tap()
        XCTAssertTrue(element("my-history", app).waitForExistence(timeout: 5))
        return app
    }

    private func element(_ identifier: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
