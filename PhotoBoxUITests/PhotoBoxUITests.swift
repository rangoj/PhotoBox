import XCTest

final class PhotoBoxUITests: XCTestCase {
    @MainActor
    func testPermissionEducationIsShownBeforeRequestingAccess() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-not-determined"]
        app.launch()

        XCTAssertTrue(app.staticTexts["整理从了解相册开始"].waitForExistence(timeout: 3))
        app.buttons["允许访问照片"].tap()
        XCTAssertTrue(app.navigationBars["相册收件箱"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testAuthorizedUserReachesTaskInbox() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-authorized"]
        app.launch()

        XCTAssertTrue(app.navigationBars["相册收件箱"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.tabBars.buttons["任务"].exists)
        XCTAssertTrue(app.tabBars.buttons["相册"].exists)
        XCTAssertTrue(app.tabBars.buttons["设置"].exists)
    }

    @MainActor
    func testLimitedAccessShowsManageBanner() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-limited"]
        app.launch()

        XCTAssertTrue(app.staticTexts["正在整理已允许的照片"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["管理"].exists)
    }

    @MainActor
    func testDeniedAccessOffersSettingsRecovery() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-denied"]
        app.launch()

        XCTAssertTrue(app.staticTexts["无法访问照片"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["打开系统设置"].exists)
    }

    @MainActor
    func testRestrictedAccessExplainsDeviceRestriction() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-restricted"]
        app.launch()

        XCTAssertTrue(app.staticTexts["无法访问照片"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["此设备限制了照片访问。请检查屏幕使用时间或设备管理设置。"].exists)
        XCTAssertFalse(app.buttons["打开系统设置"].exists)
    }
}
