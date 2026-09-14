import XCTest

@MainActor
final class CleanupHomeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testA01LayoutAt375KeepsFirstMonthVisible() throws {
        let app = launchHome(arguments: ["--ui-testing-home-width-375"])

        let home = element("cleanup-home", in: app)
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(home.frame.width, 375.5)
        XCTAssertTrue(app.staticTexts["PhotoBox"].exists)
        assertCollectionEntries(in: app)
        XCTAssertTrue(element("home-month-2026-08", in: app).isHittable)
        attachScreenshot(of: app, named: "cleanup-home-375")
    }

    func testA01LayoutAt393SupportsAccessibilityTextAndAudit() throws {
        let app = launchHome(arguments: [
            "--ui-testing-home-width-393",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL"
        ])

        let home = element("cleanup-home", in: app)
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(home.frame.width, 393.5)
        assertCollectionEntries(in: app)
        XCTAssertTrue(reveal(element("home-month-2026-08", in: app), in: app))
        attachScreenshot(of: app, named: "cleanup-home-393-accessibility")
        try app.performAccessibilityAudit(for: [.dynamicType, .hitRegion, .textClipped])
    }

    func testHistoryEntryOpensHistoricalDayBatch() throws {
        let app = launchHome()
        element("home-on-this-day", in: app).tap()
        assertDecisionScreen(in: app)
    }

    func testRecentEntryOpensLatestEligibleDayBatch() throws {
        let app = launchHome()
        element("home-recent", in: app).tap()
        assertDecisionScreen(in: app)
        XCTAssertEqual(value(of: element("decision-position", in: app)), "第 1 项，共 40 项")
    }

    func testRandomEntryOpensAnEligibleDayBatch() throws {
        let app = launchHome()
        element("home-random", in: app).tap()
        assertDecisionScreen(in: app)
    }

    func testDuplicateEntryOpensExistingSimilarTask() throws {
        let app = launchHome()
        element("home-duplicates", in: app).tap()

        XCTAssertTrue(element("duplicates-list", in: app).waitForExistence(timeout: 3))
        element("duplicates-task-home-similar-task", in: app).tap()
        XCTAssertTrue(element("comparison-group-position", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.buttons["整理"].exists)
    }

    func testMonthEntryOpensBalancedLatestDayBatch() throws {
        let app = launchHome()
        element("home-month-2026-08", in: app).tap()
        assertDecisionScreen(in: app)
        XCTAssertEqual(value(of: element("decision-position", in: app)), "第 1 项，共 40 项")
    }

    func testThreeTabsAndMyDirectDestinations() throws {
        let app = launchHome()
        XCTAssertTrue(app.tabBars.buttons["整理"].exists)
        XCTAssertTrue(app.tabBars.buttons["相册"].exists)
        XCTAssertTrue(app.tabBars.buttons["我的"].exists)

        app.tabBars.buttons["相册"].tap()
        XCTAssertTrue(element("albums-workspace-list", in: app).waitForExistence(timeout: 3))
        app.tabBars.buttons["我的"].tap()
        XCTAssertTrue(element("my-workspace-list", in: app).waitForExistence(timeout: 3))

        element("my-statistics", in: app).tap()
        XCTAssertTrue(app.navigationBars["统计"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.tabBars.buttons["我的"].exists)
        app.navigationBars.buttons.firstMatch.tap()

        let settings = element("my-settings", in: app)
        XCTAssertTrue(reveal(settings, in: app))
        settings.tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.tabBars.buttons["我的"].exists)
    }

    func testKeepOnlyBatchShowsResultsAndReturnsHome() throws {
        let app = launchHome(mode: "--ui-testing-home-small-keep")
        element("home-recent", in: app).tap()
        assertDecisionScreen(in: app)

        element("decision-keep", in: app).tap()
        XCTAssertTrue(waitForValue("第 2 项，共 2 项", element: element("decision-position", in: app)))
        element("decision-keep", in: app).tap()

        let returnButton = element("cleanup-results-return", in: app)
        XCTAssertTrue(returnButton.waitForExistence(timeout: 5))
        returnButton.tap()
        XCTAssertTrue(element("cleanup-home", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["整理"].exists)
    }

    func testDeleteCandidateBatchOpensDeleteReview() throws {
        let app = launchHome(mode: "--ui-testing-home-small-delete")
        element("home-recent", in: app).tap()
        assertDecisionScreen(in: app)

        element("decision-delete", in: app).tap()
        XCTAssertTrue(waitForValue("第 2 项，共 2 项", element: element("decision-position", in: app)))
        element("decision-keep", in: app).tap()

        XCTAssertTrue(app.navigationBars["删除复核"].waitForExistence(timeout: 5))
        let count = element("delete-review-candidate-count", in: app)
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertEqual(value(of: count), "1 项")
        XCTAssertFalse(app.tabBars.buttons["整理"].exists)
    }

    func testMonthProgressShowsPartialAndCompletedStates() throws {
        let app = launchHome()
        let august = element("home-month-2026-08", in: app)
        XCTAssertTrue(august.waitForExistence(timeout: 5))
        XCTAssertEqual(value(of: august), "238 张照片，已处理 40 张")

        let july = element("home-month-2026-07", in: app)
        XCTAssertTrue(reveal(july, in: app))
        XCTAssertEqual(value(of: july), "186 张照片，已完成")
    }

    func testLimitedEmptyCloudFailureAndLoadingStates() throws {
        var app = launchHome(mode: "--ui-testing-home-limited")
        XCTAssertTrue(element("permission-limited-state", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["管理"].exists)
        app.terminate()

        app = launchHome(mode: "--ui-testing-home-empty")
        XCTAssertTrue(element("home-empty-state", in: app).waitForExistence(timeout: 3))
        app.terminate()

        app = launchHome(mode: "--ui-testing-home-cloud-only")
        element("home-recent", in: app).tap()
        XCTAssertTrue(app.staticTexts["此集合暂无可整理的本地照片。"].waitForExistence(timeout: 3))
        app.terminate()

        app = launchHome(mode: "--ui-testing-home-failed")
        XCTAssertTrue(element("home-scan-status", in: app).waitForExistence(timeout: 3))
        element("scan-retry", in: app).tap()
        XCTAssertTrue(element("home-month-2026-09", in: app).waitForExistence(timeout: 8))
        app.terminate()

        app = launchHome(mode: "--ui-testing-home-loading")
        XCTAssertTrue(element("home-scan-status", in: app).waitForExistence(timeout: 3))
        XCTAssertFalse(element("home-recent", in: app).isEnabled)
        XCTAssertTrue(element("scan-cancel", in: app).exists)
    }

    private func launchHome(
        mode: String = "--ui-testing-home",
        arguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [mode] + arguments
        app.launch()
        XCTAssertTrue(element("cleanup-home", in: app).waitForExistence(timeout: 5))
        return app
    }

    private func assertCollectionEntries(in app: XCUIApplication) {
        for identifier in ["home-on-this-day", "home-recent", "home-random", "home-duplicates"] {
            XCTAssertTrue(element(identifier, in: app).exists, identifier)
        }
    }

    private func assertDecisionScreen(in app: XCUIApplication) {
        XCTAssertTrue(element("decision-position", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("decision-media-viewport", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.buttons["整理"].exists)
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<6 {
            if element.exists, element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }

    private func value(of element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty { return value }
        return element.label
    }

    private func waitForValue(
        _ expected: String,
        element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@ OR label == %@", expected, expected),
                object: element
            )],
            timeout: timeout
        ) == .completed
    }

    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
