import XCTest
import UIKit

@MainActor
final class AlbumHomeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testHomeAt375ShowsCoversAndOnlyAddCommand() throws {
        let app = launch(arguments: ["--ui-testing-home-width-375"])
        let home = element("albums-workspace-list", app)
        XCTAssertLessThanOrEqual(home.frame.width, 375.5)
        XCTAssertTrue(element("album-quick-favorites", app).exists)
        XCTAssertTrue(element("album-quick-travel", app).exists)
        XCTAssertTrue(element("album-grid-personal", app).isHittable)
        let add = element("album-home-add", app)
        XCTAssertGreaterThanOrEqual(add.frame.width, 44)
        XCTAssertGreaterThanOrEqual(add.frame.height, 44)
        XCTAssertFalse(app.buttons["搜索"].exists)
        XCTAssertFalse(app.buttons["用户"].exists)
        XCTAssertTrue(app.tabBars.buttons["相册"].isSelected)
        try assertRenderedPhoto(element("album-grid-personal", app), app: app)
        screenshot(app, "a02-375")
    }

    func testHomeAt393LargeTextAndAccessibleLabels() throws {
        let app = launch(arguments: ["--ui-testing-home-width-393", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertLessThanOrEqual(element("albums-workspace-list", app).frame.width, 393.5)
        XCTAssertEqual(element("album-quick-favorites", app).label, "收藏")
        XCTAssertEqual(element("album-quick-favorites", app).value as? String, "2 项")
        screenshot(app, "a02-393-accessibility")
        try app.performAccessibilityAudit(for: [.dynamicType, .hitRegion, .textClipped])
    }

    func testCollectionMediaAndReturnRestoreAlbumTab() throws {
        let app = launch(arguments: ["--ui-testing-home-width-393"])
        element("album-quick-travel", app).tap()
        XCTAssertTrue(element("album-content-grid", app).waitForExistence(timeout: 5))
        XCTAssertEqual(element("album-content-asset-cloud", app).label, "视频，0:42，仅云端可用")
        XCTAssertFalse(app.tabBars.buttons["相册"].exists)
        screenshot(app, "a02-content-393")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(element("album-quick-travel", app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["相册"].isSelected)
        screenshot(app, "a02-393")
    }

    func testCreateEmptyAlbumAndCancel() throws {
        let app = launch()
        element("album-home-add", app).tap()
        XCTAssertFalse(element("album-creation-submit", app).isEnabled)
        element("album-creation-name", app).tap()
        element("album-creation-name", app).typeText("New Album")
        element("album-creation-cancel", app).tap()
        XCTAssertFalse(app.staticTexts["New Album"].exists)
        element("album-home-add", app).tap()
        element("album-creation-name", app).tap()
        element("album-creation-name", app).typeText("New Album")
        element("album-creation-submit", app).tap()
        XCTAssertTrue(element("album-home-notice", app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("album-home-notice", app).label.contains("模拟"))
        let album = app.buttons.matching(NSPredicate(format: "label == %@", "New Album")).firstMatch
        XCTAssertTrue(reveal(album, app))
        album.tap()
        XCTAssertTrue(element("album-content-empty", app).waitForExistence(timeout: 5))
    }

    func testOpenContentDropsPhotosAfterScopeReduction() throws {
        let app = launch(arguments: ["--ui-testing-albums-scope-change"])
        element("album-quick-travel", app).tap()
        let cloud = element("album-content-asset-cloud", app)
        XCTAssertTrue(cloud.waitForExistence(timeout: 5))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: cloud
        )], timeout: 15), .completed)
        XCTAssertTrue(element("album-content-asset-lake", app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("album-content-asset-field", app).exists)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(element("album-home-limited", app).waitForExistence(timeout: 5))
        XCTAssertEqual(element("album-grid-travel", app).value as? String, "1 项")
    }

    func testCreationUncertaintyRequiresRefresh() throws {
        let app = launch(arguments: ["--ui-testing-albums-create-failure"])
        element("album-home-add", app).tap()
        element("album-creation-name", app).tap()
        element("album-creation-name", app).typeText("Uncertain")
        element("album-creation-submit", app).tap()
        XCTAssertTrue(element("album-creation-error", app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("album-creation-submit", app).isEnabled)
        element("album-creation-recover", app).tap()
        XCTAssertTrue(element("album-creation-submit", app).waitForExistence(timeout: 5))
        XCTAssertEqual(element("album-creation-name", app).value as? String, "Uncertain")
        element("album-creation-cancel", app).tap()
    }

    func testLimitedEmptyLoadingAndFailureRecovery() throws {
        var app = launch(arguments: ["--ui-testing-albums-limited"])
        XCTAssertTrue(element("album-home-limited", app).waitForExistence(timeout: 5))
        app.terminate()
        app = launch(arguments: ["--ui-testing-albums-empty"])
        XCTAssertTrue(element("album-home-empty", app).waitForExistence(timeout: 5))
        app.terminate()
        app = launch(arguments: ["--ui-testing-albums-loading"])
        XCTAssertTrue(element("album-home-loading", app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("album-home-empty", app).exists)
        app.terminate()
        app = launch(arguments: ["--ui-testing-albums-failure"])
        XCTAssertTrue(element("album-home-error", app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("album-home-empty", app).exists)
        element("album-home-retry", app).tap()
        XCTAssertTrue(element("album-quick-favorites", app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("album-home-error", app).exists)
    }

    func testMissingCollectionRetryAndQueueNavigation() throws {
        let app = launch(arguments: ["--ui-testing-albums-content-failure"])
        element("album-quick-favorites", app).tap()
        XCTAssertTrue(element("album-content-retry", app).waitForExistence(timeout: 5))
        element("album-content-retry", app).tap()
        XCTAssertTrue(element("album-content-grid", app).waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        let later = element("albums-decide-later", app)
        XCTAssertTrue(reveal(later, app))
        let priorPosition = later.frame.minY
        later.tap()
        XCTAssertTrue(app.navigationBars["稍后决定"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(later.waitForExistence(timeout: 5))
        XCTAssertEqual(later.frame.minY, priorPosition, accuracy: 6)
        element("albums-protected", app).tap()
        XCTAssertTrue(app.navigationBars["受保护照片"].waitForExistence(timeout: 5))
    }

    private func launch(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-albums"] + arguments
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["相册"].waitForExistence(timeout: 5))
        app.tabBars.buttons["相册"].tap()
        XCTAssertTrue(element("albums-workspace-list", app).waitForExistence(timeout: 5))
        return app
    }

    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        let button = app.buttons.matching(identifier: id).firstMatch
        if button.exists { return button }
        return app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func reveal(_ target: XCUIElement, _ app: XCUIApplication) -> Bool {
        for _ in 0..<8 {
            if target.exists && target.isHittable { return true }
            app.swipeUp()
        }
        return target.exists && target.isHittable
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertRenderedPhoto(_ album: XCUIElement, app: XCUIApplication) throws {
        let screenshot = try XCTUnwrap(app.screenshot().image.cgImage)
        let scale = CGFloat(screenshot.width) / app.frame.width
        let frame = album.frame
        let rect = CGRect(x: frame.minX * scale, y: frame.minY * scale,
                          width: frame.width * scale, height: frame.width * scale)
        let cover = try XCTUnwrap(screenshot.cropping(to: rect))
        var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 32, height: 32,
                bitsPerComponent: 8, bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.draw(cover, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            return true
        }
        XCTAssertTrue(rendered)
        let coloredPixels = stride(from: 0, to: pixels.count, by: 4).filter { index in
            let channels = [Int(pixels[index]), Int(pixels[index + 1]), Int(pixels[index + 2])]
            return channels.max()! - channels.min()! > 25
        }.count
        XCTAssertGreaterThan(coloredPixels, 150, "The local sunset cover must render colored photo pixels, not a placeholder")
    }
}
