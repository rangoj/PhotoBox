import XCTest

final class PhotoBoxUITests: XCTestCase {
    private struct AccessibilityManifestEntry {
        let identifier: String
        let type: XCUIElement.ElementType
        let label: String
        let value: String?
        let enabled: Bool?
        let selected: Bool?

        init(
            _ identifier: String,
            _ type: XCUIElement.ElementType,
            _ label: String,
            value: String? = nil,
            enabled: Bool? = nil,
            selected: Bool? = nil
        ) {
            self.identifier = identifier
            self.type = type
            self.label = label
            self.value = value
            self.enabled = enabled
            self.selected = selected
        }
    }

    // Production break: the root authorization task settles before exposing a named loading state.
    @MainActor
    func testAuthorizationLoadingHasExplicitChineseSemantics() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-authorization-loading"]
        app.launch()

        assertAccessibility(
            element(in: app, identifier: "authorization-loading"),
            type: .activityIndicator,
            label: "正在检查照片访问权限",
            value: "正在载入授权状态"
        )
        XCTAssertTrue(app.tabBars.buttons["整理"].waitForExistence(timeout: 8))
    }

    @MainActor
    func testPermissionEducationIsShownBeforeRequestingAccess() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-not-determined"]
        app.launch()

        XCTAssertTrue(app.staticTexts["整理从了解相册开始"].waitForExistence(timeout: 3))
        assertZeroLifecycleNotificationEffects(in: app)
        app.buttons["允许访问照片"].tap()
        XCTAssertTrue(app.tabBars.buttons["整理"].waitForExistence(timeout: 3))
        assertZeroLifecycleNotificationEffects(in: app)
    }

    // Production break: a full-flow fixture that starts below the permission
    // root or pre-seeds the result/weekly roots bypasses the real handoffs.
    @MainActor
    func testFullP0FlowCompletesFromOnePermissionLaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-full-flow"]
        app.launch()

        XCTAssertTrue(app.buttons["permission-request"].waitForExistence(timeout: 3))
        app.buttons["permission-request"].tap()
        XCTAssertTrue(element(in: app, identifier: "home-scan-status").waitForExistence(timeout: 3))
        navigateToTaskDashboard(in: app)
        XCTAssertTrue(
            waitForValue("全部照片，正在读取相册", element: element(in: app, identifier: "scan-status")),
            "The one-launch fixture must expose a real in-progress scan state before completion"
        )
        XCTAssertTrue(
            waitForValue("全部照片，相册诊断已更新", element: element(in: app, identifier: "scan-status")),
            "The permission action must reach the completed partial-scan handoff"
        )

        let comparisonTask = app.buttons["diagnosis-task-action-full-flow-comparison"]
        XCTAssertTrue(comparisonTask.waitForExistence(timeout: 3))
        comparisonTask.tap()
        XCTAssertTrue(app.navigationBars["照片对比"].waitForExistence(timeout: 3))
        let alternateKeep = app.buttons["comparison-select-keep-full-flow-comparison-delete"]
        XCTAssertTrue(alternateKeep.waitForExistence(timeout: 3))
        alternateKeep.tap()
        XCTAssertTrue(app.buttons["comparison-complete-group"].waitForExistence(timeout: 3))
        app.buttons["comparison-complete-group"].tap()
        XCTAssertTrue(app.staticTexts["已完成所有对比"].waitForExistence(timeout: 3))
        app.navigationBars.buttons.firstMatch.tap()

        let decisionTask = app.buttons["diagnosis-task-action-full-flow-decisions"]
        XCTAssertTrue(decisionTask.waitForExistence(timeout: 3))
        decisionTask.tap()
        XCTAssertTrue(app.navigationBars["整理照片"].waitForExistence(timeout: 3))
        let position = app.staticTexts["decision-position"]
        XCTAssertEqual(position.label, "第 1 项，共 5 项")
        app.buttons["decision-keep"].tap()
        app.buttons["decision-delete"].tap()
        app.buttons["decision-archive"].tap()
        XCTAssertTrue(app.navigationBars["选择相册"].waitForExistence(timeout: 3))
        app.buttons["album-recent-row-full-flow-album"].tap()
        XCTAssertTrue(app.navigationBars["整理照片"].waitForExistence(timeout: 3))
        app.buttons["decision-protect"].tap()
        app.buttons["decision-later"].tap()
        XCTAssertTrue(element(in: app, identifier: "decision-complete").waitForExistence(timeout: 3))

        app.navigationBars.buttons.firstMatch.tap()
        let reviewRoute = app.buttons["delete-review-route"]
        XCTAssertTrue(reviewRoute.waitForExistence(timeout: 3))
        reviewRoute.tap()
        XCTAssertTrue(app.navigationBars["删除复核"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["delete-review-confirm"].waitForExistence(timeout: 3))
        app.buttons["delete-review-confirm"].tap()
        app.buttons["delete-review-confirm-final"].firstMatch.tap()

        XCTAssertTrue(app.navigationBars["整理结果"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(in: app, identifier: "cleanup-results-deleted-count").waitForExistence(timeout: 3))
        XCTAssertTrue(waitForValue("2 项", element: element(in: app, identifier: "cleanup-results-deleted-count")))
        XCTAssertTrue(element(in: app, identifier: "cleanup-results-archive-count").exists)
        XCTAssertTrue(element(in: app, identifier: "cleanup-results-protect-count").exists)
        XCTAssertTrue(element(in: app, identifier: "cleanup-results-deferred-count").exists)
        app.buttons["cleanup-results-return"].tap()
        assertCleanupHome(in: app)
        navigateToWeeklyInbox(in: app)
        XCTAssertTrue(app.navigationBars["本周收件箱"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(in: app, identifier: "weekly-inbox-list").waitForExistence(timeout: 3))
        let weeklyTaskCount = element(in: app, identifier: "weekly-task-count")
        if weeklyTaskCount.waitForExistence(timeout: 3) {
            XCTAssertTrue(waitForValue("1 项", element: weeklyTaskCount))
        } else {
            XCTAssertTrue(element(in: app, identifier: "weekly-tidy-empty").waitForExistence(timeout: 3))
        }
        navigateToSettings(in: app)
        let mutationMode = element(in: app, identifier: "settings.mutationMode")
        XCTAssertTrue(reveal(mutationMode, in: app, upward: true))
        XCTAssertEqual(mutationMode.label, "照片变更模式, 模拟模式（不会修改系统照片）")
    }

    // Production break: an onboarding side effect after the root snapshot remains hidden from the final probe.
    @MainActor
    func testOnboardingBoundaryRefreshesNotificationRecordingAfterAction() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-not-determined",
            "--ui-testing-lifecycle-onboarding-authorization-side-effect"
        ]
        app.launch()

        XCTAssertTrue(app.buttons["允许访问照片"].waitForExistence(timeout: 3))
        app.buttons["允许访问照片"].tap()
        XCTAssertTrue(app.tabBars.buttons["整理"].waitForExistence(timeout: 3))
        assertLifecycleNotificationEffects(
            authorizationRequests: 1,
            scheduledRequests: 0,
            in: app
        )
    }

    @MainActor
    func testAuthorizedUserReachesHome() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-authorized"]
        app.launch()

        assertCleanupHome(in: app)
        XCTAssertTrue(app.staticTexts["PhotoBox"].exists)
        XCTAssertTrue(app.tabBars.buttons["整理"].exists)
        XCTAssertTrue(app.tabBars.buttons["相册"].exists)
        XCTAssertTrue(app.tabBars.buttons["我的"].exists)
        XCTAssertEqual(app.tabBars.buttons.count, 3)
        XCTAssertFalse(app.tabBars.buttons["任务"].exists)
        XCTAssertFalse(app.tabBars.buttons["统计"].exists)
        XCTAssertFalse(app.tabBars.buttons["设置"].exists)
    }

    @MainActor
    func testAuthorizedHomeHasNoPaywallSurface() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-authorized"]
        app.launch()

        assertCleanupHome(in: app)
        for token in ["订阅", "升级", "购买", "Paywall", "StoreKit"] {
            let match = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS[c] %@", token))
                .firstMatch
            XCTAssertFalse(match.exists, "Unexpected paywall surface containing \(token)")
        }
    }

    @MainActor
    func testLimitedAccessShowsManageBanner() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-limited"]
        app.launch()

        navigateToTaskDashboard(in: app)
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

    @MainActor
    func testCancelledScanOffersResumeAndRestart() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-cancelled"]
        app.launch()

        navigateToTaskDashboard(in: app)
        assertAccessibility(
            element(in: app, identifier: "scan-status"),
            label: "扫描状态",
            value: "全部照片，扫描已暂停"
        )
        XCTAssertTrue(app.buttons["继续扫描"].exists)
        XCTAssertTrue(app.buttons["重新开始"].exists)
    }

    @MainActor
    func testEmptyLibraryShowsHealthyState() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-empty"]
        app.launch()

        navigateToTaskDashboard(in: app)
        XCTAssertTrue(app.staticTexts["相册状态良好"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["当前可访问范围内没有需要整理的照片或视频。"].exists)
    }

    // Production break: the empty fixture reads queue decisions persisted by an
    // earlier UI test and replaces the healthy state with unrelated work.
    @MainActor
    func testEmptyLibraryFixtureIgnoresPersistedQueueState() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-queues-reset"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["相册"].waitForExistence(timeout: 3))

        app.terminate()
        app.launchArguments = ["--ui-testing-empty"]
        app.launch()

        navigateToTaskDashboard(in: app)
        XCTAssertTrue(app.staticTexts["相册状态良好"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["当前可访问范围内没有需要整理的照片或视频。"].exists)
    }

    @MainActor
    func testFailedScanOffersScopedRetry() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-failed"]
        app.launch()

        navigateToTaskDashboard(in: app)
        assertAccessibility(
            element(in: app, identifier: "scan-status"),
            label: "扫描状态",
            value: "全部照片，无法扫描当前可访问范围"
        )
        XCTAssertTrue(app.buttons["重试扫描"].exists)
    }

    @MainActor
    func testPartialScanShowsProgressAndCancelAction() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-partial"]
        app.launch()

        navigateToTaskDashboard(in: app)
        assertAccessibility(
            element(in: app, identifier: "scan-status"),
            label: "扫描状态",
            value: "全部照片，正在检查本地照片"
        )
        XCTAssertTrue(app.staticTexts["已发现 8 项，已处理 3 项"].exists)
        XCTAssertTrue(app.buttons["取消扫描"].exists)
    }

    @MainActor
    func testDiagnosisFixtureRanksTrustedTaskBeforeLargerHighRiskTask() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-diagnosis"]
        app.launch()

        assertZeroLifecycleNotificationEffects(in: app)
        navigateToTaskDashboard(in: app)
        XCTAssertTrue(app.collectionViews["task-inbox-list"].waitForExistence(timeout: 3))
        let lowRiskTask = element(in: app, identifier: "diagnosis-task-low-risk")
        let highRiskTask = element(in: app, identifier: "diagnosis-task-high-risk")
        XCTAssertTrue(lowRiskTask.waitForExistence(timeout: 3))
        XCTAssertTrue(highRiskTask.exists)
        XCTAssertLessThan(lowRiskTask.frame.minY, highRiskTask.frame.minY)

        app.buttons["diagnosis-report"].tap()
        XCTAssertTrue(app.staticTexts["diagnosis-current-storage"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["diagnosis-estimated-reclaimable"].exists)
        XCTAssertTrue(app.staticTexts["diagnosis-recently-deleted-guidance"].exists)
        assertZeroLifecycleNotificationEffects(in: app)
    }

    @MainActor
    func testDiagnosisLifecycleHasZeroNotificationEffects() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-diagnosis"]
        app.launch()

        navigateToTaskDashboard(in: app)
        XCTAssertTrue(app.buttons["diagnosis-report"].waitForExistence(timeout: 3))
        assertZeroLifecycleNotificationEffects(in: app)
        app.buttons["diagnosis-report"].tap()
        XCTAssertTrue(app.navigationBars["诊断报告"].waitForExistence(timeout: 3))
        assertZeroLifecycleNotificationEffects(in: app)
    }

    // Production break: a diagnosis-navigation side effect after the root snapshot remains hidden from the final probe.
    @MainActor
    func testDiagnosisBoundaryRefreshesNotificationRecordingAfterNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-diagnosis",
            "--ui-testing-lifecycle-diagnosis-schedule-side-effect"
        ]
        app.launch()

        navigateToTaskDashboard(in: app)
        XCTAssertTrue(app.buttons["diagnosis-report"].waitForExistence(timeout: 3))
        app.buttons["diagnosis-report"].tap()
        XCTAssertTrue(app.navigationBars["诊断报告"].waitForExistence(timeout: 3))
        assertLifecycleNotificationEffects(
            authorizationRequests: 0,
            scheduledRequests: 1,
            in: app
        )
    }

    @MainActor
    func testMediaFixturePresentsPagedStableThumbnailStatesAndMetadata() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-media"]
        app.launch()

        XCTAssertTrue(app.navigationBars["照片对比"].waitForExistence(timeout: 3))
        let viewport = app.descendants(matching: .any)
            .matching(identifier: "media-viewport")
            .firstMatch
        let controls = app.otherElements["media-page-controls"]
        XCTAssertTrue(viewport.waitForExistence(timeout: 3))
        XCTAssertTrue(controls.exists)
        let initialViewportFrame = viewport.frame
        let initialControlsFrame = controls.frame

        XCTAssertTrue(app.staticTexts["media-thumbnail-loading-media-loading-video"].exists)
        XCTAssertTrue(app.staticTexts["media-badge-video-media-loading-video"].exists)

        let expectedStates = [
            ("media-thumbnail-unavailable-media-unavailable", "", false),
            ("media-badge-live-photo-media-live", "media-live", true),
            ("media-badge-panorama-media-panorama", "media-panorama", true),
            ("media-badge-favorite-media-favorite", "media-favorite", true),
            ("media-badge-edited-media-edited", "media-edited", true),
            ("media-badge-protected-media-protected", "media-protected", true)
        ]
        for (identifier, assetID, expectsLoadedThumbnail) in expectedStates {
            app.buttons["media-next-page"].tap()
            XCTAssertTrue(app.staticTexts[identifier].waitForExistence(timeout: 3))
            if expectsLoadedThumbnail {
                XCTAssertTrue(app.images["media-thumbnail-loaded-\(assetID)"].waitForExistence(timeout: 3))
            }
            XCTAssertEqual(viewport.frame.height, initialViewportFrame.height, accuracy: 1)
            XCTAssertEqual(controls.frame.minY, initialControlsFrame.minY, accuracy: 1)
            XCTAssertFalse(viewport.frame.intersects(controls.frame))
        }
    }

    @MainActor
    func testComparisonFixtureAllowsEditingRecommendationBeforeCompletingGroup() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-comparison"]
        app.launch()

        XCTAssertTrue(app.navigationBars["照片对比"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.otherElements["comparison-media-grid"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.otherElements["comparison-media-comparison-recommended"].exists)
        XCTAssertTrue(app.otherElements["comparison-media-comparison-chosen"].exists)
        XCTAssertTrue(app.otherElements["comparison-media-comparison-protected"].exists)
        XCTAssertTrue(app.staticTexts["media-badge-favorite-comparison-protected"].exists)
        XCTAssertTrue(element(in: app, identifier: "comparison-reason-sharper").waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["comparison-select-keep-comparison-chosen"].exists)

        app.buttons["comparison-inspect-comparison-chosen"].tap()
        XCTAssertTrue(app.navigationBars["查看照片"].waitForExistence(timeout: 3))
        XCTAssertTrue(element(in: app, identifier: "media-viewport").exists)
        let pagePosition = element(in: app, identifier: "media-page-position")
        XCTAssertEqual(pagePosition.label, "1 / 3")
        app.buttons["media-next-page"].tap()
        XCTAssertEqual(pagePosition.label, "2 / 3")
        app.buttons["comparison-inspector-dismiss"].tap()

        app.buttons["comparison-select-keep-comparison-chosen"].tap()
        XCTAssertFalse(element(in: app, identifier: "comparison-recommendation-section").exists)
        revealTop(in: app)
        XCTAssertTrue(element(in: app, identifier: "comparison-user-selection").exists)
        XCTAssertTrue(reveal(app.buttons["comparison-complete-group"], in: app, upward: true))
        app.buttons["comparison-complete-group"].tap()

        let groupPosition = app.staticTexts["comparison-group-position"]
        XCTAssertTrue(groupPosition.waitForExistence(timeout: 3))
        XCTAssertEqual(groupPosition.label, "第 2 组，共 2 组")
        XCTAssertEqual(app.staticTexts["comparison-delete-count"].value as? String, "1")
        XCTAssertEqual(app.staticTexts["comparison-reclaimable-bytes"].value as? String, "8,000,000")
        let comparisonList = app.collectionViews
            .containing(.staticText, identifier: "comparison-group-position")
            .firstMatch
        XCTAssertTrue(comparisonList.waitForExistence(timeout: 3))
        let lowConfidence = element(in: app, identifier: "comparison-low-confidence-section")
        for _ in 0..<3 where !lowConfidence.exists {
            comparisonList.swipeDown()
        }
        XCTAssertTrue(lowConfidence.waitForExistence(timeout: 3))
        XCTAssertFalse(element(in: app, identifier: "comparison-recommendation-section").exists)
    }

    @MainActor
    func testDecisionFixtureExposesEveryLabeledActionWithoutSwipeGestures() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-decision"]
        app.launch()

        XCTAssertTrue(app.navigationBars["整理照片"].waitForExistence(timeout: 3))
        let position = app.staticTexts["decision-position"]
        XCTAssertTrue(position.waitForExistence(timeout: 3))
        for identifier in ["decision-keep", "decision-delete", "decision-archive", "decision-protect", "decision-later"] {
            XCTAssertTrue(app.buttons[identifier].exists, "Missing \(identifier)")
        }
        XCTAssertEqual(position.label, "第 1 项，共 5 项")

        app.buttons["decision-archive"].tap()
        XCTAssertTrue(app.navigationBars["选择相册"].waitForExistence(timeout: 3))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(position.waitForExistence(timeout: 3))
        XCTAssertEqual(position.label, "第 1 项，共 5 项")

        app.buttons["decision-keep"].tap()
        XCTAssertTrue(app.buttons["decision-undo"].waitForExistence(timeout: 3))
        XCTAssertEqual(position.label, "第 2 项，共 5 项")
        app.buttons["decision-undo"].tap()
        XCTAssertEqual(position.label, "第 1 项，共 5 项")
        app.buttons["decision-keep"].tap()

        app.buttons["decision-delete"].tap()
        XCTAssertEqual(app.staticTexts["decision-reclaimable-bytes"].value as? String, "1,000")
        app.buttons["decision-undo"].tap()
        XCTAssertEqual(app.staticTexts["decision-reclaimable-bytes"].value as? String, "0")
        app.buttons["decision-delete"].tap()
        app.buttons["decision-protect"].tap()
        app.buttons["decision-later"].tap()

        XCTAssertEqual(position.label, "第 5 项，共 5 项")
        XCTAssertEqual(app.staticTexts["decision-pending-count"].value as? String, "4")
        app.buttons["decision-keep"].tap()
        XCTAssertTrue(element(in: app, identifier: "decision-complete").waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["decision-undo"].exists)
        app.buttons["decision-undo"].tap()
        XCTAssertEqual(position.label, "第 5 项，共 5 项")
        XCTAssertTrue(app.buttons["decision-keep"].exists)
    }

    // Production break: a disappeared archive target loses the routed asset, hides recovery, or reaches live PhotoKit.
    @MainActor
    func testAlbumArchiveFixtureRecoversFromMissingTargetAndReturnsToNextItem() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-archive"]
        app.launch()

        XCTAssertTrue(app.navigationBars["整理照片"].waitForExistence(timeout: 3))
        let position = app.staticTexts["decision-position"]
        XCTAssertTrue(position.waitForExistence(timeout: 3))
        XCTAssertEqual(position.label, "第 1 项，共 2 项")
        app.buttons["decision-archive"].tap()

        XCTAssertTrue(app.navigationBars["选择相册"].waitForExistence(timeout: 3))
        XCTAssertTrue(element(in: app, identifier: "album-list").waitForExistence(timeout: 3))
        XCTAssertTrue(element(in: app, identifier: "album-recent-section").exists)
        XCTAssertTrue(app.buttons["album-recent-row-archive-valid"].exists)
        XCTAssertTrue(app.buttons["album-system-row-archive-missing"].exists)
        XCTAssertEqual(app.staticTexts["album-current-asset"].value as? String, "等待选择归档相册")

        app.buttons["album-create-command"].tap()
        XCTAssertTrue(app.textFields["album-create-name"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["album-create-confirm"].exists)
        app.buttons["album-create-cancel"].tap()

        app.buttons["album-system-row-archive-missing"].tap()
        XCTAssertTrue(app.staticTexts["album-error-guidance"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["album-reselection-action"].exists)
        XCTAssertEqual(app.staticTexts["album-current-asset"].value as? String, "等待选择归档相册")
        XCTAssertFalse(app.buttons["album-system-row-archive-missing"].exists)

        app.buttons["album-reselection-action"].tap()
        XCTAssertTrue(app.buttons["album-recent-row-archive-valid"].waitForExistence(timeout: 3))
        app.buttons["album-recent-row-archive-valid"].tap()

        XCTAssertTrue(app.navigationBars["整理照片"].waitForExistence(timeout: 3))
        XCTAssertTrue(position.waitForExistence(timeout: 3))
        XCTAssertEqual(position.label, "第 2 项，共 2 项")
    }

    // Production break: non-validation album creation failures render only behind the presented sheet.
    @MainActor
    func testAlbumCreationFailureGuidanceRemainsVisibleInSheet() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-archive-create-failure"]
        app.launch()

        XCTAssertTrue(app.navigationBars["整理照片"].waitForExistence(timeout: 3))
        app.buttons["decision-archive"].tap()
        XCTAssertTrue(app.navigationBars["选择相册"].waitForExistence(timeout: 3))
        app.buttons["album-create-command"].tap()
        let name = app.textFields["album-create-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        name.typeText("旅行")
        app.buttons["album-create-confirm"].tap()

        let guidance = app.staticTexts["album-create-error"]
        XCTAssertTrue(guidance.waitForExistence(timeout: 3))
        XCTAssertEqual(guidance.label, "无法创建相册，请稍后重试。")
        XCTAssertTrue(app.navigationBars["新建相册"].exists)
    }

    // Production break: cancelling the final app confirmation reaches the mutator or preserves a removed candidate.
    @MainActor
    func testDeleteReviewCancellationKeepsRecordingMutatorAtZeroCalls() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-delete-review"]
        app.launch()

        XCTAssertTrue(app.navigationBars["删除复核"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["delete-review-remove-delete-review-removed"].waitForExistence(timeout: 3))
        XCTAssertTrue(element(in: app, identifier: "delete-review-favorite-delete-review-removed").exists)
        XCTAssertTrue(element(in: app, identifier: "delete-review-edited-delete-review-remaining").exists)
        XCTAssertTrue(element(in: app, identifier: "delete-review-protected-exclusion").exists)
        XCTAssertTrue(waitForValue("0", element: element(in: app, identifier: "delete-review-submission-count")))
        XCTAssertTrue(waitForValue("1", element: element(in: app, identifier: "delete-review-submission-read-count")))

        app.buttons["delete-review-remove-delete-review-removed"].tap()
        XCTAssertFalse(app.buttons["delete-review-remove-delete-review-removed"].exists)
        XCTAssertTrue(waitForValue("1 项", element: element(in: app, identifier: "delete-review-candidate-count")))
        app.buttons["delete-review-confirm"].tap()
        XCTAssertTrue(app.buttons["delete-review-confirm-final"].waitForExistence(timeout: 3))
        app.buttons["取消"].tap()

        XCTAssertTrue(waitForValue("0", element: element(in: app, identifier: "delete-review-submission-count")))
        XCTAssertTrue(waitForValue("2", element: element(in: app, identifier: "delete-review-submission-read-count")))
    }

    // Production break: exiting review skips its fresh mutator-boundary read or submits a deletion before dismissal.
    @MainActor
    func testDeleteReviewExitKeepsRecordingMutatorAtZeroCalls() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-delete-review"]
        app.launch()

        XCTAssertTrue(app.navigationBars["删除复核"].waitForExistence(timeout: 3))
        XCTAssertTrue(waitForValue("0", element: element(in: app, identifier: "delete-review-submission-count")))
        XCTAssertTrue(waitForValue("1", element: element(in: app, identifier: "delete-review-submission-read-count")))

        app.buttons["delete-review-exit"].tap()
        XCTAssertTrue(app.buttons["delete-review-route"].waitForExistence(timeout: 3))
        app.buttons["delete-review-route"].tap()

        XCTAssertTrue(app.navigationBars["删除复核"].waitForExistence(timeout: 3))
        XCTAssertTrue(waitForValue("0", element: element(in: app, identifier: "delete-review-submission-count")))
        XCTAssertTrue(waitForValue("3", element: element(in: app, identifier: "delete-review-submission-read-count")))
    }

    // Production break: a failed review load is hidden by an automatic second load, leaving no user-initiated retry path.
    @MainActor
    func testDeleteReviewLoadFailureUsesExplicitRetry() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-delete-review-load-failure"]
        app.launch()

        XCTAssertTrue(app.navigationBars["删除复核"].waitForExistence(timeout: 3))
        XCTAssertTrue(element(in: app, identifier: "delete-review-load-failed").waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["delete-review-retry"].exists)

        app.buttons["delete-review-retry"].tap()

        XCTAssertTrue(waitForValue("2 项", element: element(in: app, identifier: "delete-review-candidate-count")))
    }

    // Production break: persisted queue counts lie, visible queue commands mutate the wrong state, or relaunch loses the action results.
    @MainActor
    func testDecisionQueuesPreserveMembershipAcrossRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-queues-reset"]
        app.launch()

        let albumsTab = app.tabBars.buttons["相册"]
        XCTAssertTrue(albumsTab.waitForExistence(timeout: 3))
        albumsTab.tap()
        XCTAssertTrue(element(in: app, identifier: "albums-workspace-list").waitForExistence(timeout: 3))
        XCTAssertTrue(waitForLabel("1", element: element(in: app, identifier: "albums-decide-later-count")))
        XCTAssertTrue(waitForLabel("1", element: element(in: app, identifier: "albums-protected-count")))
        XCTAssertTrue(waitForLabel("0", element: element(in: app, identifier: "queue-fixture-delete-count")))

        element(in: app, identifier: "albums-decide-later").tap()
        XCTAssertTrue(element(in: app, identifier: "decide-later-list").waitForExistence(timeout: 3))
        XCTAssertTrue(element(in: app, identifier: "decision-queue-item-queue-later").exists)
        XCTAssertTrue(app.staticTexts["media-badge-edited-queue-later"].exists)
        app.buttons["decision-defer-again-queue-later"].tap()
        XCTAssertTrue(element(in: app, identifier: "decision-queue-item-queue-later").exists)
        XCTAssertFalse(element(in: app, identifier: "decision-queue-error").exists)

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(waitForLabel("0", element: element(in: app, identifier: "queue-fixture-delete-count")))
        element(in: app, identifier: "albums-protected").tap()
        XCTAssertTrue(element(in: app, identifier: "protected-list").waitForExistence(timeout: 3))
        XCTAssertTrue(element(in: app, identifier: "decision-queue-item-queue-protected").exists)
        XCTAssertTrue(app.staticTexts["media-badge-favorite-queue-protected"].exists)
        XCTAssertTrue(app.staticTexts["media-badge-protected-queue-protected"].exists)
        app.buttons["decision-unprotect-queue-protected"].tap()
        XCTAssertTrue(element(in: app, identifier: "protected-empty").waitForExistence(timeout: 3))
        XCTAssertFalse(element(in: app, identifier: "decision-queue-item-queue-protected").exists)
        XCTAssertFalse(element(in: app, identifier: "decision-queue-error").exists)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(waitForLabel("0", element: element(in: app, identifier: "queue-fixture-delete-count")))

        app.terminate()
        app.launchArguments = ["--ui-testing-queues"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["相册"].waitForExistence(timeout: 3))
        app.tabBars.buttons["相册"].tap()
        XCTAssertTrue(waitForLabel("1", element: element(in: app, identifier: "albums-decide-later-count")))
        XCTAssertTrue(waitForLabel("0", element: element(in: app, identifier: "albums-protected-count")))
        XCTAssertTrue(waitForLabel("0", element: element(in: app, identifier: "queue-fixture-delete-count")))
        XCTAssertTrue(waitForLabel("decideLater", element: element(in: app, identifier: "queue-fixture-later-kind")))
        XCTAssertTrue(waitForLabel("queue-fixture-task", element: element(in: app, identifier: "queue-fixture-later-task")))
        XCTAssertTrue(waitForLabel("1000", element: element(in: app, identifier: "queue-fixture-later-bytes")))
        element(in: app, identifier: "albums-decide-later").tap()
        XCTAssertTrue(element(in: app, identifier: "decision-queue-item-queue-later").waitForExistence(timeout: 3))
    }

    // Production break: root queue failures show false zero counts or empty destinations omit their truthful states.
    @MainActor
    func testDecisionQueueLoadFailureRetriesIntoBothEmptyStates() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-queues-loading"]
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["相册"].waitForExistence(timeout: 3))
        app.tabBars.buttons["相册"].tap()
        XCTAssertTrue(app.staticTexts["正在载入整理队列"].waitForExistence(timeout: 3))
        app.terminate()

        app.launchArguments = ["--ui-testing-queues-load-failure"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["相册"].waitForExistence(timeout: 3))
        app.tabBars.buttons["相册"].tap()
        XCTAssertTrue(element(in: app, identifier: "albums-queue-error").waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["albums-queue-retry"].exists)
        XCTAssertFalse(element(in: app, identifier: "albums-decide-later-count").exists)
        XCTAssertFalse(element(in: app, identifier: "albums-protected-count").exists)

        app.buttons["albums-queue-retry"].tap()
        XCTAssertTrue(waitForLabel("0", element: element(in: app, identifier: "albums-decide-later-count")))
        XCTAssertTrue(waitForLabel("0", element: element(in: app, identifier: "albums-protected-count")))

        element(in: app, identifier: "albums-decide-later").tap()
        XCTAssertTrue(element(in: app, identifier: "decide-later-empty").waitForExistence(timeout: 3))
        app.navigationBars.buttons.firstMatch.tap()
        element(in: app, identifier: "albums-protected").tap()
        XCTAssertTrue(element(in: app, identifier: "protected-empty").waitForExistence(timeout: 3))
    }

    // Production break: result retry resubmits succeeded or stale transaction items instead of exact unresolved IDs.
    @MainActor
    func testCleanupResultsRetrySubmitsOnlyRecordedUnresolvedStableIDs() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-cleanup-results"]
        app.launch()

        XCTAssertTrue(app.navigationBars["整理结果"].waitForExistence(timeout: 3))
        XCTAssertTrue(waitForValue("1 项", element: element(in: app, identifier: "cleanup-results-deleted-count")))
        XCTAssertTrue(waitForValue("1 项", element: element(in: app, identifier: "cleanup-results-unresolved-count")))
        let estimatedSpace = element(in: app, identifier: "cleanup-results-estimated-space")
        XCTAssertTrue(estimatedSpace.label.contains("预计可释放"))
        XCTAssertTrue(waitForValue("1 KB", element: estimatedSpace))
        XCTAssertTrue(waitForValue("1 项", element: element(in: app, identifier: "cleanup-results-archive-count")))
        XCTAssertTrue(waitForValue("1 项", element: element(in: app, identifier: "cleanup-results-protect-count")))
        XCTAssertTrue(waitForValue("1 项", element: element(in: app, identifier: "cleanup-results-deferred-count")))
        XCTAssertTrue(waitForValue("1 项", element: element(in: app, identifier: "cleanup-results-keep-count")))
        XCTAssertTrue(element(in: app, identifier: "cleanup-results-recently-deleted-guidance").exists)

        app.buttons["cleanup-results-retry"].tap()
        XCTAssertTrue(app.buttons["cleanup-results-retry-confirm"].waitForExistence(timeout: 3))
        app.buttons["cleanup-results-retry-confirm"].firstMatch.tap()
        assertAccessibility(
            element(in: app, identifier: "cleanup-results-recorded-retry-ids:result-retry"),
            type: .staticText,
            label: "已提交 1 项未完成请求",
            value: "1 项"
        )
        XCTAssertFalse(element(in: app, identifier: "cleanup-results-retry").exists)
    }

    // Production break: a no-delete summary hides its zero count or makes deletion/duration claims without evidence.
    @MainActor
    func testNoDeleteCleanupSummaryShowsZeroAndTruthfulAggregates() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-cleanup-results-summary"]
        app.launch()

        XCTAssertTrue(app.navigationBars["整理结果"].waitForExistence(timeout: 3))
        XCTAssertTrue(waitForValue("0 项", element: element(in: app, identifier: "cleanup-results-delete-candidate-count")))
        XCTAssertTrue(waitForValue("1 项", element: element(in: app, identifier: "cleanup-results-archive-count")))
        XCTAssertTrue(waitForValue("1 项", element: element(in: app, identifier: "cleanup-results-protect-count")))
        XCTAssertTrue(waitForValue("1 项", element: element(in: app, identifier: "cleanup-results-deferred-count")))
        XCTAssertTrue(waitForValue("1 项", element: element(in: app, identifier: "cleanup-results-keep-count")))
        XCTAssertFalse(element(in: app, identifier: "cleanup-results-recently-deleted-guidance").exists)
        XCTAssertFalse(element(in: app, identifier: "cleanup-results-elapsed").exists)
        XCTAssertFalse(element(in: app, identifier: "cleanup-results-retry").exists)
        assertZeroLifecycleNotificationEffects(in: app)
    }

    // Production break: a cleanup-child lifecycle side effect after the root snapshot remains hidden from the final probe.
    @MainActor
    func testCleanupBoundaryRefreshesNotificationRecordingAfterChildLifecycle() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-cleanup-results-summary",
            "--ui-testing-lifecycle-cleanup-schedule-side-effect"
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["整理结果"].waitForExistence(timeout: 3))
        XCTAssertTrue(element(in: app, identifier: "cleanup-results-delete-candidate-count").waitForExistence(timeout: 3))
        assertLifecycleNotificationEffects(
            authorizationRequests: 0,
            scheduledRequests: 1,
            in: app
        )
    }

    // Production break: Delete Review bypasses Result, Result retry skips native confirmation,
    // or retry resubmits an item that succeeded, became stale, or was removed during review.
    @MainActor
    func testDeleteReviewPartialResultRetriesOnlyUnresolvedIDsAfterConfirmation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-cleanup-results-production"]
        app.launch()

        XCTAssertTrue(app.navigationBars["删除复核"].waitForExistence(timeout: 3))
        XCTAssertTrue(waitForValue("4 项", element: element(in: app, identifier: "delete-review-candidate-count")))
        app.buttons["delete-review-remove-production-removed"].tap()
        XCTAssertTrue(waitForValue("3 项", element: element(in: app, identifier: "delete-review-candidate-count")))

        app.buttons["delete-review-confirm"].tap()
        XCTAssertTrue(app.buttons["delete-review-confirm-final"].waitForExistence(timeout: 3))
        app.buttons["delete-review-confirm-final"].firstMatch.tap()

        XCTAssertTrue(app.navigationBars["整理结果"].waitForExistence(timeout: 3))
        XCTAssertTrue(waitForValue("1 项", element: element(in: app, identifier: "cleanup-results-deleted-count")))
        XCTAssertTrue(waitForValue("1 项", element: element(in: app, identifier: "cleanup-results-unresolved-count")))
        XCTAssertTrue(waitForValue("1 项", element: element(in: app, identifier: "cleanup-results-stale-count")))
        XCTAssertTrue(waitForValue("1", element: element(in: app, identifier: "cleanup-results-recorded-retry-count")))
        XCTAssertFalse(app.navigationBars["整理结果"].buttons["删除复核"].exists)
        app.swipeRight()
        XCTAssertTrue(app.navigationBars["整理结果"].exists)
        XCTAssertFalse(app.navigationBars["删除复核"].exists)

        app.buttons["cleanup-results-retry"].tap()
        let retryDismissRegion = app.otherElements["PopoverDismissRegion"]
        XCTAssertTrue(retryDismissRegion.waitForExistence(timeout: 3))
        retryDismissRegion.tap()

        XCTAssertTrue(app.navigationBars["整理结果"].exists)
        XCTAssertTrue(waitForValue("1", element: element(in: app, identifier: "cleanup-results-recorded-retry-count")))

        app.buttons["cleanup-results-retry"].tap()
        XCTAssertTrue(app.buttons["cleanup-results-retry-confirm"].waitForExistence(timeout: 3))
        app.buttons["cleanup-results-retry-confirm"].firstMatch.tap()

        XCTAssertTrue(waitForValue("2", element: element(in: app, identifier: "cleanup-results-recorded-retry-count")))
        assertAccessibility(
            element(in: app, identifier: "cleanup-results-recorded-retry-ids:production-retry"),
            type: .staticText,
            label: "已提交 1 项未完成请求",
            value: "1 项"
        )
        XCTAssertFalse(element(in: app, identifier: "cleanup-results-retry").exists)

        app.buttons["cleanup-results-return"].tap()
        assertCleanupHome(in: app)
        navigateToWeeklyInbox(in: app)
        XCTAssertTrue(app.navigationBars["本周收件箱"].waitForExistence(timeout: 3))
        XCTAssertTrue(
            element(in: app, identifier: "weekly-inbox-list").exists
                || element(in: app, identifier: "weekly-tidy-empty").exists
        )
        XCTAssertFalse(app.navigationBars["删除复核"].exists)
    }

    // Production break: weekly mode restores into a placeholder or displays injected labels instead of generated work.
    @MainActor
    func testWeeklyInboxRestoresGeneratedWorkAndStartsExistingTaskRoute() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-weekly-work"]
        app.launch()

        XCTAssertTrue(app.navigationBars["本周收件箱"].waitForExistence(timeout: 3))
        XCTAssertTrue(element(in: app, identifier: "weekly-inbox-list").waitForExistence(timeout: 3))
        XCTAssertTrue(waitForValue("3 项", element: element(in: app, identifier: "weekly-task-count")))
        XCTAssertTrue(waitForValue("约 3 分钟", element: element(in: app, identifier: "weekly-duration")))
        XCTAssertTrue(waitForValue("0%", element: element(in: app, identifier: "weekly-progress")))
        XCTAssertTrue(element(in: app, identifier: "weekly-source-weekly:1:weekly-expired").exists)
        XCTAssertTrue(element(in: app, identifier: "weekly-source-weekly:2:weekly-new").exists)
        XCTAssertTrue(element(in: app, identifier: "weekly-source-deferred:weekly-deferred").exists)

        app.buttons["weekly-start-weekly:1:weekly-expired"].tap()

        XCTAssertTrue(app.navigationBars["整理照片"].waitForExistence(timeout: 3))
        XCTAssertTrue(element(in: app, identifier: "decision-position").exists)
    }

    // Production break: an empty weekly period fabricates work or offers no refresh/return path.
    @MainActor
    func testWeeklyInboxShowsTruthfulTidyEmptyState() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-weekly-empty"]
        app.launch()

        XCTAssertTrue(app.navigationBars["本周收件箱"].waitForExistence(timeout: 3))
        XCTAssertTrue(element(in: app, identifier: "weekly-tidy-empty").waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["本周已整理好"].exists)
        XCTAssertFalse(element(in: app, identifier: "weekly-task-count").exists)
        XCTAssertTrue(app.buttons["weekly-refresh-empty"].exists)

        app.buttons["weekly-refresh-empty"].tap()

        XCTAssertTrue(element(in: app, identifier: "weekly-tidy-empty").waitForExistence(timeout: 3))
    }

    // Production break: a due deferred item opens a weekly-only placeholder instead of its persisted queue record.
    @MainActor
    func testWeeklyDeferredItemUsesExistingDecideLaterQueue() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-weekly-work"]
        app.launch()

        XCTAssertTrue(app.navigationBars["本周收件箱"].waitForExistence(timeout: 3))
        let deferred = app.buttons["weekly-start-deferred:weekly-deferred"]
        XCTAssertTrue(deferred.waitForExistence(timeout: 3))
        if !deferred.isHittable { app.swipeUp() }
        deferred.tap()

        XCTAssertTrue(app.navigationBars["稍后决定"].waitForExistence(timeout: 3))
        XCTAssertTrue(element(in: app, identifier: "decision-queue-item-weekly-deferred").exists)
    }

    // Production break: an initial repository read failure has no production-routed retry recovery.
    @MainActor
    func testWeeklyInboxInitialRepositoryFailureRetriesIntoRealWork() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-weekly-load-failure"]
        app.launch()

        XCTAssertTrue(app.navigationBars["本周收件箱"].waitForExistence(timeout: 3))
        XCTAssertTrue(element(in: app, identifier: "weekly-load-retry").waitForExistence(timeout: 3))
        XCTAssertFalse(element(in: app, identifier: "weekly-tidy-empty").exists)

        app.buttons["weekly-load-retry"].tap()

        XCTAssertTrue(element(in: app, identifier: "weekly-inbox-list").waitForExistence(timeout: 3))
        XCTAssertTrue(waitForValue("3 项", element: element(in: app, identifier: "weekly-task-count")))
    }

    // Production break: a whole task above five minutes is presented as a tidy week.
    @MainActor
    func testWeeklyInboxOverLimitWorkDoesNotClaimTidy() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-weekly-over-limit"]
        app.launch()

        XCTAssertTrue(app.navigationBars["本周收件箱"].waitForExistence(timeout: 3))
        XCTAssertTrue(element(in: app, identifier: "weekly-work-over-limit").waitForExistence(timeout: 3))
        XCTAssertFalse(element(in: app, identifier: "weekly-tidy-empty").exists)
        XCTAssertTrue(app.buttons["weekly-return-to-tasks"].exists)

        app.buttons["weekly-return-to-tasks"].tap()
        assertCleanupHome(in: app)
    }

    // Production break: a permanently failing weekly setting traps Result with no explicit non-success exit.
    @MainActor
    func testWeeklyTransitionFailureRetriesFromResultBeforeReturn() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-weekly-transition-failure"]
        app.launch()

        XCTAssertTrue(app.navigationBars["整理结果"].waitForExistence(timeout: 3))
        XCTAssertTrue(element(in: app, identifier: "cleanup-results-persistence-warning").waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["cleanup-results-weekly-retry"].exists)

        app.buttons["cleanup-results-weekly-retry"].tap()
        XCTAssertTrue(element(in: app, identifier: "cleanup-results-persistence-warning").waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["cleanup-results-weekly-retry"].exists)
        let exit = app.buttons["cleanup-results-weekly-exit"]
        XCTAssertTrue(exit.waitForExistence(timeout: 3))
        XCTAssertTrue(waitForLabel("暂不启用每周整理并返回", element: exit))
        exit.tap()

        assertCleanupHome(in: app)
        XCTAssertFalse(app.navigationBars["本周收件箱"].exists)
    }

    // Production break: Statistics full rescan restores a weekly-origin descendant when re-entering legacy tasks.
    @MainActor
    func testWeeklyFullRescanReentersTaskDashboardWithoutWeeklyRoute() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-weekly-work"]
        app.launch()

        XCTAssertTrue(app.navigationBars["本周收件箱"].waitForExistence(timeout: 3))
        app.buttons["weekly-start-weekly:1:weekly-expired"].tap()
        XCTAssertTrue(app.navigationBars["整理照片"].waitForExistence(timeout: 3))
        navigateToStatistics(in: app)
        app.buttons["完整重新扫描"].tap()
        navigateToTaskDashboard(in: app)

        XCTAssertTrue(element(in: app, identifier: "task-inbox-list").waitForExistence(timeout: 3))
        XCTAssertFalse(element(in: app, identifier: "weekly-inbox-list").exists)
    }

    // Production break: Statistics hides aggregate estimates, rescan changes local
    // history or mutator composition, or cancel/confirm clear mutates the simulated inventory.
    @MainActor
    func testStatisticsShowsMetricsRescansAndClearsOnlyLocalHistory() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-statistics"]
        app.launch()

        navigateToStatistics(in: app)
        XCTAssertTrue(app.navigationBars["统计"].waitForExistence(timeout: 3))
        let inventoryBefore = assertExactStatisticsInventory(in: app)
        let clearCallCount = element(in: app, identifier: "statistics-clear-call-count")
        XCTAssertTrue(reveal(clearCallCount, in: app, upward: true))
        XCTAssertTrue(waitForValue("0", element: clearCallCount))

        revealTop(in: app)
        XCTAssertTrue(waitForValue("0", element: element(in: app, identifier: "statistics-new-items")))
        XCTAssertTrue(waitForValue("5", element: element(in: app, identifier: "statistics-processed-items")))
        XCTAssertTrue(waitForValue("1", element: element(in: app, identifier: "statistics-archives")))
        XCTAssertTrue(waitForValue("1", element: element(in: app, identifier: "statistics-protections")))
        XCTAssertTrue(waitForValue("1", element: element(in: app, identifier: "statistics-deferrals")))
        XCTAssertTrue(waitForValue("1", element: element(in: app, identifier: "statistics-reviewed-deletions")))
        XCTAssertTrue(waitForValue("4 KB", element: element(in: app, identifier: "statistics-estimated-space")))
        XCTAssertTrue(waitForValue("1 / 2", element: element(in: app, identifier: "statistics-task-trend")))
        XCTAssertTrue(element(in: app, identifier: "statistics-estimated-wording").exists)
        XCTAssertTrue(reveal(element(in: app, identifier: "statistics-icloud-estimate"), in: app, upward: true))
        XCTAssertTrue(reveal(app.buttons["statistics-full-rescan"], in: app, upward: true))
        app.buttons["statistics-full-rescan"].tap()
        revealTop(in: app)
        XCTAssertTrue(waitForValue("5", element: element(in: app, identifier: "statistics-processed-items")))

        XCTAssertTrue(reveal(app.buttons["statistics-clear-history"], in: app, upward: true))
        XCTAssertTrue(reveal(app.buttons["statistics-clear-history"], in: app, upward: true))
        app.buttons["statistics-clear-history"].tap()
        XCTAssertTrue(app.sheets["清除本机整理历史？"].waitForExistence(timeout: 3))
        // The native compact confirmation dialog exposes its cancel action as this system control.
        let nativeCancel = app.otherElements["PopoverDismissRegion"]
        XCTAssertTrue(nativeCancel.waitForExistence(timeout: 3))
        nativeCancel.tap()
        revealTop(in: app)
        XCTAssertTrue(reveal(element(in: app, identifier: "statistics-processed-items"), in: app, upward: false))
        XCTAssertTrue(reveal(clearCallCount, in: app, upward: true))
        XCTAssertTrue(waitForValue("0", element: clearCallCount))
        XCTAssertEqual(assertExactStatisticsInventory(in: app), inventoryBefore)

        XCTAssertTrue(reveal(app.buttons["statistics-clear-history"], in: app, upward: true))
        app.buttons["statistics-clear-history"].tap()
        let confirm = app.sheets.buttons["清除本机整理历史"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.firstMatch.tap()
        XCTAssertTrue(element(in: app, identifier: "statistics-no-history").waitForExistence(timeout: 3))
        XCTAssertTrue(reveal(clearCallCount, in: app, upward: true))
        XCTAssertTrue(waitForValue("1", element: clearCallCount))
        XCTAssertEqual(assertExactStatisticsInventory(in: app), inventoryBefore)
    }

    @MainActor
    func testStatisticsClearFailureRetainsHistoryThenRetriesExactlyOnce() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-statistics-clear-failure"]
        app.launch()

        navigateToStatistics(in: app)
        let inventoryBefore = assertExactStatisticsInventory(in: app)
        XCTAssertTrue(reveal(app.buttons["statistics-clear-history"], in: app, upward: true))
        app.buttons["statistics-clear-history"].tap()
        XCTAssertTrue(app.sheets.buttons["清除本机整理历史"].waitForExistence(timeout: 3))
        app.sheets.buttons["清除本机整理历史"].firstMatch.tap()
        XCTAssertTrue(element(in: app, identifier: "statistics-clear-failure").waitForExistence(timeout: 3))
        XCTAssertTrue(reveal(element(in: app, identifier: "statistics-processed-items"), in: app, upward: false))
        let clearCallCount = element(in: app, identifier: "statistics-clear-call-count")
        XCTAssertTrue(reveal(clearCallCount, in: app, upward: true))
        XCTAssertTrue(waitForValue("1", element: clearCallCount))
        XCTAssertEqual(assertExactStatisticsInventory(in: app), inventoryBefore)
        XCTAssertTrue(reveal(app.buttons["statistics-clear-retry"], in: app, upward: true))
        app.buttons["statistics-clear-retry"].tap()
        XCTAssertTrue(element(in: app, identifier: "statistics-no-history").waitForExistence(timeout: 3))
        XCTAssertTrue(reveal(clearCallCount, in: app, upward: true))
        XCTAssertTrue(waitForValue("2", element: clearCallCount))
        XCTAssertEqual(assertExactStatisticsInventory(in: app), inventoryBefore)
    }

    @MainActor
    func testStatisticsCancelledRescanOffersResumeRecovery() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-statistics-rescan-cancelled"]
        app.launch()

        navigateToStatistics(in: app)
        let fullRescan = app.buttons["statistics-full-rescan"]
        revealTop(in: app)
        XCTAssertTrue(waitForValue("5", element: element(in: app, identifier: "statistics-processed-items")))
        XCTAssertTrue(reveal(element(in: app, identifier: "statistics-rescan-cancelled"), in: app, upward: true))
        XCTAssertTrue(reveal(app.buttons["statistics-rescan-resume"], in: app, upward: true))
        XCTAssertTrue(waitForValue("扫描已取消", element: fullRescan))
        app.buttons["statistics-rescan-resume"].tap()
        XCTAssertTrue(reveal(fullRescan, in: app, upward: true))
        XCTAssertTrue(waitForValue("扫描已完成", element: fullRescan))
        XCTAssertFalse(element(in: app, identifier: "statistics-rescan-cancelled").exists)
        revealTop(in: app)
        XCTAssertTrue(waitForValue("5", element: element(in: app, identifier: "statistics-processed-items")))
    }

    @MainActor
    func testStatisticsFailedRescanOffersRetryRecovery() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-statistics-rescan-failed"]
        app.launch()

        navigateToStatistics(in: app)
        let fullRescan = app.buttons["statistics-full-rescan"]
        revealTop(in: app)
        XCTAssertTrue(waitForValue("5", element: element(in: app, identifier: "statistics-processed-items")))
        XCTAssertTrue(reveal(element(in: app, identifier: "statistics-rescan-failed"), in: app, upward: true))
        XCTAssertTrue(reveal(app.buttons["statistics-rescan-retry"], in: app, upward: true))
        XCTAssertTrue(waitForValue("扫描失败", element: fullRescan))
        app.buttons["statistics-rescan-retry"].tap()
        XCTAssertTrue(reveal(fullRescan, in: app, upward: true))
        XCTAssertTrue(waitForValue("扫描已完成", element: fullRescan))
        XCTAssertFalse(element(in: app, identifier: "statistics-rescan-failed").exists)
        revealTop(in: app)
        XCTAssertTrue(waitForValue("5", element: element(in: app, identifier: "statistics-processed-items")))
    }

    @MainActor
    func testSettingsReminderIsGatedUntilMeaningfulCleanup() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-settings-locked"]
        app.launch()

        navigateToSettings(in: app)

        let reminder = app.switches["settings.reminderEnabled"]
        XCTAssertTrue(reminder.waitForExistence(timeout: 3))
        XCTAssertFalse(reminder.isEnabled)
        XCTAssertTrue(element(in: app, identifier: "settings.reminderLockedReason").exists)
        XCTAssertTrue(reveal(element(in: app, identifier: "settings.privacyLocalOnly"), in: app, upward: true))
        XCTAssertTrue(reveal(element(in: app, identifier: "settings.privacyGenericReminder"), in: app, upward: true))
    }

    @MainActor
    func testSettingsGrantedReminderReplacesWeekdayAndDisables() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-settings-granted"]
        app.launch()

        navigateToSettings(in: app)
        let reminder = app.switches["settings.reminderEnabled"]
        XCTAssertTrue(reminder.waitForExistence(timeout: 3))
        tapSwitch(reminder)
        XCTAssertTrue(waitForValue("1", element: reminder))

        let weekday = element(in: app, identifier: "settings.reminderWeekday")
        XCTAssertTrue(weekday.waitForExistence(timeout: 3))
        weekday.tap()
        XCTAssertTrue(app.buttons["星期一"].waitForExistence(timeout: 3))
        app.buttons["星期一"].tap()
        revealTop(in: app)
        tapSwitch(app.switches["settings.reminderEnabled"])
        XCTAssertTrue(waitForValue("0", element: app.switches["settings.reminderEnabled"]))

        XCTAssertTrue(reveal(element(in: app, identifier: "settings.recordedReminderCount"), in: app, upward: true))
        XCTAssertTrue(waitForLabel("授权请求, 1", element: element(in: app, identifier: "settings.recordedAuthorizationRequests")))
        XCTAssertTrue(waitForLabel("待处理提醒, 0", element: element(in: app, identifier: "settings.recordedReminderCount")))
        XCTAssertTrue(waitForLabel("最后提醒日期, 2", element: element(in: app, identifier: "settings.recordedReminderWeekday")))
        XCTAssertTrue(waitForLabel("移除次数, 1", element: element(in: app, identifier: "settings.recordedRemovalCount")))
    }

    @MainActor
    func testSettingsDeniedReminderShowsRecoveryWithoutScheduling() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-settings-denied"]
        app.launch()

        navigateToSettings(in: app)
        let reminder = app.switches["settings.reminderEnabled"]
        XCTAssertTrue(reminder.waitForExistence(timeout: 3))
        tapSwitch(reminder)

        let guidance = element(in: app, identifier: "settings.reminderGuidance")
        XCTAssertTrue(guidance.waitForExistence(timeout: 3))
        XCTAssertEqual(
            guidance.label,
            "通知未获允许。你仍可使用每周整理，并可在系统设置中开启通知。"
        )
        XCTAssertTrue(waitForValue("0", element: reminder))
        XCTAssertTrue(element(in: app, identifier: "settings.openNotificationSettings").exists)
        XCTAssertTrue(reveal(element(in: app, identifier: "settings.recordedAuthorizationRequests"), in: app, upward: true))
        XCTAssertTrue(waitForLabel("授权请求, 0", element: element(in: app, identifier: "settings.recordedAuthorizationRequests")))
        XCTAssertTrue(waitForLabel("待处理提醒, 0", element: element(in: app, identifier: "settings.recordedReminderCount")))
    }

    @MainActor
    func testSettingsScreenshotPersistenceFailureRollsBackWithoutRescan() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-settings-screenshot-failure"]
        app.launch()

        navigateToSettings(in: app)
        let threshold = element(in: app, identifier: "settings.screenshotThreshold")
        XCTAssertTrue(waitForValue("30 天", element: threshold))
        XCTAssertTrue(reveal(element(in: app, identifier: "settings.recordedScanCount"), in: app, upward: true))
        let initialScans = element(in: app, identifier: "settings.recordedScanCount").label

        revealTop(in: app)
        XCTAssertTrue(app.buttons["7 天"].waitForExistence(timeout: 3))
        app.buttons["7 天"].tap()

        XCTAssertTrue(waitForValue("30 天", element: threshold))
        let recovery = element(in: app, identifier: "settings.screenshotPersistenceError")
        XCTAssertTrue(recovery.waitForExistence(timeout: 3))
        XCTAssertEqual(recovery.label, "无法保存截图提醒天数。请重试；当前设置未更改。")
        XCTAssertTrue(reveal(element(in: app, identifier: "settings.recordedScanCount"), in: app, upward: true))
        XCTAssertEqual(element(in: app, identifier: "settings.recordedScanCount").label, initialScans)
    }

    @MainActor
    func testSettingsDoesNotMislabelUnrelatedPersistenceFailureAsScreenshotRecovery() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-settings-unrelated-persistence-error"]
        app.launch()

        navigateToSettings(in: app)
        XCTAssertTrue(element(in: app, identifier: "settings.screenshotThreshold").waitForExistence(timeout: 3))
        XCTAssertFalse(element(in: app, identifier: "settings.screenshotPersistenceError").exists)
    }

    // Production break: an off Toggle cannot retry removal for a disabled model with a pending request.
    @MainActor
    func testSettingsRetriesDisabledReminderMismatchUntilRemovalSucceeds() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-settings-disabled-mismatch"]
        app.launch()

        navigateToSettings(in: app)
        let retry = app.buttons["settings.retryReminderSynchronization"]
        XCTAssertTrue(retry.waitForExistence(timeout: 3))
        XCTAssertTrue(waitForValue("0", element: app.switches["settings.reminderEnabled"]))
        XCTAssertTrue(reveal(element(in: app, identifier: "settings.recordedReminderCount"), in: app, upward: true))
        XCTAssertTrue(waitForLabel("待处理提醒, 1", element: element(in: app, identifier: "settings.recordedReminderCount")))

        revealTop(in: app)
        retry.tap()
        XCTAssertTrue(retry.waitForExistence(timeout: 3))
        XCTAssertTrue(reveal(element(in: app, identifier: "settings.recordedReminderCount"), in: app, upward: true))
        XCTAssertTrue(waitForLabel("待处理提醒, 1", element: element(in: app, identifier: "settings.recordedReminderCount")))

        revealTop(in: app)
        retry.tap()
        XCTAssertTrue(reveal(element(in: app, identifier: "settings.recordedReminderCount"), in: app, upward: true))
        XCTAssertTrue(waitForLabel("待处理提醒, 0", element: element(in: app, identifier: "settings.recordedReminderCount")))
        revealTop(in: app)
        XCTAssertFalse(retry.exists)
        XCTAssertTrue(waitForValue("0", element: app.switches["settings.reminderEnabled"]))
    }

    @MainActor
    func testSettingsThresholdRescansWithoutChangingReminderOrDebugMode() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-settings-granted"]
        app.launch()

        navigateToSettings(in: app)
        XCTAssertTrue(reveal(element(in: app, identifier: "settings.mutationMode"), in: app, upward: true))
        XCTAssertTrue(waitForLabel("照片变更模式, 模拟模式（不会修改系统照片）", element: element(in: app, identifier: "settings.mutationMode")))
        XCTAssertTrue(reveal(element(in: app, identifier: "settings.recordedScanCount"), in: app, upward: true))
        let initialScans = element(in: app, identifier: "settings.recordedScanCount").label
        revealTop(in: app)
        XCTAssertTrue(app.buttons["7 天"].waitForExistence(timeout: 3))
        app.buttons["7 天"].tap()
        XCTAssertTrue(waitForValue("7 天", element: element(in: app, identifier: "settings.screenshotThreshold")))
        XCTAssertTrue(reveal(element(in: app, identifier: "settings.recordedReminderCount"), in: app, upward: true))
        XCTAssertTrue(waitForLabel("待处理提醒, 0", element: element(in: app, identifier: "settings.recordedReminderCount")))
        XCTAssertTrue(waitForLabelDifferent(
            from: initialScans,
            element: element(in: app, identifier: "settings.recordedScanCount")
        ))
        XCTAssertTrue(waitForLabel("照片变更模式, 模拟模式（不会修改系统照片）", element: element(in: app, identifier: "settings.mutationMode")))
    }

    // Production break: stable pre-audit selectors move from their original
    // static-text/image owners when richer accessibility containers are added.
    @MainActor
    func testAccessibilitySelectorCompatibilityUsesStableOwners() throws {
        var app = launchP0Fixture(arguments: ["--ui-testing-diagnosis"])
        navigateToTaskDashboard(in: app)
        assertAccessibilityManifest([
            .init("diagnosis-task-low-risk", .staticText, "处理过期截图", value: "2 项，约 2 分钟，低风险，预计可释放 32 MB，超过 30 天且未标记为收藏"),
            .init("diagnosis-task-high-risk", .staticText, "检查相似照片", value: "3 项，约 8 分钟，高风险，预计可释放 8 GB，相似度较低，需要逐组确认")
        ], in: app)
        app.terminate()

        app = launchP0Fixture(arguments: ["--ui-testing-accessibility-empty"])
        navigateToTaskDashboard(in: app)
        assertExactHealthyLibraryEmptySemantics(in: app)
        app.terminate()

        app = launchP0Fixture(arguments: ["--ui-testing-media"])
        assertAccessibilityManifest([
            .init("media-thumbnail-loading-media-loading-video", .staticText, "正在载入缩略图"),
            .init("media-badge-video-media-loading-video", .staticText, "视频")
        ], in: app)

        app.buttons["media-next-page"].tap()
        assertAccessibilityManifest([
            .init("media-thumbnail-unavailable-media-unavailable", .staticText, "无法载入此缩略图")
        ], in: app)

        for (thumbnailIdentifier, badgeIdentifier, label) in [
            ("media-thumbnail-loaded-media-live", "media-badge-live-photo-media-live", "实况照片"),
            ("media-thumbnail-loaded-media-panorama", "media-badge-panorama-media-panorama", "全景照片"),
            ("media-thumbnail-loaded-media-favorite", "media-badge-favorite-media-favorite", "已收藏"),
            ("media-thumbnail-loaded-media-edited", "media-badge-edited-media-edited", "已编辑"),
            ("media-thumbnail-loaded-media-protected", "media-badge-protected-media-protected", "已保护")
        ] {
            app.buttons["media-next-page"].tap()
            XCTAssertTrue(app.images[thumbnailIdentifier].waitForExistence(timeout: 3))
            XCTAssertEqual(app.images[thumbnailIdentifier].label, "缩略图已载入")
            assertAccessibilityManifest([
                .init(badgeIdentifier, .staticText, label)
            ], in: app)
        }
        app.terminate()
    }

    // Production break: the route-level loading owner masks missing semantics
    // on the rendered CleanupResultsScreen loading owner.
    @MainActor
    func testCleanupResultsLoadingHasExactSemanticsBeforeSettlement() throws {
        let app = launchP0Fixture(arguments: ["--ui-testing-cleanup-results-loading"])
        assertSingleAccessibilityOwner(
            .init(
                "cleanup-results-loading",
                .activityIndicator,
                "正在载入整理结果",
                value: "正在读取本地整理记录"
            ),
            in: app
        )
        assertUniqueAccessibilityIdentifiers(in: app)
        assertAccessibilityManifest([
            .init("cleanup-results-return", .button, "返回任务", enabled: true)
        ], in: app)

        XCTAssertTrue(
            element(in: app, identifier: "cleanup-results-deleted-count")
                .waitForExistence(timeout: 8)
        )
        assertAccessibilityManifest([
            .init("cleanup-results-deleted-count", .other, "已移到最近删除", value: "1 项"),
            .init("cleanup-results-return", .button, "返回任务", enabled: true)
        ], in: app)
    }

    // Production break: a required read fails before any prior projection exists,
    // but the rendered state has no exact recovery contract or cannot recover.
    @MainActor
    func testAccessibilityFailureRecoveryMatrixCoversStatisticsAndCleanupResults() throws {
        var app = launchP0Fixture(arguments: ["--ui-testing-statistics-read-failure"])
        navigateToStatistics(in: app)
        assertAccessibilityManifest([
            .init("statistics-read-failure", .other, "无法读取统计", value: "无法读取本地整理记录，请重试。"),
            .init("statistics-retry", .button, "重试", enabled: true)
        ], in: app)
        app.buttons["statistics-retry"].tap()
        assertAccessibilityManifest([
            .init("statistics-processed-items", .other, "已处理项目", value: "5")
        ], in: app)
        app.terminate()

        app = launchP0Fixture(arguments: ["--ui-testing-cleanup-results-missing"])
        assertAccessibilityManifest([
            .init("cleanup-results-missing", .other, "无法显示整理结果", value: "找不到这次整理记录。请返回任务列表。"),
            .init("cleanup-results-reload", .button, "重新载入", enabled: true),
            .init("cleanup-results-return", .button, "返回任务", enabled: true)
        ], in: app)
        app.buttons["cleanup-results-reload"].tap()
        assertAccessibilityManifest([
            .init("cleanup-results-missing", .other, "无法显示整理结果", value: "找不到这次整理记录。请返回任务列表。"),
            .init("cleanup-results-reload", .button, "重新载入", enabled: true),
            .init("cleanup-results-return", .button, "返回任务", enabled: true)
        ], in: app)
        app.buttons["cleanup-results-return"].tap()
        assertCleanupHome(in: app)
        XCTAssertFalse(element(in: app, identifier: "cleanup-results-missing").exists)
        app.terminate()

        app = launchP0Fixture(arguments: ["--ui-testing-cleanup-results-load-failure"])
        assertAccessibilityManifest([
            .init("cleanup-results-failed", .other, "无法显示整理结果", value: "无法读取这次整理结果。请重试或返回任务列表。"),
            .init("cleanup-results-reload", .button, "重新载入", enabled: true),
            .init("cleanup-results-return", .button, "返回任务", enabled: true)
        ], in: app)
        app.buttons["cleanup-results-return"].tap()
        assertCleanupHome(in: app)
        XCTAssertFalse(element(in: app, identifier: "cleanup-results-failed").exists)
        app.terminate()

        app = launchP0Fixture(arguments: ["--ui-testing-cleanup-results-load-failure"])
        assertAccessibilityManifest([
            .init("cleanup-results-failed", .other, "无法显示整理结果", value: "无法读取这次整理结果。请重试或返回任务列表。"),
            .init("cleanup-results-reload", .button, "重新载入", enabled: true),
            .init("cleanup-results-return", .button, "返回任务", enabled: true)
        ], in: app)
        app.buttons["cleanup-results-reload"].tap()
        assertAccessibilityManifest([
            .init("cleanup-results-deleted-count", .other, "已移到最近删除", value: "1 项"),
            .init("cleanup-results-return", .button, "返回任务", enabled: true)
        ], in: app)
        XCTAssertFalse(element(in: app, identifier: "cleanup-results-failed").exists)
        XCTAssertFalse(element(in: app, identifier: "cleanup-results-reload").exists)
        app.buttons["cleanup-results-return"].tap()
        assertCleanupHome(in: app)
        app.terminate()
    }

    @MainActor
    func testAccessibilityMirrorContractsMatchExactSwiftUIRepresentations() throws {
        var app = launchP0Fixture(arguments: ["--ui-testing-archive"])
        app.buttons["decision-archive"].tap()
        assertVerifiedSwiftUIMirror(identifier: "album-create-command", in: app)
        app.buttons["album-create-command"].tap()
        assertVerifiedSwiftUIMirror(identifier: "album-create-command", in: app)
        assertVerifiedSwiftUIMirror(identifier: "album-create-cancel", in: app)
        assertVerifiedSwiftUIMirror(identifier: "album-create-confirm", in: app)
        app.terminate()

        app = launchP0Fixture(arguments: ["--ui-testing-weekly-load-failure"])
        assertVerifiedSwiftUIMirror(identifier: "weekly-refresh", in: app)
        app.terminate()

        app = launchP0Fixture(arguments: ["--ui-testing-delete-review"])
        assertVerifiedSwiftUIMirror(identifier: "delete-review-exit", in: app)
        app.buttons["delete-review-confirm"].tap()
        assertVerifiedSwiftUIMirror(identifier: "delete-review-exit", in: app)
        assertVerifiedSwiftUIMirror(identifier: "delete-review-confirm-final", in: app)
        app.terminate()

        app = launchP0Fixture(arguments: ["--ui-testing-cleanup-results"])
        assertVerifiedSwiftUIMirror(identifier: "cleanup-results-return", in: app)
        app.buttons["cleanup-results-retry"].tap()
        assertVerifiedSwiftUIMirror(identifier: "cleanup-results-return", in: app)
        assertVerifiedSwiftUIMirror(identifier: "cleanup-results-retry-confirm", in: app)
        app.terminate()
    }

    // Production break: a P0 control loses its native title/accessibility label,
    // or exposes a private fixture/media identifier as spoken text.
    @MainActor
    func testAccessibilityAuditFindsNoUnusableActionLabelsAcrossP0Fixtures() throws {
        auditP0Fixture(arguments: ["--ui-testing-not-determined"]) { app in
            assertAccessibilityManifest([
                .init("permission-request", .button, "允许访问照片", enabled: true)
            ], in: app)
        }
        auditP0Fixture(arguments: ["--ui-testing-denied"]) { app in
            assertAccessibilityManifest([
                .init("permission-denied-state", .other, "照片访问状态", value: "未允许访问照片"),
                .init("permission-open-settings", .button, "打开系统设置", enabled: true)
            ], in: app)
        }
        auditP0Fixture(arguments: ["--ui-testing-restricted"]) { app in
            assertAccessibilityManifest([
                .init("permission-restricted-state", .other, "照片访问状态", value: "设备限制了照片访问")
            ], in: app)
            XCTAssertFalse(element(in: app, identifier: "permission-open-settings").exists)
        }
        auditP0Fixture(arguments: ["--ui-testing-limited"]) { app in
            navigateToTaskDashboard(in: app)
            assertAccessibilityManifest([
                .init("permission-limited-state", .other, "照片访问范围", value: "部分照片，仅整理已允许的照片"),
                .init("permission-manage-limited", .button, "管理", enabled: true),
                .init("scan-status", .staticText, "扫描状态", value: "部分照片，相册诊断已更新")
            ], in: app)
        }
        auditP0Fixture(arguments: ["--ui-testing-cancelled"]) { app in
            navigateToTaskDashboard(in: app)
            assertAccessibilityManifest([
                .init("scan-status", .staticText, "扫描状态", value: "全部照片，扫描已暂停"),
                .init("scan-resume", .button, "继续扫描", enabled: true),
                .init("scan-restart", .button, "重新开始", enabled: true)
            ], in: app)
        }
        auditP0Fixture(arguments: ["--ui-testing-failed"]) { app in
            navigateToTaskDashboard(in: app)
            assertAccessibilityManifest([
                .init("scan-status", .staticText, "扫描状态", value: "全部照片，无法扫描当前可访问范围"),
                .init("scan-retry", .button, "重试扫描", enabled: true)
            ], in: app)
        }
        auditP0Fixture(arguments: ["--ui-testing-partial"]) { app in
            navigateToTaskDashboard(in: app)
            assertAccessibilityManifest([
                .init("scan-status", .staticText, "扫描状态", value: "全部照片，正在检查本地照片"),
                .init("scan-progress", .progressIndicator, "扫描进度", value: "38%，已处理 3 项，共 8 项"),
                .init("scan-cancel", .button, "取消扫描", enabled: true)
            ], in: app)
        }
        auditP0Fixture(arguments: ["--ui-testing-accessibility-empty"]) { app in
            navigateToTaskDashboard(in: app)
            assertExactHealthyLibraryEmptySemantics(in: app)
        }
        auditP0Fixture(arguments: ["--ui-testing-diagnosis"]) { app in
            navigateToTaskDashboard(in: app)
            assertAccessibilityManifest([
                .init("diagnosis-report", .button, "查看诊断报告", value: "", enabled: true),
                .init("diagnosis-task-low-risk", .staticText, "处理过期截图", value: "2 项，约 2 分钟，低风险，预计可释放 32 MB，超过 30 天且未标记为收藏"),
                .init("diagnosis-task-action-low-risk", .button, "处理过期截图", value: "2 项，约 2 分钟，低风险，预计可释放 32 MB，超过 30 天且未标记为收藏", enabled: true),
                .init("diagnosis-task-high-risk", .staticText, "检查相似照片", value: "3 项，约 8 分钟，高风险，预计可释放 8 GB，相似度较低，需要逐组确认"),
                .init("diagnosis-task-action-high-risk", .button, "检查相似照片", value: "3 项，约 8 分钟，高风险，预计可释放 8 GB，相似度较低，需要逐组确认", enabled: true)
            ], in: app)
            app.buttons["diagnosis-report"].tap()
            assertAccessibilityManifest([
                .init("diagnosis-current-storage", .staticText, "当前照片存储", value: "128 GB"),
                .init("diagnosis-estimated-reclaimable", .staticText, "预计可释放空间", value: "8.03 GB"),
                .init("diagnosis-report-task-low-risk", .staticText, "处理过期截图", value: "2 项，约 2 分钟，低风险，预计可释放 32 MB，超过 30 天且未标记为收藏"),
                .init("diagnosis-report-task-high-risk", .staticText, "检查相似照片", value: "3 项，约 8 分钟，高风险，预计可释放 8 GB，相似度较低，需要逐组确认"),
                .init("diagnosis-recently-deleted-guidance", .staticText, "删除项目会先移到“最近删除”。从“最近删除”中移除后，iOS 才会永久回收空间。")
            ], in: app)
        }
        auditP0Fixture(arguments: ["--ui-testing-comparison"]) { app in
            assertAccessibilityManifest([
                .init("comparison-inspect-comparison-recommended", .button, "查看第 1 张照片", enabled: true),
                .init("comparison-select-keep-comparison-recommended", .button, "将第 1 张选为保留", value: "已选中", enabled: true, selected: true),
                .init("comparison-select-keep-comparison-chosen", .button, "将第 2 张选为保留", value: "未选中", enabled: true, selected: false)
            ], in: app)
            XCTAssertTrue(reveal(element(in: app, identifier: "comparison-media-comparison-protected"), in: app, upward: true))
            XCTAssertTrue(reveal(app.buttons["comparison-complete-group"], in: app, upward: true))
            assertAccessibilityManifest([
                .init("comparison-complete-group", .button, "完成本组", enabled: true)
            ], in: app)
        }
        auditP0Fixture(arguments: ["--ui-testing-media"]) { app in
            assertAccessibilityManifest([
                .init("media-previous-page", .button, "上一张", enabled: false),
                .init("media-next-page", .button, "下一张", enabled: true)
            ], in: app)
            app.buttons["media-next-page"].tap()
            assertAccessibilityManifest([
                .init("media-previous-page", .button, "上一张", enabled: true),
                .init("media-next-page", .button, "下一张", enabled: true)
            ], in: app)
        }
        auditP0Fixture(arguments: ["--ui-testing-decision"]) { app in
            assertAccessibilityManifest([
                .init("decision-keep", .button, "保留", enabled: true),
                .init("decision-delete", .button, "删除", enabled: true),
                .init("decision-archive", .button, "归档", enabled: true),
                .init("decision-protect", .button, "保护", enabled: true),
                .init("decision-later", .button, "稍后决定", enabled: true)
            ], in: app)
        }
    }

    // Production break: sheets, destructive dialogs, results, or queue destinations
    // lose exact semantics after they are materialized.
    @MainActor
    func testAccessibilityManifestCoversAlbumsDeleteResultsAndQueues() throws {
        auditP0Fixture(arguments: ["--ui-testing-archive"]) { app in
            app.buttons["decision-archive"].tap()
            assertAccessibilityManifest([
                .init("album-current-asset", .staticText, "当前照片", value: "等待选择归档相册"),
                .init("album-create-command", .button, "新建相册", enabled: true),
                .init("album-recent-row-archive-valid", .button, "选择相册，旅行", value: "包含 0 项", enabled: true),
                .init("album-system-row-archive-missing", .button, "选择相册，会消失的相册", value: "包含 0 项", enabled: true)
            ], in: app)
            app.buttons["album-create-command"].tap()
            assertAccessibilityManifest([
                .init("album-create-name", .textField, "相册名称", enabled: true),
                .init("album-create-cancel", .button, "取消", enabled: true),
                .init("album-create-confirm", .button, "创建", enabled: true)
            ], in: app)
        }
        auditP0Fixture(arguments: ["--ui-testing-archive-create-failure"]) { app in
            app.buttons["decision-archive"].tap()
            app.buttons["album-create-command"].tap()
            let name = app.textFields["album-create-name"]
            XCTAssertTrue(name.waitForExistence(timeout: 3))
            name.tap()
            name.typeText("旅行")
            app.buttons["album-create-confirm"].tap()
            assertAccessibilityManifest([
                .init("album-create-error", .staticText, "无法创建相册，请稍后重试。"),
                .init("album-create-confirm", .button, "创建", enabled: true)
            ], in: app)
        }
        auditP0Fixture(arguments: ["--ui-testing-archive"]) { app in
            app.buttons["decision-archive"].tap()
            app.buttons["album-system-row-archive-missing"].tap()
            assertAccessibilityManifest([
                .init("album-error-guidance", .staticText, "所选相册已不可用，请重新选择其他相册。"),
                .init("album-reselection-action", .button, "重新选择相册", value: "", enabled: true)
            ], in: app)
            app.buttons["album-reselection-action"].tap()
            assertAccessibilityManifest([
                .init("album-recent-row-archive-valid", .button, "选择相册，旅行", value: "包含 0 项", enabled: true)
            ], in: app)
        }
        auditP0Fixture(arguments: ["--ui-testing-delete-review"]) { app in
            assertAccessibilityManifest([
                .init("delete-review-protected-exclusion", .staticText, "已排除 1 项手动保护照片"),
                .init("delete-review-remove-delete-review-removed", .button, "从删除复核中移除此候选", enabled: true),
                .init("delete-review-confirm", .button, "确认删除 2 项", enabled: true)
            ], in: app)
            app.buttons["delete-review-confirm"].tap()
            assertAccessibilityManifest([
                .init("delete-review-confirm-final", .button, "确认删除", enabled: true)
            ], in: app)
        }
        auditP0Fixture(arguments: ["--ui-testing-delete-review-load-failure"]) { app in
            assertAccessibilityManifest([
                .init(
                    "delete-review-load-failed",
                    .other,
                    "无法载入删除复核",
                    value: "无法载入删除复核，请重试。"
                ),
                .init("delete-review-retry", .button, "重新载入", enabled: true),
                .init("delete-review-confirm", .button, "确认删除 0 项", enabled: false)
            ], in: app)
        }
        auditP0Fixture(arguments: ["--ui-testing-cleanup-results"]) { app in
            assertAccessibilityManifest([
                .init("cleanup-results-deleted-count", .other, "已移到最近删除", value: "1 项"),
                .init("cleanup-results-unresolved-count", .other, "未完成，可重试", value: "1 项"),
                .init("cleanup-results-stale-count", .other, "照片已不可用", value: "1 项"),
                .init("cleanup-results-retry", .button, "重试未完成的删除", enabled: true)
            ], in: app)
            app.buttons["cleanup-results-retry"].tap()
            assertAccessibilityManifest([
                .init("cleanup-results-retry-confirm", .button, "确认重试删除", enabled: true)
            ], in: app)
            XCTAssertTrue(app.otherElements["PopoverDismissRegion"].waitForExistence(timeout: 3))
        }
        auditP0Fixture(arguments: ["--ui-testing-queues-reset"]) { app in
            app.tabBars.buttons["相册"].tap()
            assertAccessibilityManifest([
                .init("albums-decide-later", .button, "稍后决定", value: "1 项", enabled: true),
                .init("albums-protected", .button, "已保护", value: "1 项", enabled: true)
            ], in: app)
            element(in: app, identifier: "albums-decide-later").tap()
            assertAccessibilityManifest([
                .init("decision-queue-item-queue-later", .other, "队列照片，预计大小 1 KB，已编辑", value: "稍后决定"),
                .init("decision-defer-again-queue-later", .button, "再次稍后决定", enabled: true)
            ], in: app)
        }
        auditP0Fixture(arguments: ["--ui-testing-queues-reset"]) { app in
            app.tabBars.buttons["相册"].tap()
            element(in: app, identifier: "albums-protected").tap()
            assertAccessibilityManifest([
                .init("decision-queue-item-queue-protected", .other, "队列照片，预计大小 2 KB，已收藏，已保护", value: "已保护"),
                .init("decision-unprotect-queue-protected", .button, "取消保护", enabled: true)
            ], in: app)
        }
    }

    // Production break: queue loading/failure states claim empty counts or omit
    // their exact retry and post-recovery empty semantics.
    @MainActor
    func testAccessibilityManifestCoversQueueLoadingFailureAndEmptyStates() throws {
        auditP0Fixture(arguments: ["--ui-testing-queues-loading"]) { app in
            app.tabBars.buttons["相册"].tap()
            assertAccessibilityManifest([
                .init("albums-queue-loading", .activityIndicator, "正在载入整理队列")
            ], in: app)
        }
        auditP0Fixture(arguments: ["--ui-testing-queues-load-failure"]) { app in
            app.tabBars.buttons["相册"].tap()
            assertAccessibilityManifest([
                .init("albums-queue-error", .staticText, "无法载入整理队列，请重试。"),
                .init("albums-queue-retry", .button, "重试", enabled: true)
            ], in: app)
            app.buttons["albums-queue-retry"].tap()
            element(in: app, identifier: "albums-decide-later").tap()
            assertAccessibilityManifest([
                .init("decide-later-empty", .staticText, "没有稍后决定的照片")
            ], in: app)
            app.navigationBars.buttons.firstMatch.tap()
            element(in: app, identifier: "albums-protected").tap()
            assertAccessibilityManifest([
                .init("protected-empty", .staticText, "没有受保护的照片")
            ], in: app)
        }
    }

    // Production break: lazy weekly/statistics/settings content or controls that
    // begin disabled are omitted from the manifest after scrolling or recovery.
    @MainActor
    func testAccessibilityManifestCoversWeeklyStatisticsAndSettings() throws {
        auditP0Fixture(arguments: ["--ui-testing-weekly-loading"]) { app in
            assertAccessibilityManifest([
                .init("weekly-loading", .activityIndicator, "正在载入本周整理"),
                .init("weekly-refresh", .button, "刷新本周整理", value: "", enabled: false)
            ], in: app)
            assertVerifiedSwiftUIMirror(
                identifier: "weekly-refresh",
                buttonEnabled: false,
                otherEnabled: true,
                in: app
            )
        }
        auditP0Fixture(arguments: ["--ui-testing-weekly-load-failure"]) { app in
            assertAccessibilityManifest([
                .init("weekly-load-failure", .other, "无法载入本周整理", value: "无法载入本周整理，请重试。"),
                .init("weekly-load-retry", .button, "重试", value: "", enabled: true)
            ], in: app)
            assertVerifiedSwiftUIMirror(identifier: "weekly-refresh", in: app)
            assertAccessibilityManifest([
                .init("weekly-refresh", .button, "刷新本周整理", value: "", enabled: true)
            ], in: app)
            app.buttons["weekly-load-retry"].tap()
            assertAccessibilityManifest([
                .init("weekly-task-count", .other, "任务", value: "3 项"),
                .init("weekly-start-weekly:1:weekly-expired", .button, "开始检查过期截图", value: "1 项，约 1 分钟，超过 30 天且仍可在本机访问", enabled: true)
            ], in: app)
        }
        auditP0Fixture(arguments: ["--ui-testing-weekly-work"]) { app in
            assertAccessibilityManifest([
                .init("weekly-task-count", .other, "任务", value: "3 项"),
                .init("weekly-duration", .other, "预计时间", value: "约 3 分钟"),
                .init("weekly-progress", .progressIndicator, "完成进度", value: "0%"),
                .init("weekly-start-weekly:1:weekly-expired", .button, "开始检查过期截图", enabled: true)
            ], in: app)
            XCTAssertTrue(reveal(app.buttons["weekly-start-deferred:weekly-deferred"], in: app, upward: true))
            assertAccessibilityManifest([
                .init("weekly-start-deferred:weekly-deferred", .button, "开始重新考虑稍后决定", value: "1 项，约 1 分钟，已到再次查看的时间，可继续稍后决定", enabled: true)
            ], in: app)
        }
        auditP0Fixture(arguments: ["--ui-testing-weekly-empty"]) { app in
            assertAccessibilityManifest([
                .init(
                    "weekly-tidy-empty",
                    .other,
                    "本周已整理好",
                    value: "当前可访问范围内没有需要处理的新照片、过期截图、未完成任务或到期的稍后决定"
                ),
                .init("weekly-refresh-empty", .button, "刷新", enabled: true)
            ], in: app)
        }
    }

    // Production break: Statistics and Settings recovery controls lose exact
    // values, roles, or disabled-to-enabled state transitions.
    @MainActor
    func testAccessibilityManifestCoversStatisticsAndSettingsRecovery() throws {
        auditP0Fixture(arguments: ["--ui-testing-statistics"]) { app in
            navigateToStatistics(in: app)
            assertAccessibilityManifest([
                .init("statistics-processed-items", .other, "已处理项目", value: "5")
            ], in: app)
            XCTAssertTrue(reveal(app.buttons["statistics-full-rescan"], in: app, upward: true))
            assertAccessibilityManifest([
                .init("statistics-full-rescan", .button, "完整重新扫描", value: "扫描已完成", enabled: true)
            ], in: app)
            XCTAssertTrue(reveal(app.buttons["statistics-clear-history"], in: app, upward: true))
            assertAccessibilityManifest([
                .init("statistics-clear-history", .button, "清除本机整理历史", enabled: true)
            ], in: app)
            app.buttons["statistics-clear-history"].tap()
            assertAccessibilityManifest([
                .init("statistics-clear-confirm", .button, "清除本机整理历史", enabled: true)
            ], in: app)
            app.buttons["statistics-clear-confirm"].firstMatch.tap()
            assertAccessibilityManifest([
                .init(
                    "statistics-no-history",
                    .other,
                    "还没有本地整理记录",
                    value: "完成整理后，这里会显示本机的整理进度"
                )
            ], in: app)
        }
        auditP0Fixture(arguments: ["--ui-testing-statistics-loading"]) { app in
            navigateToStatistics(in: app)
            assertAccessibilityManifest([
                .init("statistics-loading", .activityIndicator, "正在读取本地整理记录")
            ], in: app)
        }
        auditP0Fixture(arguments: ["--ui-testing-statistics-rescan-cancelled"]) { app in
            navigateToStatistics(in: app)
            XCTAssertTrue(reveal(app.buttons["statistics-full-rescan"], in: app, upward: true))
            assertAccessibilityManifest([
                .init("statistics-full-rescan", .button, "完整重新扫描", value: "扫描已取消", enabled: true),
                .init("statistics-rescan-cancelled", .staticText, "重新扫描已取消，现有整理历史会保留。"),
                .init("statistics-rescan-resume", .button, "继续重新扫描", enabled: true)
            ], in: app)
        }
        auditP0Fixture(arguments: ["--ui-testing-statistics-rescan-failed"]) { app in
            navigateToStatistics(in: app)
            XCTAssertTrue(reveal(app.buttons["statistics-full-rescan"], in: app, upward: true))
            assertAccessibilityManifest([
                .init("statistics-full-rescan", .button, "完整重新扫描", value: "扫描失败", enabled: true),
                .init("statistics-rescan-failed", .staticText, "重新扫描未完成，现有整理历史会保留。"),
                .init("statistics-rescan-retry", .button, "重试完整重新扫描", enabled: true)
            ], in: app)
        }
        auditP0Fixture(arguments: ["--ui-testing-statistics-clear-failure"]) { app in
            navigateToStatistics(in: app)
            XCTAssertTrue(reveal(app.buttons["statistics-clear-history"], in: app, upward: true))
            app.buttons["statistics-clear-history"].tap()
            assertAccessibilityManifest([
                .init("statistics-clear-confirm", .button, "清除本机整理历史", enabled: true)
            ], in: app)
            app.buttons["statistics-clear-confirm"].firstMatch.tap()
            assertAccessibilityManifest([
                .init("statistics-clear-retry", .button, "重试清除本机整理历史", enabled: true),
                .init("statistics-clear-return", .button, "保留历史并返回统计", enabled: true)
            ], in: app)
        }
        auditP0Fixture(arguments: ["--ui-testing-settings-locked"]) { app in
            navigateToSettings(in: app)
            assertAccessibilityManifest([
                .init("settings.reminderEnabled", .switch, "每周整理提醒", value: "0", enabled: false),
                .init("settings.reminderWeekday", .button, "提醒日期, 星期六", value: "星期六", enabled: false),
                .init("settings.reminderLockedReason", .staticText, "完成一次有实际决定的整理后，才可开启每周提醒。")
            ], in: app)
        }
        auditP0Fixture(arguments: ["--ui-testing-settings-granted"]) { app in
            navigateToSettings(in: app)
            assertAccessibilityManifest([
                .init("settings.reminderEnabled", .switch, "每周整理提醒", value: "0", enabled: true),
                .init("settings.reminderWeekday", .button, "提醒日期, 星期六", value: "星期六", enabled: false),
                .init("settings.reminderAuthorization", .other, "通知权限", value: "尚未请求")
            ], in: app)
            tapSwitch(app.switches["settings.reminderEnabled"])
            assertAccessibilityManifest([
                .init("settings.reminderEnabled", .switch, "每周整理提醒", value: "1", enabled: true),
                .init("settings.reminderWeekday", .button, "提醒日期, 星期六", value: "星期六", enabled: true)
            ], in: app)
        }
        auditP0Fixture(arguments: ["--ui-testing-settings-denied"]) { app in
            navigateToSettings(in: app)
            tapSwitch(app.switches["settings.reminderEnabled"])
            assertAccessibilityManifest([
                .init("settings.reminderEnabled", .switch, "每周整理提醒", value: "0", enabled: true),
                .init("settings.reminderGuidance", .staticText, "通知未获允许。你仍可使用每周整理，并可在系统设置中开启通知。"),
                .init("settings.openNotificationSettings", .button, "打开系统通知设置", enabled: true)
            ], in: app)
        }
        auditP0Fixture(arguments: ["--ui-testing-settings-disabled-mismatch"]) { app in
            navigateToSettings(in: app)
            assertAccessibilityManifest([
                .init("settings.reminderEnabled", .switch, "每周整理提醒", value: "0", enabled: false),
                .init("settings.retryReminderSynchronization", .button, "重试同步提醒", enabled: true)
            ], in: app)
        }
    }

    // Production break: critical state is color-only/private, values omit their
    // meaning, or source order no longer follows the P0 decision/recovery flow.
    @MainActor
    func testAccessibilityAuditAnnouncesCriticalStateAndLogicalActionOrder() throws {
        var app = launchP0Fixture(arguments: ["--ui-testing-partial"])
        navigateToTaskDashboard(in: app)
        assertAccessibility(
            element(in: app, identifier: "scan-status"),
            label: "扫描状态",
            value: "全部照片，正在检查本地照片"
        )
        assertAccessibility(
            element(in: app, identifier: "scan-progress"),
            label: "扫描进度",
            value: "38%，已处理 3 项，共 8 项"
        )
        app.terminate()

        app = launchP0Fixture(arguments: ["--ui-testing-comparison"])
        assertAccessibility(
            element(in: app, identifier: "comparison-media-comparison-recommended"),
            label: "第 1 张，当前保留，推荐保留"
        )
        assertAccessibility(
            app.buttons["comparison-inspect-comparison-recommended"],
            label: "查看第 1 张照片"
        )
        assertAccessibility(
            app.buttons["comparison-select-keep-comparison-recommended"],
            label: "将第 1 张选为保留",
            value: "已选中"
        )
        assertAccessibility(
            element(in: app, identifier: "comparison-media-comparison-protected"),
            label: "第 3 张，当前保留，已收藏，已保护"
        )
        assertAccessibilityOrder(
            [
                "comparison-media-comparison-recommended",
                "comparison-inspect-comparison-recommended",
                "comparison-select-keep-comparison-recommended"
            ],
            in: app
        )
        assertAccessibilityOrder(
            [
                "comparison-media-comparison-recommended",
                "comparison-media-comparison-chosen",
                "comparison-media-comparison-protected"
            ],
            in: app
        )
        app.terminate()

        app = launchP0Fixture(arguments: ["--ui-testing-decision"])
        for (identifier, label) in [
            ("decision-keep", "保留"),
            ("decision-delete", "删除"),
            ("decision-archive", "归档"),
            ("decision-protect", "保护"),
            ("decision-later", "稍后决定")
        ] {
            assertAccessibility(app.buttons[identifier], label: label)
        }
        assertAccessibilityOrder(
            ["decision-keep", "decision-delete", "decision-archive", "decision-protect", "decision-later"],
            in: app
        )
        app.terminate()

        app = launchP0Fixture(arguments: ["--ui-testing-delete-review"])
        assertAccessibility(
            element(in: app, identifier: "delete-review-candidate-count"),
            label: "待删除",
            value: "2 项"
        )
        assertAccessibility(
            element(in: app, identifier: "delete-review-candidate-delete-review-removed"),
            label: "删除候选，来自整理截图，预计大小 1 KB，已收藏",
            value: "已包含在本次删除"
        )
        assertAccessibility(
            app.buttons["delete-review-remove-delete-review-removed"],
            label: "从删除复核中移除此候选"
        )
        assertAccessibility(
            app.buttons["delete-review-confirm"],
            label: "确认删除 2 项"
        )
        let candidate = element(in: app, identifier: "delete-review-candidate-delete-review-removed")
        let nestedRemove = candidate.descendants(matching: .button)
            .matching(identifier: "delete-review-remove-delete-review-removed")
            .firstMatch
        XCTAssertTrue(
            nestedRemove.waitForExistence(timeout: 3),
            "Delete-review remove action is not an accessibility descendant of its candidate owner"
        )
        assertAccessibilityOrder(
            [
                "delete-review-candidate-count",
                "delete-review-candidate-delete-review-removed"
            ],
            in: app
        )
        app.terminate()

        app = launchP0Fixture(arguments: ["--ui-testing-cleanup-results"])
        assertAccessibility(
            element(in: app, identifier: "cleanup-results-deleted-count"),
            label: "已移到最近删除",
            value: "1 项"
        )
        assertAccessibility(
            element(in: app, identifier: "cleanup-results-unresolved-count"),
            label: "未完成，可重试",
            value: "1 项"
        )
        assertAccessibility(
            element(in: app, identifier: "cleanup-results-stale-count"),
            label: "照片已不可用",
            value: "1 项"
        )
        app.terminate()

        app = launchP0Fixture(arguments: ["--ui-testing-weekly-work"])
        assertAccessibility(
            element(in: app, identifier: "weekly-task-count"),
            label: "任务",
            value: "3 项"
        )
        assertAccessibility(
            element(in: app, identifier: "weekly-duration"),
            label: "预计时间",
            value: "约 3 分钟"
        )
        assertAccessibility(
            element(in: app, identifier: "weekly-progress"),
            label: "完成进度",
            value: "0%"
        )
        assertAccessibilityOrder(
            ["weekly-task-count", "weekly-duration", "weekly-progress", "weekly-start-weekly:1:weekly-expired"],
            in: app
        )
        app.terminate()

        app = launchP0Fixture(arguments: ["--ui-testing-statistics"])
        navigateToStatistics(in: app)
        assertAccessibility(
            element(in: app, identifier: "statistics-processed-items"),
            label: "已处理项目",
            value: "5"
        )
        assertAccessibility(
            element(in: app, identifier: "statistics-estimated-space"),
            label: "预计可回收空间",
            value: "4 KB"
        )
        assertAccessibilityOrder(
            ["statistics-processed-items", "statistics-archives", "statistics-protections"],
            in: app
        )
        XCTAssertTrue(reveal(app.buttons["statistics-full-rescan"], in: app, upward: true))
        XCTAssertEqual(app.buttons["statistics-full-rescan"].label, "完整重新扫描")
        XCTAssertTrue(reveal(app.buttons["statistics-clear-history"], in: app, upward: true))
        XCTAssertEqual(app.buttons["statistics-clear-history"].label, "清除本机整理历史")
        app.terminate()

        app = launchP0Fixture(arguments: ["--ui-testing-settings-granted"])
        navigateToSettings(in: app)
        assertAccessibility(
            element(in: app, identifier: "settings.reminderAuthorization"),
            label: "通知权限",
            value: "尚未请求"
        )
        assertAccessibility(
            element(in: app, identifier: "settings.screenshotThreshold"),
            label: "提醒处理",
            value: "30 天"
        )
        assertAccessibility(
            element(in: app, identifier: "settings.photoAuthorization"),
            label: "当前范围",
            value: "全部照片"
        )
        assertAccessibilityOrder(
            ["settings.reminderEnabled", "settings.reminderWeekday", "settings.screenshotThreshold", "settings.photoAuthorization"],
            in: app
        )
        app.terminate()
    }

    // Harness break: accepting any frame intersection treats a mostly hidden
    // action below fixed chrome as reachable.
    func testReachabilityRequiresFortyFourVisiblePointsInsideUsableViewport() throws {
        let viewport = CGRect(x: 0, y: 100, width: 393, height: 700)
        let fullyVisible = CGRect(x: 24, y: 756, width: 200, height: 44)
        let mostlyOffscreen = CGRect(x: 24, y: 775, width: 200, height: 44)

        XCTAssertTrue(hasMinimumVisibleTouchTarget(fullyVisible, in: viewport))
        XCTAssertFalse(hasMinimumVisibleTouchTarget(mostlyOffscreen, in: viewport))
    }

    // Production break: a full viewport minHeight applied before outer padding
    // creates scroll overflow even when normal-size onboarding content fits.
    @MainActor
    func testPermissionEducationFitsNormalViewportWithoutInitialOverflow() throws {
        let app = launchP0Fixture(arguments: ["--ui-testing-not-determined"])
        let permissionRequest = app.buttons["permission-request"]
        XCTAssertTrue(permissionRequest.waitForExistence(timeout: 3))
        XCTAssertTrue(
            hasMinimumVisibleTouchTarget(permissionRequest.frame, in: usableViewport(in: app)),
            "The permission action must expose 44 unobscured points without scrolling at normal size"
        )
        let initialFrame = permissionRequest.frame
        app.swipeUp()
        XCTAssertEqual(
            permissionRequest.frame.minY,
            initialFrame.minY,
            accuracy: 1,
            "Normal-size onboarding must not have a synthetic padding-only scroll range"
        )
        app.terminate()
    }

    // Production break: accessibility-size text pushes onboarding or decision
    // commands off screen, leaves the three-column decision grid in place, or
    // lets comparison actions overlap their media metadata.
    @MainActor
    func testAccessibilityDynamicTypeReflowsPermissionTasksComparisonAndDecision() throws {
        var app = launchAccessibilityFixture(arguments: ["--ui-testing-not-determined"])
        let permissionRequest = app.buttons["permission-request"]
        assertReachableControl(permissionRequest, label: "允许访问照片", in: app)
        recordVisualEvidence("dynamic-type-permission-onboarding", in: app)
        app.terminate()

        app = launchAccessibilityFixture(arguments: ["--ui-testing-diagnosis"])
        navigateToTaskDashboard(in: app)
        assertMaterializedText(
            element(in: app, identifier: "diagnosis-task-high-risk"),
            label: "检查相似照片",
            in: app
        )
        revealTop(in: app)
        let diagnosisReport = app.buttons["diagnosis-report"]
        assertReachableControl(diagnosisReport, label: "查看诊断报告", in: app)
        recordVisualEvidence("dynamic-type-task-diagnosis", in: app)
        diagnosisReport.tap()
        let recentlyDeletedGuidance = element(in: app, identifier: "diagnosis-recently-deleted-guidance")
        assertMaterializedText(
            recentlyDeletedGuidance,
            label: "删除项目会先移到“最近删除”。从“最近删除”中移除后，iOS 才会永久回收空间。",
            in: app
        )
        recordVisualEvidence("dynamic-type-diagnosis-report", in: app)
        app.terminate()

        app = launchAccessibilityFixture(arguments: ["--ui-testing-comparison"])
        let inspect = app.buttons["comparison-inspect-comparison-recommended"]
        let select = app.buttons["comparison-select-keep-comparison-recommended"]
        let firstCandidate = element(in: app, identifier: "comparison-media-comparison-recommended")
        let mediaGrid = element(in: app, identifier: "comparison-media-grid")
        assertReachableControl(inspect, label: "查看第 1 张照片", in: app)
        assertReachableControl(select, label: "将第 1 张选为保留", in: app)
        assertNonOverlapping(inspect, select, message: "Comparison inspect and keep-selection actions overlap")
        XCTAssertTrue(firstCandidate.waitForExistence(timeout: 3))
        XCTAssertTrue(mediaGrid.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(
            firstCandidate.frame.width,
            mediaGrid.frame.width * 0.8,
            "AX XXXL comparison candidates must use the readable width of the grid"
        )
        XCTAssertTrue(reveal(app.buttons["comparison-complete-group"], in: app, upward: true))
        assertReachableControl(app.buttons["comparison-complete-group"], label: "完成本组", in: app)
        recordVisualEvidence("dynamic-type-similar-comparison", in: app)
        app.terminate()

        app = launchAccessibilityFixture(arguments: ["--ui-testing-decision"])
        let decisionButtons = [
            app.buttons["decision-keep"],
            app.buttons["decision-delete"],
            app.buttons["decision-archive"],
            app.buttons["decision-protect"],
            app.buttons["decision-later"]
        ]
        let decisionLabels = ["保留", "删除", "归档", "保护", "稍后决定"]
        for (button, label) in zip(decisionButtons, decisionLabels) {
            assertReachableControl(button, label: label, in: app)
        }
        for (preceding, following) in zip(decisionButtons, decisionButtons.dropFirst()) {
            XCTAssertGreaterThanOrEqual(
                following.frame.minY,
                preceding.frame.maxY,
                "Accessibility-size decision actions must form a vertical, scrollable sequence"
            )
            assertNonOverlapping(preceding, following, message: "Decision actions overlap")
        }
        recordVisualEvidence("dynamic-type-single-decision", in: app)
        app.terminate()
    }

    // Production break: destructive/recovery commands or queue actions become
    // off-screen-only or collide with long result and media descriptions.
    @MainActor
    func testAccessibilityDynamicTypeKeepsDeleteResultsAndQueuesReachable() throws {
        var app = launchAccessibilityFixture(arguments: ["--ui-testing-delete-review"])
        assertMaterializedText(
            element(in: app, identifier: "delete-review-protected-exclusion"),
            label: "已排除 1 项手动保护照片",
            in: app
        )
        assertReachableControl(
            app.buttons["delete-review-remove-delete-review-removed"],
            label: "从删除复核中移除此候选",
            in: app
        )
        assertReachableControl(app.buttons["delete-review-confirm"], label: "确认删除 2 项", in: app)
        recordVisualEvidence("dynamic-type-delete-review", in: app)
        app.terminate()

        app = launchAccessibilityFixture(arguments: ["--ui-testing-cleanup-results"])
        assertMaterializedText(
            element(in: app, identifier: "cleanup-results-recently-deleted-guidance"),
            label: "照片会先保留在“最近删除”中，空间释放为预计值，清空“最近删除”后才会永久释放。",
            in: app
        )
        assertReachableControl(app.buttons["cleanup-results-retry"], label: "重试未完成的删除", in: app)
        recordVisualEvidence("dynamic-type-cleanup-result", in: app)
        app.terminate()

        app = launchAccessibilityFixture(arguments: ["--ui-testing-queues-reset"])
        app.tabBars.buttons["相册"].tap()
        assertReachableControl(element(in: app, identifier: "albums-decide-later"), label: "稍后决定", in: app)
        element(in: app, identifier: "albums-decide-later").tap()
        assertMaterializedText(
            element(in: app, identifier: "decision-queue-item-queue-later"),
            label: "队列照片，预计大小 1 KB，已编辑",
            in: app
        )
        assertReachableControl(
            app.buttons["decision-defer-again-queue-later"],
            label: "再次稍后决定",
            in: app
        )
        recordVisualEvidence("dynamic-type-queue-decide-later", in: app)
        app.terminate()

        app = launchAccessibilityFixture(arguments: ["--ui-testing-queues-reset"])
        app.tabBars.buttons["相册"].tap()
        assertReachableControl(element(in: app, identifier: "albums-protected"), label: "已保护", in: app)
        element(in: app, identifier: "albums-protected").tap()
        assertMaterializedText(
            element(in: app, identifier: "decision-queue-item-queue-protected"),
            label: "队列照片，预计大小 2 KB，已收藏，已保护",
            in: app
        )
        assertReachableControl(
            app.buttons["decision-unprotect-queue-protected"],
            label: "取消保护",
            in: app
        )
        recordVisualEvidence("dynamic-type-queue-protected", in: app)
        app.terminate()
    }

    // Production break: shared task, metric, and settings rows truncate their
    // meaning or hide the command needed to continue at an accessibility size.
    @MainActor
    func testAccessibilityDynamicTypeKeepsWeeklyStatisticsAndSettingsReachable() throws {
        var app = launchAccessibilityFixture(arguments: ["--ui-testing-weekly-work"])
        assertMaterializedText(element(in: app, identifier: "weekly-task-count"), label: "任务", in: app)
        assertReachableControl(
            app.buttons["weekly-start-weekly:1:weekly-expired"],
            label: "开始检查过期截图",
            in: app
        )
        assertReachableControl(
            app.buttons["weekly-start-deferred:weekly-deferred"],
            label: "开始重新考虑稍后决定",
            in: app
        )
        assertFullyVisibleControl(
            app.buttons["weekly-start-deferred:weekly-deferred"],
            label: "开始重新考虑稍后决定",
            in: app
        )
        recordVisualEvidence("dynamic-type-weekly-inbox", in: app)
        app.terminate()

        app = launchAccessibilityFixture(arguments: ["--ui-testing-statistics"])
        navigateToStatistics(in: app)
        assertMaterializedText(
            element(in: app, identifier: "statistics-estimated-space"),
            label: "预计可回收空间",
            in: app
        )
        assertReachableControl(app.buttons["statistics-full-rescan"], label: "完整重新扫描", in: app)
        assertReachableControl(app.buttons["statistics-clear-history"], label: "清除本机整理历史", in: app)
        recordVisualEvidence("dynamic-type-statistics", in: app)
        app.terminate()

        app = launchAccessibilityFixture(arguments: ["--ui-testing-settings-granted"])
        navigateToSettings(in: app)
        assertReachableControl(
            element(in: app, identifier: "settings.reminderEnabled"),
            label: "每周整理提醒",
            in: app
        )
        assertMaterializedText(
            element(in: app, identifier: "settings.privacyGenericReminder"),
            label: "提醒仅包含通用整理文字，不含照片内容",
            in: app
        )
        recordVisualEvidence("dynamic-type-settings", in: app)
        app.terminate()
    }

    // Production break: available queue and weekly recovery states can retain
    // correct semantics while their critical copy or recovery action is clipped.
    @MainActor
    func testAccessibilityDynamicTypeCoversQueueAndWeeklyRecoveryStates() throws {
        var app = launchAccessibilityFixture(arguments: ["--ui-testing-queues-loading"])
        app.tabBars.buttons["相册"].tap()
        assertMaterializedText(
            element(in: app, identifier: "albums-queue-loading"),
            label: "正在载入整理队列",
            in: app
        )
        recordVisualEvidence("dynamic-type-queue-loading", in: app)
        app.terminate()

        app = launchAccessibilityFixture(arguments: ["--ui-testing-queues-load-failure"])
        app.tabBars.buttons["相册"].tap()
        assertMaterializedText(
            app.staticTexts["无法载入整理队列，请重试。"],
            label: "无法载入整理队列，请重试。",
            in: app
        )
        assertReachableControl(app.buttons["albums-queue-retry"], label: "重试", in: app)
        recordVisualEvidence("dynamic-type-queue-failure", in: app)
        app.buttons["albums-queue-retry"].tap()
        let decideLater = element(in: app, identifier: "albums-decide-later")
        XCTAssertTrue(decideLater.waitForExistence(timeout: 3))
        decideLater.tap()
        assertMaterializedText(
            app.staticTexts["没有稍后决定的照片"],
            label: "没有稍后决定的照片",
            in: app
        )
        recordVisualEvidence("dynamic-type-queue-empty", in: app)
        app.terminate()

        app = launchAccessibilityFixture(arguments: ["--ui-testing-weekly-loading"])
        assertMaterializedText(
            element(in: app, identifier: "weekly-loading"),
            label: "正在载入本周整理",
            in: app
        )
        let weeklyRefresh = app.buttons["weekly-refresh"]
        XCTAssertTrue(weeklyRefresh.waitForExistence(timeout: 3))
        XCTAssertEqual(weeklyRefresh.label, "刷新本周整理")
        XCTAssertFalse(weeklyRefresh.isEnabled)
        let visibleRefreshFrame = weeklyRefresh.frame.intersection(app.windows.firstMatch.frame)
        XCTAssertGreaterThan(visibleRefreshFrame.width, 0)
        XCTAssertGreaterThan(visibleRefreshFrame.height, 0)
        recordVisualEvidence("dynamic-type-weekly-loading", in: app)
        app.terminate()

        app = launchAccessibilityFixture(arguments: ["--ui-testing-weekly-load-failure"])
        assertMaterializedState(
            element(in: app, identifier: "weekly-load-failure"),
            label: "无法载入本周整理",
            value: "无法载入本周整理，请重试。",
            in: app
        )
        assertReachableControl(app.buttons["weekly-load-retry"], label: "重试", in: app)
        recordVisualEvidence("dynamic-type-weekly-failure", in: app)
        app.terminate()

        app = launchAccessibilityFixture(arguments: ["--ui-testing-weekly-empty"])
        assertMaterializedState(
            element(in: app, identifier: "weekly-tidy-empty"),
            label: "本周已整理好",
            value: "当前可访问范围内没有需要处理的新照片、过期截图、未完成任务或到期的稍后决定",
            in: app
        )
        assertReachableControl(app.buttons["weekly-refresh-empty"], label: "刷新", in: app)
        recordVisualEvidence("dynamic-type-weekly-empty", in: app)
        app.terminate()
    }

    // Production break: Statistics and Settings expose recovery but long AX
    // copy can hide the only read/rescan/clear/persistence/synchronization action.
    @MainActor
    func testAccessibilityDynamicTypeCoversStatisticsAndSettingsRecoveryStates() throws {
        var app = launchAccessibilityFixture(arguments: ["--ui-testing-statistics-read-failure"])
        navigateToStatistics(in: app)
        assertMaterializedState(
            element(in: app, identifier: "statistics-read-failure"),
            label: "无法读取统计",
            value: "无法读取本地整理记录，请重试。",
            in: app
        )
        assertReachableControl(app.buttons["statistics-retry"], label: "重试", in: app)
        recordVisualEvidence("dynamic-type-statistics-read-failure", in: app)
        app.terminate()

        app = launchAccessibilityFixture(arguments: ["--ui-testing-statistics-rescan-failed"])
        navigateToStatistics(in: app)
        assertMaterializedText(
            element(in: app, identifier: "statistics-rescan-failed"),
            label: "重新扫描未完成，现有整理历史会保留。",
            in: app
        )
        assertReachableControl(app.buttons["statistics-rescan-retry"], label: "重试完整重新扫描", in: app)
        recordVisualEvidence("dynamic-type-statistics-rescan-failure", in: app)
        app.terminate()

        app = launchAccessibilityFixture(arguments: ["--ui-testing-statistics-clear-failure"])
        navigateToStatistics(in: app)
        assertReachableControl(app.buttons["statistics-clear-history"], label: "清除本机整理历史", in: app)
        app.buttons["statistics-clear-history"].tap()
        XCTAssertTrue(app.buttons["statistics-clear-confirm"].waitForExistence(timeout: 3))
        app.buttons["statistics-clear-confirm"].firstMatch.tap()
        assertMaterializedText(
            element(in: app, identifier: "statistics-clear-failure"),
            label: "无法读取本地整理记录，请重试。",
            in: app
        )
        assertReachableControl(app.buttons["statistics-clear-retry"], label: "重试清除本机整理历史", in: app)
        assertReachableControl(app.buttons["statistics-clear-return"], label: "保留历史并返回统计", in: app)
        recordVisualEvidence("dynamic-type-statistics-clear-failure", in: app)
        app.terminate()

        app = launchAccessibilityFixture(arguments: ["--ui-testing-settings-screenshot-failure"])
        navigateToSettings(in: app)
        XCTAssertTrue(scrollIntoMaterializedViewport(
            element(in: app, identifier: "settings.screenshotThreshold"),
            in: app,
            requireHittable: false
        ))
        XCTAssertTrue(app.buttons["7 天"].waitForExistence(timeout: 3))
        app.buttons["7 天"].tap()
        assertFullyVisibleText(
            element(in: app, identifier: "settings.screenshotPersistenceError"),
            label: "无法保存截图提醒天数。请重试；当前设置未更改。",
            in: app
        )
        recordVisualEvidence("dynamic-type-settings-persistence-failure", in: app)
        app.terminate()

        app = launchAccessibilityFixture(arguments: ["--ui-testing-settings-disabled-mismatch"])
        navigateToSettings(in: app)
        assertReachableControl(
            app.buttons["settings.retryReminderSynchronization"],
            label: "重试同步提醒",
            in: app
        )
        recordVisualEvidence("dynamic-type-settings-synchronization-recovery", in: app)
        app.terminate()
    }

    // Production break: delete-review and Cleanup Results recovery states can
    // leave their full failure scope or only recovery command outside the viewport.
    @MainActor
    func testAccessibilityDynamicTypeCoversDeleteAndCleanupResultRecoveryStates() throws {
        var app = launchAccessibilityFixture(arguments: ["--ui-testing-delete-review-load-failure"])
        assertMaterializedState(
            element(in: app, identifier: "delete-review-load-failed"),
            label: "无法载入删除复核",
            value: "无法载入删除复核，请重试。",
            in: app
        )
        assertReachableControl(app.buttons["delete-review-retry"], label: "重新载入", in: app)
        recordVisualEvidence("dynamic-type-delete-review-load-failure", in: app)
        app.terminate()

        app = launchAccessibilityFixture(arguments: ["--ui-testing-cleanup-results-loading"])
        assertMaterializedState(
            element(in: app, identifier: "cleanup-results-loading"),
            label: "正在载入整理结果",
            value: "正在读取本地整理记录",
            in: app
        )
        assertAccessibility(app.buttons["cleanup-results-return"], label: "返回任务")
        recordVisualEvidence("dynamic-type-cleanup-results-loading", in: app)
        app.terminate()

        app = launchAccessibilityFixture(arguments: ["--ui-testing-cleanup-results-missing"])
        assertMaterializedState(
            element(in: app, identifier: "cleanup-results-missing"),
            label: "无法显示整理结果",
            value: "找不到这次整理记录。请返回任务列表。",
            in: app
        )
        assertReachableControl(app.buttons["cleanup-results-reload"], label: "重新载入", in: app)
        assertAccessibility(app.buttons["cleanup-results-return"], label: "返回任务")
        recordVisualEvidence("dynamic-type-cleanup-results-missing", in: app)
        app.terminate()

        app = launchAccessibilityFixture(arguments: ["--ui-testing-cleanup-results-load-failure"])
        assertMaterializedState(
            element(in: app, identifier: "cleanup-results-failed"),
            label: "无法显示整理结果",
            value: "无法读取这次整理结果。请重试或返回任务列表。",
            in: app
        )
        assertReachableControl(app.buttons["cleanup-results-reload"], label: "重新载入", in: app)
        assertAccessibility(app.buttons["cleanup-results-return"], label: "返回任务")
        recordVisualEvidence("dynamic-type-cleanup-results-failed", in: app)
        app.terminate()
    }

    // Production break: Reduce Motion still applies nonessential state-change
    // animation, or removing it also loses selection and advancement feedback.
    @MainActor
    func testReduceMotionPreservesComparisonAndDecisionAdvancement() throws {
        var app = launchReduceMotionFixture(arguments: ["--ui-testing-comparison"])
        let chosen = app.buttons["comparison-select-keep-comparison-chosen"]
        assertReachableControl(chosen, label: "将第 2 张选为保留", in: app)
        chosen.tap()
        assertMotionProbe("motion-probe-comparison", in: app)
        XCTAssertTrue(waitForValue("已选中", element: chosen))
        XCTAssertTrue(chosen.isSelected)
        XCTAssertTrue(reveal(app.buttons["comparison-complete-group"], in: app, upward: true))
        app.buttons["comparison-complete-group"].tap()
        let groupPosition = app.staticTexts["comparison-group-position"]
        XCTAssertTrue(groupPosition.waitForExistence(timeout: 3))
        XCTAssertEqual(groupPosition.label, "第 2 组，共 2 组")
        recordVisualEvidence("reduce-motion-comparison-advancement", in: app)
        app.terminate()

        app = launchReduceMotionFixture(arguments: ["--ui-testing-decision"])
        let position = app.staticTexts["decision-position"]
        XCTAssertTrue(position.waitForExistence(timeout: 3))
        assertReachableControl(app.buttons["decision-keep"], label: "保留", in: app)
        app.buttons["decision-keep"].tap()
        assertMotionProbe("motion-probe-decision", in: app)
        XCTAssertTrue(waitForLabel("第 2 项，共 5 项", element: position))
        assertReachableControl(app.buttons["decision-undo"], label: "撤销", in: app)
        recordVisualEvidence("reduce-motion-decision-advancement", in: app)
        app.buttons["decision-undo"].tap()
        XCTAssertTrue(waitForLabel("第 1 项，共 5 项", element: position))
        app.terminate()

        app = launchReduceMotionFixture(arguments: ["--ui-testing-queues-reset"])
        app.tabBars.buttons["相册"].tap()
        element(in: app, identifier: "albums-protected").tap()
        let unprotect = app.buttons["decision-unprotect-queue-protected"]
        assertReachableControl(unprotect, label: "取消保护", in: app)
        unprotect.tap()
        assertMotionProbe("motion-probe-queue", in: app)
        XCTAssertTrue(element(in: app, identifier: "protected-empty").waitForExistence(timeout: 3))
        recordVisualEvidence("reduce-motion-queue-action", in: app)
        app.terminate()
    }

    #if !DEBUG
    @MainActor
    func testReleaseSettingsOmitsRealMutationControl() throws {
        let app = XCUIApplication()
        app.launch()

        if app.buttons["允许访问照片"].waitForExistence(timeout: 2) {
            let permissionMonitor = addUIInterruptionMonitor(withDescription: "照片访问权限") { alert in
                let labels = ["允许完全访问", "Allow Full Access", "允许访问所有照片", "Allow Access to All Photos"]
                guard let button = labels.lazy.map({ alert.buttons[$0] }).first(where: \.exists) else {
                    return false
                }
                button.tap()
                return true
            }
            app.buttons["允许访问照片"].tap()
            app.tap()
            removeUIInterruptionMonitor(permissionMonitor)
        }

        navigateToSettings(in: app)
        XCTAssertTrue(app.switches["settings.reminderEnabled"].waitForExistence(timeout: 3))
        XCTAssertTrue(element(in: app, identifier: "settings.screenshotThreshold").exists)
        XCTAssertTrue(reveal(element(in: app, identifier: "settings.privacyGenericReminder"), in: app, upward: true))
        XCTAssertFalse(app.switches["settings.debugRealMutation"].exists)
        XCTAssertFalse(element(in: app, identifier: "settings.mutationMode").exists)
    }
    #endif

    private func element(in app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func assertCleanupHome(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            element(in: app, identifier: "cleanup-home").waitForExistence(timeout: 5),
            file: file,
            line: line
        )
        XCTAssertTrue(app.tabBars.buttons["整理"].exists, file: file, line: line)
        XCTAssertTrue(app.tabBars.buttons["相册"].exists, file: file, line: line)
        XCTAssertTrue(app.tabBars.buttons["我的"].exists, file: file, line: line)
    }

    @MainActor
    private func navigateToTaskDashboard(in app: XCUIApplication) {
        navigateFromMy(identifier: "my-task-dashboard", in: app)
        XCTAssertTrue(element(in: app, identifier: "task-inbox-list").waitForExistence(timeout: 3))
    }

    @MainActor
    private func navigateToWeeklyInbox(in app: XCUIApplication) {
        navigateFromMy(identifier: "my-weekly-inbox", in: app)
        XCTAssertTrue(app.navigationBars["本周收件箱"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func navigateToStatistics(in app: XCUIApplication) {
        navigateFromMy(identifier: "my-statistics", in: app)
        XCTAssertTrue(app.navigationBars["统计"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func navigateToSettings(in app: XCUIApplication) {
        navigateFromMy(identifier: "my-settings", in: app)
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func navigateFromMy(identifier: String, in app: XCUIApplication) {
        returnToRootTabs(in: app)
        let myTab = app.tabBars.buttons["我的"]
        XCTAssertTrue(myTab.waitForExistence(timeout: 3))
        myTab.tap()
        XCTAssertTrue(element(in: app, identifier: "my-workspace-list").waitForExistence(timeout: 3))
        let destination = element(in: app, identifier: identifier)
        XCTAssertTrue(reveal(destination, in: app, upward: true), identifier)
        destination.tap()
    }

    @MainActor
    private func returnToRootTabs(in app: XCUIApplication) {
        for _ in 0..<10 {
            if app.tabBars.buttons["我的"].exists { return }
            let backButton = app.navigationBars.buttons.firstMatch
            guard backButton.waitForExistence(timeout: 1), backButton.isHittable else { break }
            backButton.tap()
        }
        XCTAssertTrue(app.tabBars.buttons["我的"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func launchP0Fixture(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 3))
        return app
    }

    @MainActor
    private func launchAccessibilityFixture(arguments: [String]) -> XCUIApplication {
        let app = launchP0Fixture(arguments: arguments + [
            "--ui-testing-accessibility-environment-probe",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        assertAccessibilityEnvironment(contentSize: "accessibility5", in: app)
        return app
    }

    @MainActor
    private func launchReduceMotionFixture(arguments: [String]) -> XCUIApplication {
        let app = launchP0Fixture(arguments: arguments + [
            "--ui-testing-accessibility-environment-probe",
            "--ui-testing-motion-probe"
        ])
        assertAccessibilityEnvironment(contentSize: "large", reduceMotion: true, in: app)
        return app
    }

    @MainActor
    private func recordVisualEvidence(_ name: String, in app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name + "-screenshot"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    @MainActor
    private func assertReachableControl(
        _ element: XCUIElement,
        label: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(scrollIntoMaterializedViewport(element, in: app, requireHittable: true), label, file: file, line: line)
        XCTAssertEqual(element.label, label, file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.width, 44, label, file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.height, 44, label, file: file, line: line)
        XCTAssertTrue(
            hasMinimumVisibleTouchTarget(element.frame, in: usableViewport(in: app)),
            label,
            file: file,
            line: line
        )
        XCTAssertTrue(element.isHittable, label, file: file, line: line)
    }

    @MainActor
    private func assertFullyVisibleControl(
        _ element: XCUIElement,
        label: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            scrollIntoMaterializedViewport(
                element,
                in: app,
                requireHittable: true,
                requireFullyVisible: true
            ),
            label,
            file: file,
            line: line
        )
        XCTAssertEqual(element.label, label, file: file, line: line)
        XCTAssertTrue(element.isHittable, label, file: file, line: line)
    }

    @MainActor
    private func assertMaterializedState(
        _ element: XCUIElement,
        label: String,
        value: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            scrollIntoMaterializedViewport(element, in: app, requireHittable: false),
            label,
            file: file,
            line: line
        )
        assertAccessibility(element, label: label, value: value, file: file, line: line)
    }

    @MainActor
    private func assertMaterializedText(
        _ element: XCUIElement,
        label: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(scrollIntoMaterializedViewport(element, in: app, requireHittable: false), label, file: file, line: line)
        XCTAssertEqual(element.label, label, file: file, line: line)
        XCTAssertGreaterThan(element.frame.width, 0, label, file: file, line: line)
        XCTAssertGreaterThan(element.frame.height, 0, label, file: file, line: line)
    }

    @MainActor
    private func assertFullyVisibleText(
        _ element: XCUIElement,
        label: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            scrollIntoMaterializedViewport(
                element,
                in: app,
                requireHittable: false,
                requireFullyVisible: true
            ),
            label,
            file: file,
            line: line
        )
        XCTAssertEqual(element.label, label, file: file, line: line)
        XCTAssertTrue(
            usableViewport(in: app).contains(element.frame),
            label,
            file: file,
            line: line
        )
    }

    @MainActor
    private func scrollIntoMaterializedViewport(
        _ element: XCUIElement,
        in app: XCUIApplication,
        requireHittable: Bool,
        requireFullyVisible: Bool = false
    ) -> Bool {
        let window = app.windows.firstMatch
        guard window.waitForExistence(timeout: 3) else { return false }
        for _ in 0..<10 {
            let viewport = usableViewport(in: app)
            if element.exists {
                let frame = element.frame
                let visibleFrame = frame.intersection(viewport)
                let isVisible: Bool
                if requireFullyVisible {
                    isVisible = viewport.contains(frame)
                } else if requireHittable {
                    isVisible = hasMinimumVisibleTouchTarget(frame, in: viewport)
                } else {
                    isVisible = !visibleFrame.isNull && visibleFrame.width > 0 && visibleFrame.height > 0
                }
                if frame.width > 0,
                   frame.height > 0,
                   isVisible,
                   (!requireHittable || element.isHittable) {
                    return true
                }
                if frame.minY < viewport.minY {
                    scrollViewport(in: app, upward: false)
                } else {
                    scrollViewport(in: app, upward: true)
                }
            } else {
                scrollViewport(in: app, upward: true)
            }
        }
        return false
    }

    @MainActor
    private func usableViewport(in app: XCUIApplication) -> CGRect {
        var viewport = app.windows.firstMatch.frame
        let navigationBar = app.navigationBars.firstMatch
        if navigationBar.exists, navigationBar.frame.intersects(viewport) {
            let top = max(viewport.minY, navigationBar.frame.maxY)
            viewport = CGRect(
                x: viewport.minX,
                y: top,
                width: viewport.width,
                height: max(0, viewport.maxY - top)
            )
        }
        let tabBar = app.tabBars.firstMatch
        if tabBar.exists, tabBar.frame.intersects(viewport) {
            viewport.size.height = max(0, tabBar.frame.minY - viewport.minY)
        }
        return viewport
    }

    private func scrollViewport(in app: XCUIApplication, upward: Bool) {
        let startY: CGFloat = upward ? 0.72 : 0.42
        let endY: CGFloat = upward ? 0.42 : 0.72
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startY))
            .press(
                forDuration: 0.01,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: endY))
            )
    }

    private func hasMinimumVisibleTouchTarget(
        _ frame: CGRect,
        in viewport: CGRect,
        minimum: CGFloat = 44
    ) -> Bool {
        let visibleFrame = frame.intersection(viewport)
        return !visibleFrame.isNull
            && visibleFrame.width >= minimum
            && visibleFrame.height >= minimum
    }

    @MainActor
    private func assertAccessibilityEnvironment(
        contentSize: String,
        reduceMotion: Bool? = nil,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let probe = element(in: app, identifier: "accessibility-environment-probe")
        XCTAssertTrue(probe.waitForExistence(timeout: 3), file: file, line: line)
        let value = accessibilityValueText(probe)
        XCTAssertTrue(value.contains("contentSize=\(contentSize)"), value, file: file, line: line)
        if let reduceMotion {
            XCTAssertTrue(value.contains("reduceMotion=\(reduceMotion)"), value, file: file, line: line)
        }
    }

    @MainActor
    private func assertMotionProbe(
        _ identifier: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let probe = element(in: app, identifier: identifier)
        XCTAssertTrue(probe.waitForExistence(timeout: 3), identifier, file: file, line: line)
        XCTAssertEqual(accessibilityValueText(probe), "reduced", identifier, file: file, line: line)
    }

    private func assertNonOverlapping(
        _ first: XCUIElement,
        _ second: XCUIElement,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(first.frame.intersects(second.frame), message, file: file, line: line)
    }

    @MainActor
    private func auditP0Fixture(
        arguments: [String],
        prepare: @MainActor (XCUIApplication) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let app = launchP0Fixture(arguments: arguments)
        prepare(app)
        assertNoUnusableActionLabels(in: app, file: file, line: line)
        assertUniqueAccessibilityIdentifiers(in: app, file: file, line: line)
        app.terminate()
    }

    @MainActor
    private func assertNoUnusableActionLabels(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actionableTypes: [XCUIElement.ElementType] = [
            .button, .switch, .link, .picker, .stepper, .slider,
            .textField, .secureTextField, .textView, .searchField, .segmentedControl,
            .other
        ]
        let privatePrefixes = [
            "archive-", "comparison-", "decision-", "delete-review-", "media-",
            "production-", "queue-", "result-", "statistics-", "weekly-"
        ]
        let unusableSymbolFallbacks: Set<String> = [
            "Add", "Chevron Left", "Chevron Right", "Close", "Folder Badge Plus",
            "Magnifyingglass", "Minus Circle", "Refresh", "Search", "Trash", "Xmark"
        ]

        let systemKeyboardFrames = app.keyboards.allElementsBoundByAccessibilityElement.map(\.frame)
        let appOwnedSwitches = app.switches.allElementsBoundByAccessibilityElement.filter {
            isAppOwnedAccessibilityIdentifier($0.identifier)
                && !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        for type in actionableTypes {
            let controls = app.descendants(matching: type).allElementsBoundByAccessibilityElement
            for control in controls
            where control.exists
                && control.isEnabled
                && (type != .other || isAppOwnedActionableOther(control, in: app))
                && !systemKeyboardFrames.contains(where: { $0.intersects(control.frame) })
                && !isVerifiedNativeSwitchImplementationNode(control, owners: appOwnedSwitches) {
                let label = control.label.trimmingCharacters(in: .whitespacesAndNewlines)
                XCTAssertFalse(
                    label.isEmpty,
                    "Enabled \(type) has no accessibility label: \(control.debugDescription)",
                    file: file,
                    line: line
                )
                XCTAssertFalse(
                    !control.identifier.isEmpty && label == control.identifier,
                    "Action exposes its automation identifier as its label: \(control.identifier)",
                    file: file,
                    line: line
                )
                XCTAssertFalse(
                    privatePrefixes.contains(where: label.contains),
                    "Action exposes a private fixture/media identifier: \(label)",
                    file: file,
                    line: line
                )
                XCTAssertFalse(
                    unusableSymbolFallbacks.contains(label),
                    "Action exposes an SF Symbol fallback instead of an exact Chinese label: \(label)",
                    file: file,
                    line: line
                )
            }
        }
    }

    private func isAppOwnedActionableOther(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.elementType == .other,
              element.isHittable,
              isAppOwnedAccessibilityIdentifier(element.identifier) else { return false }

        return app.descendants(matching: .any)
            .matching(identifier: element.identifier)
            .allElementsBoundByAccessibilityElement
            .contains { candidate in
                candidate.elementType == .button
                    && candidate.frame.intersects(element.frame)
            }
    }

    private func isVerifiedNativeSwitchImplementationNode(
        _ element: XCUIElement,
        owners: [XCUIElement]
    ) -> Bool {
        let frame = element.frame
        guard element.elementType == .switch,
              element.identifier.isEmpty,
              element.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              frame.width <= 80,
              frame.height <= 50 else { return false }

        let value = element.value as? String
        let matchingOwners = owners.filter { owner in
            owner.elementType == .switch
                && owner.frame != frame
                && owner.frame.contains(frame)
                && owner.isEnabled == element.isEnabled
                && owner.value as? String == value
        }
        return matchingOwners.count == 1
    }

    @MainActor
    private func assertUniqueAccessibilityIdentifiers(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let elements = app.descendants(matching: .any).allElementsBoundByAccessibilityElement
            .filter {
                $0.exists
                    && isAppOwnedAccessibilityIdentifier($0.identifier)
            }
        let groups = Dictionary(grouping: elements, by: \.identifier)
        let duplicates = groups
            .filter { $0.value.count > 1 }
            .keys
            .sorted()
        let duplicateDescriptions = duplicates.map { identifier in
            let descriptions = (groups[identifier] ?? []).map(accessibilityNodeDescription)
            return "\(identifier): [\(descriptions.joined(separator: "; "))]"
        }
        let unexpectedDuplicates = duplicates.filter { identifier in
            guard [
                "album-create-cancel",
                "album-create-command",
                "album-create-confirm",
                "cleanup-results-retry-confirm",
                "cleanup-results-return",
                "delete-review-confirm-final",
                "delete-review-exit",
                "weekly-refresh"
            ].contains(identifier) else {
                return true
            }
            let isWeeklyLoading = identifier == "weekly-refresh"
                && element(in: app, identifier: "weekly-loading").exists
            assertVerifiedSwiftUIMirror(
                identifier: identifier,
                elements: groups[identifier] ?? [],
                buttonEnabled: !isWeeklyLoading,
                otherEnabled: isWeeklyLoading ? true : nil,
                file: file,
                line: line
            )
            return false
        }
        XCTAssertTrue(
            unexpectedDuplicates.isEmpty,
            "Duplicate accessibility identifiers in materialized screen: \(unexpectedDuplicates). Nodes: \(duplicateDescriptions)",
            file: file,
            line: line
        )
    }

    private func accessibilityNodeDescription(_ element: XCUIElement) -> String {
        "type=\(element.elementType.rawValue), label=\(element.label), value=\(element.value as? String ?? "<nil>"), enabled=\(element.isEnabled), selected=\(element.isSelected), hittable=\(element.isHittable), frame=\(element.frame)"
    }

    private func assertVerifiedSwiftUIMirror(
        identifier: String,
        buttonEnabled: Bool = true,
        otherEnabled: Bool? = nil,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let query = app.descendants(matching: .any)
            .matching(identifier: identifier)
        XCTAssertTrue(query.firstMatch.waitForExistence(timeout: 3), identifier, file: file, line: line)
        let elements = query.allElementsBoundByAccessibilityElement
        assertVerifiedSwiftUIMirror(
            identifier: identifier,
            elements: elements,
            buttonEnabled: buttonEnabled,
            otherEnabled: otherEnabled,
            file: file,
            line: line
        )
    }

    private func assertVerifiedSwiftUIMirror(
        identifier: String,
        elements: [XCUIElement],
        buttonEnabled: Bool,
        otherEnabled: Bool?,
        file: StaticString,
        line: UInt
    ) {
        let expectedLabel: String
        switch identifier {
        case "album-create-cancel": expectedLabel = "取消"
        case "album-create-command": expectedLabel = "新建相册"
        case "album-create-confirm": expectedLabel = "创建"
        case "cleanup-results-retry-confirm": expectedLabel = "确认重试删除"
        case "cleanup-results-return": expectedLabel = "返回任务"
        case "delete-review-confirm-final": expectedLabel = "确认删除"
        case "delete-review-exit": expectedLabel = "退出复核"
        case "weekly-refresh": expectedLabel = "刷新本周整理"
        default:
            XCTFail("No strict SwiftUI mirror contract for \(identifier)", file: file, line: line)
            return
        }

        XCTAssertEqual(elements.count, 2, "\(identifier) node count", file: file, line: line)
        guard elements.count == 2 else { return }
        let otherNodes = elements.filter { $0.elementType == .other }
        let buttons = elements.filter { $0.elementType == .button }

        for element in elements {
            XCTAssertEqual(element.label, expectedLabel, "\(identifier) label", file: file, line: line)
            XCTAssertEqual(element.value as? String, "", "\(identifier) value", file: file, line: line)
            XCTAssertFalse(element.isSelected, "\(identifier) selected", file: file, line: line)
        }

        switch identifier {
        case "cleanup-results-retry-confirm", "delete-review-confirm-final":
            XCTAssertEqual(otherNodes.count, 0, "\(identifier) .other count", file: file, line: line)
            XCTAssertEqual(buttons.count, 2, "\(identifier) button count", file: file, line: line)
            guard buttons.count == 2 else { return }
            for button in buttons {
                XCTAssertEqual(button.isEnabled, buttonEnabled, "\(identifier) button enabled", file: file, line: line)
            }
            assertCoincidentFrames(buttons[0], buttons[1], identifier: identifier, file: file, line: line)
            XCTAssertEqual(buttons[0].isHittable, buttons[1].isHittable, "\(identifier) hittable", file: file, line: line)
        case "album-create-command", "weekly-refresh":
            XCTAssertEqual(otherNodes.count, 1, "\(identifier) .other count", file: file, line: line)
            XCTAssertEqual(buttons.count, 1, "\(identifier) button count", file: file, line: line)
            guard let other = otherNodes.first, let button = buttons.first else { return }
            XCTAssertEqual(other.isEnabled, otherEnabled ?? buttonEnabled, "\(identifier) .other enabled", file: file, line: line)
            XCTAssertEqual(button.isEnabled, buttonEnabled, "\(identifier) button enabled", file: file, line: line)
            XCTAssertTrue(other.frame.contains(button.frame), "\(identifier) containment", file: file, line: line)
            XCTAssertEqual(other.frame.minY, button.frame.minY, accuracy: 0.5, file: file, line: line)
            XCTAssertEqual(other.frame.height, button.frame.height, accuracy: 0.5, file: file, line: line)
            XCTAssertGreaterThan(other.frame.width, button.frame.width, file: file, line: line)
            XCTAssertEqual(other.isHittable, button.isHittable, "\(identifier) hittable", file: file, line: line)
        default:
            XCTAssertEqual(otherNodes.count, 1, "\(identifier) .other count", file: file, line: line)
            XCTAssertEqual(buttons.count, 1, "\(identifier) button count", file: file, line: line)
            guard let other = otherNodes.first, let button = buttons.first else { return }
            XCTAssertEqual(other.isEnabled, otherEnabled ?? buttonEnabled, "\(identifier) .other enabled", file: file, line: line)
            XCTAssertEqual(button.isEnabled, buttonEnabled, "\(identifier) button enabled", file: file, line: line)
            assertCoincidentFrames(other, button, identifier: identifier, file: file, line: line)
            XCTAssertEqual(other.isHittable, button.isHittable, "\(identifier) hittable", file: file, line: line)
        }
    }

    private func assertCoincidentFrames(
        _ first: XCUIElement,
        _ second: XCUIElement,
        identifier: String,
        file: StaticString,
        line: UInt
    ) {
        XCTAssertEqual(first.frame.minX, second.frame.minX, accuracy: 0.5, "\(identifier) minX", file: file, line: line)
        XCTAssertEqual(first.frame.minY, second.frame.minY, accuracy: 0.5, "\(identifier) minY", file: file, line: line)
        XCTAssertEqual(first.frame.width, second.frame.width, accuracy: 0.5, "\(identifier) width", file: file, line: line)
        XCTAssertEqual(first.frame.height, second.frame.height, accuracy: 0.5, "\(identifier) height", file: file, line: line)
    }

    private func isAppOwnedAccessibilityIdentifier(_ identifier: String) -> Bool {
        let prefixes = [
            "album-", "albums-", "authorization-", "cleanup-", "comparison-",
            "decision-", "delete-", "diagnosis-", "lifecycle.", "media-", "permission-",
            "queue-", "scan-", "settings.", "statistics-", "task-", "weekly-"
        ]
        return prefixes.contains(where: identifier.hasPrefix)
    }

    private func assertAccessibility(
        _ element: XCUIElement,
        type: XCUIElement.ElementType? = nil,
        label: String,
        value: String? = nil,
        waitForExistence: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if waitForExistence {
            XCTAssertTrue(element.waitForExistence(timeout: 3), file: file, line: line)
        }
        if let type {
            XCTAssertEqual(element.elementType, type, file: file, line: line)
        }
        XCTAssertEqual(element.label, label, file: file, line: line)
        if let value {
            XCTAssertEqual(element.value as? String, value, file: file, line: line)
        }
    }

    @MainActor
    private func assertSingleAccessibilityOwner(
        _ entry: AccessibilityManifestEntry,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let query = app.descendants(matching: .any)
            .matching(identifier: entry.identifier)
        XCTAssertTrue(query.firstMatch.waitForExistence(timeout: 3), entry.identifier, file: file, line: line)
        let elements = query.allElementsBoundByAccessibilityElement.filter(\.exists)
        XCTAssertEqual(
            elements.count,
            1,
            "Expected one accessibility owner for \(entry.identifier): \(elements.map(accessibilityNodeDescription))",
            file: file,
            line: line
        )
        guard let element = elements.first, elements.count == 1 else { return }
        assertAccessibility(
            element,
            type: entry.type,
            label: entry.label,
            value: entry.value,
            waitForExistence: false,
            file: file,
            line: line
        )
        if let enabled = entry.enabled {
            XCTAssertEqual(element.isEnabled, enabled, entry.identifier, file: file, line: line)
        }
        if let selected = entry.selected {
            XCTAssertEqual(element.isSelected, selected, entry.identifier, file: file, line: line)
        }
    }

    @MainActor
    private func assertExactHealthyLibraryEmptySemantics(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let titleLabel = "相册状态良好"
        let bodyLabel = "当前可访问范围内没有需要整理的照片或视频。"
        let titleQuery = app.staticTexts.matching(identifier: "scan-empty-state")
        XCTAssertTrue(titleQuery.firstMatch.waitForExistence(timeout: 3), titleLabel, file: file, line: line)

        let titleOwners = titleQuery.allElementsBoundByAccessibilityElement.filter(\.exists)
        let bodyOwners = app.staticTexts.allElementsBoundByAccessibilityElement.filter {
            $0.exists && $0.label == bodyLabel
        }
        XCTAssertEqual(
            titleOwners.count,
            1,
            "Unexpected title owners: \(titleOwners.map(accessibilityNodeDescription))",
            file: file,
            line: line
        )
        XCTAssertEqual(
            bodyOwners.count,
            1,
            "Unexpected body owners: \(bodyOwners.map(accessibilityNodeDescription))",
            file: file,
            line: line
        )
        guard titleOwners.count == 1,
              bodyOwners.count == 1,
              let title = titleOwners.first,
              let body = bodyOwners.first else { return }

        XCTAssertEqual(title.elementType, .staticText, titleLabel, file: file, line: line)
        XCTAssertEqual(title.identifier, "scan-empty-state", titleLabel, file: file, line: line)
        XCTAssertEqual(title.label, titleLabel, titleLabel, file: file, line: line)
        XCTAssertEqual(accessibilityValueText(title), "", "\(titleLabel) value", file: file, line: line)
        XCTAssertEqual(body.elementType, .staticText, bodyLabel, file: file, line: line)
        XCTAssertEqual(body.identifier, "", bodyLabel, file: file, line: line)
        XCTAssertEqual(body.label, bodyLabel, bodyLabel, file: file, line: line)
        XCTAssertEqual(accessibilityValueText(body), "", "\(bodyLabel) value", file: file, line: line)

        let emptyContentFrames = [title.frame, body.frame]
        let semanticOwners = app.descendants(matching: .any)
            .allElementsBoundByAccessibilityElement
            .filter { element in
                guard element.exists,
                      emptyContentFrames.contains(where: { $0.intersects(element.frame) }) else { return false }
                return !element.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !accessibilityValueText(element).isEmpty
            }
        let expectedOwners = [
            (identifier: "scan-empty-state", label: titleLabel),
            (identifier: "", label: bodyLabel)
        ]
        XCTAssertEqual(
            semanticOwners.count,
            expectedOwners.count,
            "Unexpected owners in empty-content region: \(semanticOwners.map(accessibilityNodeDescription))",
            file: file,
            line: line
        )
        for expected in expectedOwners {
            let matches = semanticOwners.filter {
                $0.elementType == .staticText
                    && $0.identifier == expected.identifier
                    && $0.label == expected.label
                    && accessibilityValueText($0).isEmpty
            }
            XCTAssertEqual(
                matches.count,
                1,
                "Missing or duplicated empty-state owner \(expected): \(semanticOwners.map(accessibilityNodeDescription))",
                file: file,
                line: line
            )
        }
    }

    private func accessibilityValueText(_ element: XCUIElement) -> String {
        (element.value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    private func assertAccessibilityManifest(
        _ entries: [AccessibilityManifestEntry],
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for entry in entries {
            let query = app.descendants(matching: .any)
                .matching(identifier: entry.identifier)
            XCTAssertTrue(query.firstMatch.waitForExistence(timeout: 3), entry.identifier, file: file, line: line)
            guard let matched = query.allElementsBoundByAccessibilityElement.first(where: {
                $0.elementType == entry.type
            }) else {
                XCTFail("Missing materialized accessibility element: \(entry.identifier)", file: file, line: line)
                continue
            }
            assertAccessibility(
                matched,
                type: entry.type,
                label: entry.label,
                value: entry.value,
                waitForExistence: false,
                file: file,
                line: line
            )
            if let enabled = entry.enabled {
                XCTAssertEqual(matched.isEnabled, enabled, entry.identifier, file: file, line: line)
            }
            if let selected = entry.selected {
                XCTAssertEqual(matched.isSelected, selected, entry.identifier, file: file, line: line)
            }
        }
    }

    private func assertAccessibilityOrder(
        _ identifiers: [String],
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let elements = app.descendants(matching: .any).allElementsBoundByAccessibilityElement
        let positions = identifiers.map { identifier in
            elements.firstIndex(where: { $0.identifier == identifier })
        }
        XCTAssertFalse(
            positions.contains(where: { $0 == nil }),
            "Missing accessibility-order element: \(zip(identifiers, positions).filter { $0.1 == nil }.map(\.0))",
            file: file,
            line: line
        )
        let resolved = positions.compactMap { $0 }
        XCTAssertEqual(resolved, resolved.sorted(), file: file, line: line)
    }

    @MainActor
    @discardableResult
    private func assertExactStatisticsInventory(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        let expected = "statistics-inventory-fingerprint:assets=statistics-archive,statistics-delete,statistics-keep,statistics-later,statistics-protect|albums=statistics-album:整理相册[]|mutationCalls=0"
        let marker = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", expected))
            .firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 3), file: file, line: line)
        let stableFingerprint = marker.identifier.components(separatedBy: "|inventoryReads=").first ?? marker.identifier
        XCTAssertEqual(stableFingerprint, expected, file: file, line: line)
        XCTAssertFalse(marker.label.contains("statistics-"), file: file, line: line)
        XCTAssertFalse((marker.value as? String ?? "").contains("statistics-"), file: file, line: line)
        return stableFingerprint
    }

    private func assertZeroLifecycleNotificationEffects(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertLifecycleNotificationEffects(
            authorizationRequests: 0,
            scheduledRequests: 0,
            in: app,
            file: file,
            line: line
        )
    }

    private func assertLifecycleNotificationEffects(
        authorizationRequests: Int,
        scheduledRequests: Int,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let probe = element(in: app, identifier: "lifecycle.notificationRecording")
        XCTAssertTrue(probe.waitForExistence(timeout: 3), file: file, line: line)
        XCTAssertTrue(
            waitForValue(
                "authorizationRequests=\(authorizationRequests);scheduledRequests=\(scheduledRequests)",
                element: probe
            ),
            file: file,
            line: line
        )
    }

    private func tapSwitch(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    }

    private func revealTop(in app: XCUIApplication) {
        for _ in 0..<3 {
            app.swipeDown()
        }
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, upward: Bool) -> Bool {
        for _ in 0..<4 {
            if element.exists { return true }
            if upward {
                app.swipeUp()
            } else {
                app.swipeDown()
            }
        }
        return element.exists
    }

    private func waitForLabel(
        _ expectedLabel: String,
        element: XCUIElement,
        timeout: TimeInterval = 3
    ) -> Bool {
        let predicate = NSPredicate(format: "label == %@", expectedLabel)
        return XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: predicate, object: element)],
            timeout: timeout
        ) == .completed
    }

    private func waitForValue(
        _ expectedValue: String,
        element: XCUIElement,
        timeout: TimeInterval = 3
    ) -> Bool {
        let predicate = NSPredicate(format: "value == %@", expectedValue)
        return XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: predicate, object: element)],
            timeout: timeout
        ) == .completed
    }

    private func waitForLabelDifferent(
        from initialValue: String,
        element: XCUIElement,
        timeout: TimeInterval = 3
    ) -> Bool {
        let predicate = NSPredicate(format: "label != %@", initialValue)
        return XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: predicate, object: element)],
            timeout: timeout
        ) == .completed
    }
}
