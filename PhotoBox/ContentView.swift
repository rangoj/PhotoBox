//
//  ContentView.swift
//  PhotoBox
//
//  Created by rango on 2026/8/27.
//

import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: AppModel

    init() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains(where: { $0.hasPrefix("--ui-testing-my") }) {
            _model = State(initialValue: MyHomeUITestFixture.makeModel(arguments: arguments))
        } else if arguments.contains(where: { $0.hasPrefix("--ui-testing-albums") }) {
            _model = State(initialValue: AlbumHomeUITestFixture.makeModel(arguments: arguments))
        } else if let homeMode = CleanupHomeUITestFixture.mode(for: arguments) {
            _model = State(initialValue: CleanupHomeUITestFixture.makeModel(mode: homeMode))
        } else if arguments.contains("--ui-testing-authorization-loading") {
            _model = State(initialValue: AppModel(library: UITestPhotoLibraryService(
                authorization: .authorized,
                authorizationStatusDelay: .seconds(5)
            )))
        } else if arguments.contains("--ui-testing-settings-locked") {
            _model = State(initialValue: SettingsUITestFixture.makeModel(mode: .locked))
        } else if arguments.contains("--ui-testing-settings-screenshot-failure") {
            _model = State(initialValue: SettingsUITestFixture.makeModel(mode: .screenshotFailure))
        } else if arguments.contains("--ui-testing-settings-unrelated-persistence-error") {
            _model = State(initialValue: SettingsUITestFixture.makeModel(mode: .unrelatedPersistenceError))
        } else if arguments.contains("--ui-testing-settings-disabled-mismatch") {
            _model = State(initialValue: SettingsUITestFixture.makeModel(mode: .disabledMismatch))
        } else if arguments.contains("--ui-testing-settings-granted") {
            _model = State(initialValue: SettingsUITestFixture.makeModel(mode: .granted))
        } else if arguments.contains("--ui-testing-settings-denied") {
            _model = State(initialValue: SettingsUITestFixture.makeModel(mode: .denied))
        } else if arguments.contains("--ui-testing-statistics-rescan-cancelled") {
            _model = State(initialValue: StatisticsUITestFixture.makeModel(scanFixture: .cancelled))
        } else if arguments.contains("--ui-testing-statistics-rescan-failed") {
            _model = State(initialValue: StatisticsUITestFixture.makeModel(scanFixture: .failed))
        } else if arguments.contains("--ui-testing-statistics-loading") {
            _model = State(initialValue: StatisticsUITestFixture.makeModel(scanFixture: .statisticsLoading))
        } else if arguments.contains("--ui-testing-statistics-read-failure") {
            _model = State(initialValue: StatisticsUITestFixture.makeModel(
                initialReadFailures: 1,
                scanFixture: .statisticsLoading
            ))
        } else if arguments.contains("--ui-testing-statistics") {
            _model = State(initialValue: StatisticsUITestFixture.makeModel())
        } else if arguments.contains("--ui-testing-statistics-clear-failure") {
            _model = State(initialValue: StatisticsUITestFixture.makeModel(clearFailures: 1))
        } else if arguments.contains("--ui-testing-weekly-transition-failure") {
            _model = State(initialValue: WeeklyInboxUITestFixture.makeTransitionFailureModel())
        } else if arguments.contains("--ui-testing-weekly-loading") {
            _model = State(initialValue: WeeklyInboxUITestFixture.makeLoadingModel())
        } else if arguments.contains("--ui-testing-weekly-load-failure") {
            _model = State(initialValue: WeeklyInboxUITestFixture.makeLoadFailureModel())
        } else if arguments.contains("--ui-testing-weekly-over-limit") {
            _model = State(initialValue: WeeklyInboxUITestFixture.makeOverLimitModel())
        } else if arguments.contains("--ui-testing-weekly-work") {
            _model = State(initialValue: WeeklyInboxUITestFixture.makeModel(hasWork: true))
        } else if arguments.contains("--ui-testing-weekly-empty") {
            _model = State(initialValue: WeeklyInboxUITestFixture.makeModel(hasWork: false))
        } else if arguments.contains("--ui-testing-queues-loading") {
            _model = State(initialValue: DecisionQueueUITestFixture.makeLoadingModel())
        } else if arguments.contains("--ui-testing-queues-load-failure") {
            _model = State(initialValue: DecisionQueueUITestFixture.makeLoadFailureModel())
        } else if arguments.contains("--ui-testing-queues-reset") {
            _model = State(initialValue: DecisionQueueUITestFixture.makeModel(reset: true))
        } else if arguments.contains("--ui-testing-queues") {
            _model = State(initialValue: DecisionQueueUITestFixture.makeModel(reset: false))
        } else if arguments.contains("--ui-testing-authorized") {
            _model = State(initialValue: AppModel(library: UITestPhotoLibraryService(authorization: .authorized)))
        } else if arguments.contains("--ui-testing-archive-create-failure") {
            _model = State(initialValue: ArchiveUITestFixture.makeModel(albumCreationFails: true))
        } else if arguments.contains("--ui-testing-archive") {
            _model = State(initialValue: ArchiveUITestFixture.makeModel())
        } else if arguments.contains("--ui-testing-delete-review-load-failure") {
            _model = State(initialValue: DeleteReviewUITestFixture.makeModel(loadFailsOnce: true))
        } else if arguments.contains("--ui-testing-delete-review") {
            _model = State(initialValue: DeleteReviewUITestFixture.makeModel())
        } else if arguments.contains("--ui-testing-cleanup-results-production") {
            _model = State(initialValue: CleanupResultsProductionUITestFixture.makeModel())
        } else if arguments.contains("--ui-testing-cleanup-results-summary") {
            _model = State(initialValue: CleanupResultsSummaryUITestFixture.makeModel(
                postSnapshotMutation: arguments.contains("--ui-testing-lifecycle-cleanup-schedule-side-effect")
                    ? .schedule(weekday: 7)
                    : nil
            ))
        } else if arguments.contains("--ui-testing-cleanup-results-loading") {
            _model = State(initialValue: CleanupResultsUITestFixture.makeLoadingModel())
        } else if arguments.contains("--ui-testing-cleanup-results-missing") {
            _model = State(initialValue: CleanupResultsUITestFixture.makeMissingModel())
        } else if arguments.contains("--ui-testing-cleanup-results-load-failure") {
            _model = State(initialValue: CleanupResultsUITestFixture.makeLoadFailureModel())
        } else if arguments.contains("--ui-testing-cleanup-results") {
            _model = State(initialValue: CleanupResultsUITestFixture.makeModel())
        } else if arguments.contains("--ui-testing-decision") {
            _model = State(initialValue: DecisionUITestFixture.makeModel())
        } else if arguments.contains("--ui-testing-comparison") {
            _model = State(initialValue: AppModel(
                library: UITestPhotoLibraryService(authorization: .authorized, fixture: .comparison),
                repository: try? SwiftDataTaskRepository(inMemory: true),
                initialScan: UITestPhotoLibraryService.snapshot(for: .comparison),
                initialActiveRoute: .comparison("comparison-fixture"),
                comparisonGroups: UITestPhotoLibraryService.comparisonGroups,
                comparisonRecommendations: UITestPhotoLibraryService.comparisonRecommendations
            ))
        } else if arguments.contains("--ui-testing-media") {
            _model = State(initialValue: AppModel(
                library: UITestPhotoLibraryService(authorization: .authorized, fixture: .media),
                initialScan: UITestPhotoLibraryService.snapshot(for: .media),
                initialActiveRoute: .comparison("media-fixture"),
                mediaPages: UITestPhotoLibraryService.mediaPages
            ))
        } else if arguments.contains("--ui-testing-diagnosis") {
            let repository = try! SwiftDataTaskRepository(inMemory: true)
            try! repository.save(tasks: DiagnosisUITestFixture.tasks)
            let notifications = RecordingLocalNotificationService(
                authorization: .notDetermined,
                postSnapshotMutation: arguments.contains("--ui-testing-lifecycle-diagnosis-schedule-side-effect")
                    ? .schedule(weekday: 7)
                    : nil
            )
            _model = State(initialValue: AppModel(
                library: UITestPhotoLibraryService(authorization: .authorized),
                repository: repository,
                notifications: notifications,
                initialScan: UITestPhotoLibraryService.snapshot(for: .completed),
                initialCleanupTasks: DiagnosisUITestFixture.tasks,
                currentPhotoStorageBytes: DiagnosisUITestFixture.currentPhotoStorageBytes,
                reminderRecordingSignal: { await notifications.recording() }
            ))
        } else if arguments.contains("--ui-testing-limited") {
            _model = State(initialValue: AppModel(library: UITestPhotoLibraryService(authorization: .limited)))
        } else if arguments.contains("--ui-testing-denied") {
            _model = State(initialValue: AppModel(library: UITestPhotoLibraryService(authorization: .denied)))
        } else if arguments.contains("--ui-testing-restricted") {
            _model = State(initialValue: AppModel(library: UITestPhotoLibraryService(authorization: .restricted)))
        } else if arguments.contains("--ui-testing-cancelled") {
            _model = State(initialValue: AppModel(
                library: UITestPhotoLibraryService(authorization: .authorized, fixture: .cancelled),
                initialScan: UITestPhotoLibraryService.snapshot(for: .cancelled)
            ))
        } else if arguments.contains("--ui-testing-accessibility-empty") {
            _model = State(initialValue: AppModel(
                library: UITestPhotoLibraryService(authorization: .authorized),
                repository: try? SwiftDataTaskRepository(inMemory: true),
                initialScan: UITestPhotoLibraryService.snapshot(for: .completed)
            ))
        } else if arguments.contains("--ui-testing-empty") {
            _model = State(initialValue: AppModel(
                library: UITestPhotoLibraryService(authorization: .authorized),
                repository: try! SwiftDataTaskRepository(inMemory: true),
                initialScan: UITestPhotoLibraryService.snapshot(for: .completed)
            ))
        } else if arguments.contains("--ui-testing-failed") {
            _model = State(initialValue: AppModel(
                library: UITestPhotoLibraryService(authorization: .authorized, fixture: .failed),
                initialScan: UITestPhotoLibraryService.snapshot(for: .failed)
            ))
        } else if arguments.contains("--ui-testing-partial") {
            _model = State(initialValue: AppModel(
                library: UITestPhotoLibraryService(authorization: .authorized, fixture: .partial),
                initialScan: UITestPhotoLibraryService.snapshot(for: .partial)
            ))
        } else if arguments.contains("--ui-testing-full-flow") {
            _model = State(initialValue: FullFlowUITestFixture.makeModel())
        } else if arguments.contains("--ui-testing-not-determined") {
            let notifications = RecordingLocalNotificationService(
                authorization: .notDetermined,
                requestedAuthorization: .authorized,
                postSnapshotMutation: arguments.contains("--ui-testing-lifecycle-onboarding-authorization-side-effect")
                    ? .requestAuthorization
                    : nil
            )
            _model = State(initialValue: AppModel(library: UITestPhotoLibraryService(
                authorization: .notDetermined,
                requestedAuthorization: .authorized
            ), notifications: notifications, reminderRecordingSignal: {
                await notifications.recording()
            }))
        } else {
            _model = State(initialValue: AppModel())
        }
        #else
        _model = State(initialValue: AppModel())
        #endif
    }

    var body: some View {
        Group {
            if !model.hasLoadedAuthorization {
                ProgressView("正在检查照片访问权限")
                    .accessibilityIdentifier("authorization-loading")
                    .accessibilityValue("正在载入授权状态")
            } else {
                switch model.authorization {
                case .notDetermined:
                    PermissionEducationView {
                        Task {
                            await model.requestPhotoAccess()
                            await model.refreshSettingsSignals()
                        }
                    }
                case .authorized, .limited:
                    MainTabView(model: model)
                case .denied, .restricted:
                    PermissionRecoveryView(isRestricted: model.authorization == .restricted)
                }
            }
        }
        #if DEBUG
        .frame(maxWidth: homeFixtureWidth)
        #endif
        .task {
            await model.refreshAuthorization()
            await model.refreshSettingsSignals()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await model.refreshForAppActivation()
                await model.refreshSettingsSignals()
            }
        }
        #if DEBUG
        .overlay(alignment: .topLeading) {
            if let recording = model.reminderRecording {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityIdentifier("lifecycle.notificationRecording")
                    .accessibilityValue(
                        "authorizationRequests=\(recording.authorizationRequestCount);scheduledRequests=\(recording.scheduledRequests.count)"
                    )
            }
        }
        .overlay(alignment: .topTrailing) {
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-accessibility-environment-probe") {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityIdentifier("accessibility-environment-probe")
                    .accessibilityLabel("辅助功能环境")
                    .accessibilityValue(Text(verbatim:
                        "contentSize=\(dynamicTypeSize.photoBoxProbeName);reduceMotion=\(reduceMotion)"
                    ))
            }
        }
        #endif
    }

    #if DEBUG
    private var homeFixtureWidth: CGFloat? {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing-home-width-375") { return 375 }
        if arguments.contains("--ui-testing-home-width-393") { return 393 }
        return nil
    }
    #endif
}

#if DEBUG
private extension DynamicTypeSize {
    var photoBoxProbeName: String {
        switch self {
        case .xSmall: "xSmall"
        case .small: "small"
        case .medium: "medium"
        case .large: "large"
        case .xLarge: "xLarge"
        case .xxLarge: "xxLarge"
        case .xxxLarge: "xxxLarge"
        case .accessibility1: "accessibility1"
        case .accessibility2: "accessibility2"
        case .accessibility3: "accessibility3"
        case .accessibility4: "accessibility4"
        case .accessibility5: "accessibility5"
        @unknown default: "unknown"
        }
    }
}
#endif

#if DEBUG
private enum SettingsUITestFixture {
    enum Mode: Equatable {
        case locked
        case granted
        case denied
        case screenshotFailure
        case unrelatedPersistenceError
        case disabledMismatch
    }

    @MainActor
    static func makeModel(mode: Mode) -> AppModel {
        let storage = try! SwiftDataTaskRepository(inMemory: true)
        var settings = WorkflowSettings.defaults
        settings.weeklyModeEnabled = mode != .locked
        settings.reminderEnabled = mode == .disabledMismatch
        try! storage.save(settings: settings)
        let repository: any TaskRepository
        if mode == .screenshotFailure {
            let failingRepository = WeeklyInboxUITestRepository(storage: storage)
            failingRepository.failAllSettingsWrites = true
            repository = failingRepository
        } else {
            repository = storage
        }
        let library = SettingsUITestPhotoLibrary()
        let notifications: RecordingLocalNotificationService
        switch mode {
        case .locked:
            notifications = RecordingLocalNotificationService(authorization: .notDetermined)
        case .granted, .screenshotFailure, .unrelatedPersistenceError:
            notifications = RecordingLocalNotificationService(
                authorization: .notDetermined,
                requestedAuthorization: .authorized
            )
        case .denied:
            notifications = RecordingLocalNotificationService(authorization: .denied)
        case .disabledMismatch:
            notifications = RecordingLocalNotificationService(
                authorization: .authorized,
                pendingWeekday: 7,
                removalFailureCount: 2
            )
        }
        let model = AppModel(
            library: library,
            repository: repository,
            notifications: notifications,
            mutator: SimulatedPhotoLibraryMutator(),
            reminderRecordingSignal: { await notifications.recording() },
            settingsScanCountSignal: { await library.inventoryReadCount() }
        )
        if mode == .unrelatedPersistenceError {
            model.persistenceErrorMessage = "无法打开本地整理记录"
        } else if mode == .disabledMismatch {
            Task {
                _ = await model.clearStatisticsHistory()
                await model.refreshSettingsSignals()
            }
        }
        return model
    }
}

private actor SettingsUITestPhotoLibrary: PhotoLibraryReading {
    private var readCount = 0

    func authorizationStatus() -> PhotoAuthorization { .authorized }
    func requestAuthorization() -> PhotoAuthorization { .authorized }

    func accessibleAssetDescriptors() -> [PhotoAssetDescriptor] {
        readCount += 1
        return []
    }

    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> {
        AsyncStream { $0.finish() }
    }

    func inventoryReadCount() -> Int { readCount }
}

private enum DiagnosisUITestFixture {
    static let currentPhotoStorageBytes: Int64 = 128_000_000_000

    static let tasks = [
        CleanupTask(
            id: "high-risk",
            type: .duplicates,
            title: "检查相似照片",
            reason: "相似度较低，需要逐组确认",
            assetIDs: ["high-1", "high-2", "high-3"],
            estimatedBytes: 8_000_000_000,
            estimatedMinutes: 8,
            risk: .high,
            confidence: 0.95,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        ),
        CleanupTask(
            id: "low-risk",
            type: .screenshots,
            title: "处理过期截图",
            reason: "超过 30 天且未标记为收藏",
            assetIDs: ["low-1", "low-2"],
            estimatedBytes: 32_000_000,
            estimatedMinutes: 2,
            risk: .low,
            confidence: 0.9,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
    ]
}

private enum FullFlowUITestFixture {
    static func makeModel() -> AppModel {
        let repository = try! SwiftDataTaskRepository(inMemory: true)
        let now = Date(timeIntervalSince1970: 1_000)
        let comparisonTask = CleanupTask(
            id: "full-flow-comparison",
            type: .similar,
            title: "检查相似照片",
            reason: "相似度较低，需要逐组确认",
            assetIDs: ["full-flow-comparison-keep", "full-flow-comparison-delete"],
            estimatedBytes: 1_000,
            estimatedMinutes: 1,
            risk: .medium,
            confidence: 0.9,
            createdAt: now,
            updatedAt: now
        )
        let decisionTask = CleanupTask(
            id: "full-flow-decisions",
            type: .screenshots,
            title: "处理照片决定",
            reason: "逐项确认后再整理",
            assetIDs: [
                "full-flow-keep",
                "full-flow-delete",
                "full-flow-archive",
                "full-flow-protect",
                "full-flow-later"
            ],
            estimatedBytes: 5_000,
            estimatedMinutes: 2,
            risk: .low,
            confidence: 1,
            createdAt: now,
            updatedAt: now
        )
        try! repository.save(tasks: [comparisonTask, decisionTask])
        var settings = WorkflowSettings.defaults
        settings.recentAlbumIDs = ["full-flow-album"]
        try! repository.save(settings: settings)

        let mutator = UITestRecordingDeleteMutator(
            assetIDs: Set(UITestPhotoLibraryService.fullFlowDescriptors.map(\.id)),
            albums: [PhotoAlbumDescriptor(id: "full-flow-album", title: "PhotoBox 归档", assetCount: 0)]
        )
        return AppModel(
            library: UITestPhotoLibraryService(
                authorization: .notDetermined,
                requestedAuthorization: .authorized,
                fixture: .fullFlow
            ),
            repository: repository,
            mutator: mutator,
            currentPhotoStorageBytes: 64_000_000,
            mutationSubmissionSignal: { await mutator.recordedDeleteCallCount() },
            mutationSubmissionReadSignal: { await mutator.recordedDeleteCallReadCount() }
        )
    }
}

private enum DecisionUITestFixture {
    static func makeModel() -> AppModel {
        let repository = try! SwiftDataTaskRepository(inMemory: true)
        let task = CleanupTask(
            id: "decision-fixture",
            type: .screenshots,
            title: "处理截图",
            reason: "测试单张决定",
            assetIDs: UITestPhotoLibraryService.decisionDescriptors.map(\.id),
            estimatedBytes: 5_000,
            estimatedMinutes: 1,
            risk: .low,
            confidence: 1,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        try! repository.save(task: task)
        return AppModel(
            library: UITestPhotoLibraryService(authorization: .authorized, fixture: .decision),
            repository: repository,
            mutator: SimulatedPhotoLibraryMutator(assetIDs: Set(task.assetIDs)),
            initialScan: UITestPhotoLibraryService.snapshot(for: .decision),
            initialActiveRoute: .task(task.id)
        )
    }
}

private enum ArchiveUITestFixture {
    static func makeModel(albumCreationFails: Bool = false) -> AppModel {
        let repository = try! SwiftDataTaskRepository(inMemory: true)
        let task = CleanupTask(
            id: "archive-fixture",
            type: .screenshots,
            title: "归档照片",
            reason: "测试归档恢复",
            assetIDs: UITestPhotoLibraryService.archiveDescriptors.map(\.id),
            estimatedBytes: 2_000,
            estimatedMinutes: 1,
            risk: .low,
            confidence: 1,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        try! repository.save(task: task)
        var settings = WorkflowSettings.defaults
        settings.recentAlbumIDs = ["archive-valid", "archive-gone-recent"]
        try! repository.save(settings: settings)
        let mutator = SimulatedPhotoLibraryMutator(
            assetIDs: Set(task.assetIDs),
            albums: [
                PhotoAlbumDescriptor(id: "archive-missing", title: "会消失的相册", assetCount: 0),
                PhotoAlbumDescriptor(id: "archive-valid", title: "旅行", assetCount: 0),
                PhotoAlbumDescriptor(id: "archive-second", title: "精选", assetCount: 0)
            ],
            albumIDsMissingOnArchive: ["archive-missing"],
            albumCreationFails: albumCreationFails
        )
        return AppModel(
            library: UITestPhotoLibraryService(authorization: .authorized, fixture: .archive),
            repository: repository,
            mutator: mutator,
            initialScan: UITestPhotoLibraryService.snapshot(for: .archive),
            initialActiveRoute: .task(task.id)
        )
    }
}

private enum DeleteReviewUITestFixture {
    static func makeModel(loadFailsOnce: Bool = false) -> AppModel {
        let repository = try! SwiftDataTaskRepository(inMemory: true)
        let task = CleanupTask(
            id: "delete-review-fixture",
            type: .screenshots,
            title: "整理截图",
            reason: "测试删除复核",
            assetIDs: [
                "delete-review-removed",
                "delete-review-remaining",
                "delete-review-protected",
                "delete-review-missing"
            ],
            estimatedBytes: 4_000,
            estimatedMinutes: 1,
            risk: .low,
            confidence: 1,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        try! repository.save(task: task)
        try! repository.save(decisions: [
            PhotoDecision(assetID: "delete-review-removed", kind: .deleteCandidate, estimatedBytes: 1_000, taskID: task.id),
            PhotoDecision(assetID: "delete-review-remaining", kind: .deleteCandidate, estimatedBytes: 2_000, taskID: task.id),
            PhotoDecision(assetID: "delete-review-protected", kind: .protect, estimatedBytes: 1_000, taskID: task.id),
            PhotoDecision(assetID: "delete-review-missing", kind: .deleteCandidate, estimatedBytes: 9_000, taskID: task.id)
        ])
        let mutator = UITestRecordingDeleteMutator(assetIDs: [
            "delete-review-removed",
            "delete-review-remaining"
        ])
        let model = AppModel(
            library: UITestPhotoLibraryService(
                authorization: .authorized,
                fixture: loadFailsOnce ? .deleteReviewLoadFailure : .deleteReview
            ),
            repository: repository,
            mutator: mutator,
            initialScan: UITestPhotoLibraryService.snapshot(for: loadFailsOnce ? .deleteReviewLoadFailure : .deleteReview),
            initialActiveRoute: .deleteReview,
            mutationSubmissionSignal: { await mutator.recordedDeleteCallCount() },
            mutationSubmissionReadSignal: { await mutator.recordedDeleteCallReadCount() }
        )
        model.restoreWorkflowState()
        model.taskNavigationPath = [.deleteReview]
        return model
    }
}

private enum CleanupResultsUITestFixture {
    static func makeModel() -> AppModel {
        let repository = try! SwiftDataTaskRepository(inMemory: true)
        let task = CleanupTask(
            id: "cleanup-results-fixture",
            type: .screenshots,
            title: "整理截图",
            reason: "测试整理结果",
            assetIDs: ["result-succeeded", "result-retry", "result-stale"],
            estimatedBytes: 3_000,
            estimatedMinutes: 1,
            risk: .low,
            confidence: 1,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        try! repository.save(task: task)
        try! repository.save(decisions: [
            PhotoDecision(assetID: "result-succeeded", kind: .deleteCandidate, estimatedBytes: 1_000, taskID: task.id, isSubmitted: true),
            PhotoDecision(assetID: "result-retry", kind: .deleteCandidate, estimatedBytes: 2_000, taskID: task.id),
            PhotoDecision(assetID: "result-stale", kind: .deleteCandidate, estimatedBytes: 3_000, taskID: task.id),
            PhotoDecision(assetID: "result-protected", kind: .protect, estimatedBytes: 0, taskID: task.id),
            PhotoDecision(assetID: "result-later", kind: .decideLater, estimatedBytes: 0, taskID: task.id),
            PhotoDecision(assetID: "result-keep", kind: .keep, estimatedBytes: 0, taskID: task.id),
            PhotoDecision(assetID: "result-archive", kind: .archive, estimatedBytes: 0, taskID: task.id, isSubmitted: true)
        ])
        try! repository.save(transaction: MutationTransaction(
            id: "cleanup-results-archive",
            operation: .archive,
            items: [MutationItem(assetID: "result-archive", state: .succeeded)],
            backendMode: .simulated
        ))
        try! repository.save(transaction: MutationTransaction(
            id: "cleanup-results-transaction",
            operation: .delete,
            items: [
                MutationItem(assetID: "result-succeeded", state: .succeeded),
                MutationItem(assetID: "result-retry", state: .failed),
                MutationItem(assetID: "result-stale", state: .stale)
            ],
            createdAt: Date(timeIntervalSince1970: 1_000),
            completedAt: Date(timeIntervalSince1970: 1_060),
            backendMode: .simulated
        ))
        let mutator = UITestRecordingDeleteMutator(assetIDs: ["result-retry"])
        let model = AppModel(
            library: UITestPhotoLibraryService(authorization: .authorized, fixture: .deleteReview),
            repository: repository,
            mutator: mutator,
            initialScan: UITestPhotoLibraryService.snapshot(for: .deleteReview),
            initialActiveRoute: .result(.transaction("cleanup-results-transaction")),
            mutationSubmittedAssetIDsSignal: { await mutator.recordedDeleteAssetIDs() }
        )
        model.taskNavigationPath = [.result(.transaction("cleanup-results-transaction"))]
        return model
    }

    static func makeMissingModel() -> AppModel {
        let source = CleanupResultSource.transaction("cleanup-results-missing")
        let model = AppModel(
            library: UITestPhotoLibraryService(authorization: .authorized),
            repository: try! SwiftDataTaskRepository(inMemory: true),
            initialScan: UITestPhotoLibraryService.snapshot(for: .cancelled),
            initialActiveRoute: .result(source)
        )
        model.authorization = .authorized
        model.hasLoadedAuthorization = true
        model.taskNavigationPath = [.result(source)]
        return model
    }

    static func makeLoadingModel() -> AppModel {
        let repository = try! SwiftDataTaskRepository(inMemory: true)
        let transactionID = "cleanup-results-loading-transaction"
        try! repository.save(transaction: MutationTransaction(
            id: transactionID,
            operation: .delete,
            items: [MutationItem(assetID: "cleanup-results-loading-asset", state: .submitted)],
            backendMode: .simulated
        ))
        let source = CleanupResultSource.transaction(transactionID)
        let mutator = CleanupResultsLoadingUITestMutator()
        let model = AppModel(
            library: UITestPhotoLibraryService(authorization: .authorized),
            repository: repository,
            mutator: mutator,
            initialScan: UITestPhotoLibraryService.snapshot(for: .cancelled),
            initialActiveRoute: .result(source)
        )
        model.authorization = .authorized
        model.hasLoadedAuthorization = true
        model.cleanupResultsSource = source
        model.cleanupResultsFlow = CleanupResultsModel(
            source: source,
            repository: repository,
            mutator: mutator
        )
        model.taskNavigationPath = [.result(source)]
        return model
    }

    static func makeLoadFailureModel() -> AppModel {
        let storage = try! SwiftDataTaskRepository(inMemory: true)
        let task = CleanupTask(
            id: "cleanup-results-load-failure-task",
            type: .screenshots,
            title: "整理截图",
            reason: "测试结果读取恢复",
            assetIDs: ["cleanup-results-load-failure-asset"],
            estimatedBytes: 1_000,
            estimatedMinutes: 1,
            risk: .low,
            confidence: 1
        )
        try! storage.save(task: task)
        try! storage.save(decision: PhotoDecision(
            assetID: "cleanup-results-load-failure-asset",
            kind: .deleteCandidate,
            estimatedBytes: 1_000,
            taskID: task.id,
            isSubmitted: true
        ))
        let transactionID = "cleanup-results-load-failure-transaction"
        try! storage.save(transaction: MutationTransaction(
            id: transactionID,
            operation: .delete,
            items: [MutationItem(assetID: "cleanup-results-load-failure-asset", state: .succeeded)],
            completedAt: .now,
            backendMode: .simulated
        ))
        let repository = WeeklyInboxUITestRepository(storage: storage)
        // The route prepares once, then the rendered result screen performs its
        // own initial load. Both must fail before the explicit user retry.
        repository.remainingTransactionReadFailures = 2
        let source = CleanupResultSource.transaction(transactionID)
        let model = AppModel(
            library: UITestPhotoLibraryService(authorization: .authorized),
            repository: repository,
            mutator: SimulatedPhotoLibraryMutator(assetIDs: ["cleanup-results-load-failure-asset"]),
            initialScan: UITestPhotoLibraryService.snapshot(for: .cancelled),
            initialActiveRoute: .result(source)
        )
        model.authorization = .authorized
        model.hasLoadedAuthorization = true
        model.taskNavigationPath = [.result(source)]
        return model
    }
}

private actor CleanupResultsLoadingUITestMutator: PhotoLibraryMutating {
    let backendMode = MutationBackendMode.simulated
    let reconciliationMode = MutationReconciliationMode.deterministicSimulation

    func availableAssetIDs(for requestedIDs: [String]) async -> Set<String> {
        try? await Task.sleep(for: .seconds(5))
        return []
    }

    func listAlbums() -> [PhotoAlbumDescriptor] { [] }
    func createAlbum(named title: String) -> PhotoAlbumDescriptor? { nil }
    func archivedAssetIDs(for requestedIDs: [String], inAlbumID albumID: String) -> Set<String> { [] }
    func addAssets(withIDs assetIDs: [String], toAlbumID albumID: String) -> PhotoMutationBatch {
        PhotoMutationBatch(operation: .archive, items: [], targetAlbumID: albumID)
    }
    func deleteAssets(withIDs assetIDs: [String]) -> PhotoMutationBatch {
        PhotoMutationBatch(operation: .delete, items: [], targetAlbumID: nil)
    }
}

private enum CleanupResultsSummaryUITestFixture {
    static func makeModel(
        postSnapshotMutation: RecordingLocalNotificationPostSnapshotMutation? = nil
    ) -> AppModel {
        let repository = try! SwiftDataTaskRepository(inMemory: true)
        let notifications = RecordingLocalNotificationService(
            authorization: .notDetermined,
            postSnapshotMutation: postSnapshotMutation
        )
        let summary = CleanupSummary(
            decisions: [
                PhotoDecision(assetID: "summary-archive", kind: .archive, isSubmitted: true),
                PhotoDecision(assetID: "summary-protect", kind: .protect),
                PhotoDecision(assetID: "summary-later", kind: .decideLater),
                PhotoDecision(assetID: "summary-keep", kind: .keep)
            ],
            elapsedSeconds: nil,
            id: CleanupSummary.identifier(forTaskID: "cleanup-results-summary-fixture")
        )
        try! repository.save(summary: summary)
        let source = CleanupResultSource.summary(summary.id)
        let model = AppModel(
            library: UITestPhotoLibraryService(authorization: .authorized),
            repository: repository,
            notifications: notifications,
            initialScan: UITestPhotoLibraryService.snapshot(for: .completed),
            initialActiveRoute: .result(source),
            reminderRecordingSignal: { await notifications.recording() }
        )
        model.taskNavigationPath = [.result(source)]
        return model
    }
}

private enum CleanupResultsProductionUITestFixture {
    static func makeModel() -> AppModel {
        let repository = try! SwiftDataTaskRepository(inMemory: true)
        let candidateIDs = [
            "production-removed",
            "production-succeeded",
            "production-retry",
            "production-stale"
        ]
        let task = CleanupTask(
            id: "cleanup-results-production-fixture",
            type: .screenshots,
            title: "整理截图",
            reason: "测试删除结果恢复",
            assetIDs: candidateIDs,
            estimatedBytes: 4_000,
            estimatedMinutes: 1,
            risk: .low,
            confidence: 1,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        try! repository.save(task: task)
        try! repository.save(checkpoint: ScanCheckpoint(
            id: "cleanup-results-production-baseline",
            stage: .completed,
            processedAssetIDs: candidateIDs,
            discoveredCount: candidateIDs.count,
            snapshot: UITestPhotoLibraryService.snapshot(for: .cleanupResultsProduction),
            updatedAt: Date(timeIntervalSince1970: 900)
        ))
        try! repository.save(decisions: candidateIDs.enumerated().map { index, assetID in
            PhotoDecision(
                assetID: assetID,
                kind: .deleteCandidate,
                estimatedBytes: Int64(index + 1) * 1_000,
                taskID: task.id,
                createdAt: Date(timeIntervalSince1970: TimeInterval(1_100 + index))
            )
        })
        let mutator = UITestRecordingDeleteMutator(
            assetIDs: ["production-removed", "production-succeeded", "production-retry"],
            configuredOutcomes: ["production-retry": .failed],
            subsequentOutcomes: ["production-retry": .succeeded]
        )
        let model = AppModel(
            library: UITestPhotoLibraryService(
                authorization: .authorized,
                fixture: .cleanupResultsProduction
            ),
            repository: repository,
            mutator: mutator,
            initialScan: UITestPhotoLibraryService.snapshot(for: .cleanupResultsProduction),
            initialActiveRoute: .deleteReview,
            mutationSubmissionSignal: { await mutator.recordedDeleteCallCount() },
            mutationSubmittedAssetIDsSignal: { await mutator.recordedLastDeleteAssetIDs() }
        )
        model.taskNavigationPath = [.deleteReview]
        return model
    }
}

private enum DecisionQueueUITestFixture {
    static func makeLoadingModel() -> AppModel {
        AppModel(
            library: UITestPhotoLibraryService(
                authorization: .authorized,
                fixture: .queuesLoading
            ),
            repository: try! SwiftDataTaskRepository(inMemory: true),
            initialScan: UITestPhotoLibraryService.snapshot(for: .queuesLoading)
        )
    }

    static func makeLoadFailureModel() -> AppModel {
        AppModel(
            library: UITestPhotoLibraryService(
                authorization: .authorized,
                fixture: .queuesLoadFailure
            ),
            repository: try! SwiftDataTaskRepository(inMemory: true),
            initialScan: UITestPhotoLibraryService.snapshot(for: .queuesLoadFailure)
        )
    }

    static func makeModel(reset: Bool) -> AppModel {
        let repository = try! SwiftDataTaskRepository()
        if reset {
            try! repository.clearHistory()
            let task = CleanupTask(
                id: "queue-fixture-task",
                type: .screenshots,
                title: "整理队列",
                reason: "测试队列恢复",
                assetIDs: UITestPhotoLibraryService.queueDescriptors.map(\.id),
                estimatedBytes: 3_000,
                estimatedMinutes: 1,
                risk: .low,
                confidence: 1,
                createdAt: Date(timeIntervalSince1970: 1_000),
                updatedAt: Date(timeIntervalSince1970: 1_000)
            )
            try! repository.save(task: task)
            try! repository.save(decisions: [
                PhotoDecision(
                    assetID: "queue-later",
                    kind: .decideLater,
                    estimatedBytes: 1_000,
                    taskID: task.id,
                    createdAt: Date(timeIntervalSince1970: 1_100)
                ),
                PhotoDecision(
                    assetID: "queue-protected",
                    kind: .protect,
                    estimatedBytes: 2_000,
                    taskID: task.id,
                    createdAt: Date(timeIntervalSince1970: 1_200)
                )
            ])
        }
        return AppModel(
            library: UITestPhotoLibraryService(authorization: .authorized, fixture: .queues),
            repository: repository,
            initialScan: UITestPhotoLibraryService.snapshot(for: .queues)
        )
    }
}

private enum StatisticsUITestFixture {
    static func makeModel(
        clearFailures: Int = 0,
        initialReadFailures: Int = 0,
        scanFixture: UITestPhotoLibraryService.Fixture = .statisticsHistory
    ) -> AppModel {
        let storage = try! SwiftDataTaskRepository(inMemory: true)
        let repository = WeeklyInboxUITestRepository(storage: storage)
        repository.remainingClearFailures = clearFailures
        repository.remainingLatestCheckpointReadFailures = initialReadFailures
        let date = Date(timeIntervalSince1970: 4_000)
        var snapshot = UITestPhotoLibraryService.snapshot(for: scanFixture)
        if scanFixture == .statistics || scanFixture == .statisticsHistory {
            snapshot.localCount = 8
            snapshot.iCloudOnlyCount = 1
        }
        let decisions = [
            PhotoDecision(assetID: "statistics-keep", kind: .keep, createdAt: date),
            PhotoDecision(assetID: "statistics-archive", kind: .archive, createdAt: date),
            PhotoDecision(assetID: "statistics-protect", kind: .protect, createdAt: date),
            PhotoDecision(assetID: "statistics-later", kind: .decideLater, createdAt: date),
            PhotoDecision(assetID: "statistics-delete", kind: .deleteCandidate, estimatedBytes: 4_096, createdAt: date)
        ]
        let completedTask = CleanupTask(
            id: "statistics-completed",
            type: .weekly,
            title: "已完成整理",
            reason: "测试",
            assetIDs: ["statistics-keep"],
            estimatedBytes: 0,
            estimatedMinutes: 1,
            risk: .low,
            confidence: 1,
            status: .completed,
            createdAt: date,
            updatedAt: date
        )
        let queuedTask = CleanupTask(
            id: "statistics-queued",
            type: .weekly,
            title: "待处理整理",
            reason: "测试",
            assetIDs: ["statistics-later"],
            estimatedBytes: 0,
            estimatedMinutes: 1,
            risk: .low,
            confidence: 1,
            status: .queued,
            createdAt: date,
            updatedAt: date
        )
        try! repository.save(checkpoint: ScanCheckpoint(
            id: "statistics-scan",
            stage: .completed,
            processedAssetIDs: decisions.map(\.assetID),
            discoveredCount: 9,
            snapshot: snapshot,
            updatedAt: date
        ))
        try! repository.save(tasks: [completedTask, queuedTask])
        try! repository.save(decisions: decisions)
        try! repository.save(transaction: MutationTransaction(
            id: "statistics-archive-transaction",
            operation: .archive,
            items: [MutationItem(assetID: "statistics-archive", state: .succeeded)],
            createdAt: date
        ))
        try! repository.save(transaction: MutationTransaction(
            id: "statistics-delete-transaction",
            operation: .delete,
            items: [MutationItem(assetID: "statistics-delete", state: .succeeded)],
            createdAt: date
        ))
        try! repository.save(summary: CleanupSummary(decisions: decisions, elapsedSeconds: 1, createdAt: date))

        let mutator = UITestStatisticsInventoryMutator(
            assetIDs: Set(decisions.map(\.assetID)),
            albums: [PhotoAlbumDescriptor(id: "statistics-album", title: "整理相册", assetCount: 0)]
        )
        let model = AppModel(
            library: UITestPhotoLibraryService(authorization: .authorized, fixture: scanFixture),
            repository: repository,
            mutator: mutator,
            initialScan: snapshot,
            statisticsInventorySignal: { await mutator.inventoryFingerprint() },
            statisticsClearCountSignal: { repository.clearCallCount }
        )
        // Statistics fixtures represent an already-authorized, settled screen.
        // Prevent the app lifecycle from starting a background scan and replacing
        // the injected cancellation/failure phase before the test can inspect it.
        model.authorization = .authorized
        model.hasLoadedAuthorization = true
        return model
    }
}

private enum WeeklyInboxUITestFixture {
    static func makeLoadingModel() -> AppModel {
        let model = AppModel(
            library: UITestPhotoLibraryService(authorization: .authorized, fixture: .queuesLoading),
            repository: makeRepository(hasWork: true),
            initialScan: UITestPhotoLibraryService.snapshot(for: .weeklyWork),
            initialActiveRoute: .weeklyInbox
        )
        model.authorization = .authorized
        model.hasLoadedAuthorization = true
        return model
    }

    static func makeModel(hasWork: Bool) -> AppModel {
        let repository = makeRepository(hasWork: hasWork)
        let model = AppModel(
            library: UITestPhotoLibraryService(
                authorization: .authorized,
                fixture: hasWork ? .weeklyWork : .weeklyEmpty
            ),
            repository: repository,
            initialScan: UITestPhotoLibraryService.snapshot(for: hasWork ? .weeklyWork : .weeklyEmpty),
            initialActiveRoute: .weeklyInbox
        )
        model.authorization = .authorized
        model.hasLoadedAuthorization = true
        return model
    }

    static func makeLoadFailureModel() -> AppModel {
        let storage = makeRepository(hasWork: true)
        let repository = WeeklyInboxUITestRepository(storage: storage)
        // With the fixture marked as already authorized, the first weekly
        // refresh is the user-visible load and should exercise the recovery UI.
        repository.taskReadFailureCall = 1
        let model = AppModel(
            library: UITestPhotoLibraryService(authorization: .authorized, fixture: .weeklyWork),
            repository: repository,
            initialScan: UITestPhotoLibraryService.snapshot(for: .weeklyWork),
            initialActiveRoute: .weeklyInbox
        )
        model.authorization = .authorized
        model.hasLoadedAuthorization = true
        return model
    }

    static func makeOverLimitModel() -> AppModel {
        let repository = makeRepository(hasWork: false)
        try! repository.save(task: CleanupTask(
            id: "weekly-ui-over-limit",
            type: .weekly,
            title: "完整整理任务",
            reason: "需要保持完整所有权",
            assetIDs: ["weekly-over-limit"],
            estimatedBytes: 1_000,
            estimatedMinutes: 6,
            risk: .low,
            confidence: 1,
            createdAt: .now,
            updatedAt: .now
        ))
        try! repository.save(checkpoint: ScanCheckpoint(
            id: "weekly-ui-over-limit-baseline",
            stage: .completed,
            processedAssetIDs: ["weekly-over-limit"],
            discoveredCount: 1,
            updatedAt: .now
        ))
        let model = AppModel(
            library: UITestPhotoLibraryService(authorization: .authorized, fixture: .weeklyOverLimit),
            repository: repository,
            initialScan: UITestPhotoLibraryService.snapshot(for: .weeklyOverLimit),
            initialActiveRoute: .weeklyInbox
        )
        model.authorization = .authorized
        model.hasLoadedAuthorization = true
        return model
    }

    static func makeTransitionFailureModel() -> AppModel {
        let storage = try! SwiftDataTaskRepository(inMemory: true)
        let summary = CleanupSummary(
            decisions: [PhotoDecision(assetID: "weekly-transition-keep", kind: .keep)],
            elapsedSeconds: nil,
            id: CleanupSummary.identifier(forTaskID: "weekly-transition-failure")
        )
        try! storage.save(summary: summary)
        var settings = WorkflowSettings.defaults
        settings.pendingResultSource = .summary(summary.id)
        try! storage.save(settings: settings)
        let repository = WeeklyInboxUITestRepository(storage: storage)
        repository.failAllSettingsWrites = true
        return AppModel(
            library: UITestPhotoLibraryService(authorization: .authorized, fixture: .weeklyEmpty),
            repository: repository,
            initialScan: .idle,
            initialActiveRoute: .result(.summary(summary.id))
        )
    }

    private static func makeRepository(hasWork: Bool) -> SwiftDataTaskRepository {
        let repository = try! SwiftDataTaskRepository(inMemory: true)
        let now = Date()
        let summary = CleanupSummary(
            decisions: [PhotoDecision(assetID: "weekly-meaningful", kind: .keep)],
            elapsedSeconds: nil,
            id: CleanupSummary.identifier(forTaskID: "weekly-ui-meaningful"),
            createdAt: now.addingTimeInterval(-10 * 86_400)
        )
        var settings = WorkflowSettings.defaults
        settings.weeklyModeEnabled = true
        try! repository.save(summary: summary)
        try! repository.save(settings: settings)
        try! repository.save(checkpoint: ScanCheckpoint(
            id: "weekly-ui-baseline",
            stage: .completed,
            processedAssetIDs: hasWork ? ["weekly-deferred"] : [],
            discoveredCount: hasWork ? 2 : 0,
            updatedAt: now.addingTimeInterval(-7 * 86_400)
        ))
        if hasWork {
            try! repository.save(decision: PhotoDecision(
                assetID: "weekly-deferred",
                kind: .decideLater,
                taskID: "weekly-original-task",
                createdAt: now.addingTimeInterval(-8 * 86_400)
            ))
        }
        return repository
    }
}

@MainActor
private final class WeeklyInboxUITestRepository: TaskRepository {
    let storage: SwiftDataTaskRepository
    var taskReadFailureCall: Int?
    var remainingSettingsWriteFailures = 0
    var failAllSettingsWrites = false
    var remainingClearFailures = 0
    var remainingLatestCheckpointReadFailures = 0
    var remainingTransactionReadFailures = 0
    private(set) var clearCallCount = 0
    private var taskReadCount = 0

    init(storage: SwiftDataTaskRepository) { self.storage = storage }

    func save(checkpoint: ScanCheckpoint) throws { try storage.save(checkpoint: checkpoint) }
    func latestCheckpoint() throws -> ScanCheckpoint? {
        if remainingLatestCheckpointReadFailures > 0 {
            remainingLatestCheckpointReadFailures -= 1
            throw WeeklyInboxUITestFailure.forced
        }
        return try storage.latestCheckpoint()
    }
    func latestCompletedCheckpoint() throws -> ScanCheckpoint? { try storage.latestCompletedCheckpoint() }
    func initialCompletedCheckpoint() throws -> RepositoryLookup<ScanCheckpoint> { try storage.initialCompletedCheckpoint() }
    func save(task: CleanupTask) throws { try storage.save(task: task) }
    func save(tasks: [CleanupTask]) throws { try storage.save(tasks: tasks) }
    func tasks() throws -> [CleanupTask] {
        taskReadCount += 1
        if taskReadCount == taskReadFailureCall {
            throw WeeklyInboxUITestFailure.forced
        }
        return try storage.tasks()
    }
    func applySingleDecision(_ decision: PhotoDecision, undo: DecisionUndoEntry, task: CleanupTask?) throws { try storage.applySingleDecision(decision, undo: undo, task: task) }
    func save(decision: PhotoDecision) throws { try storage.save(decision: decision) }
    func save(decisions: [PhotoDecision]) throws { try storage.save(decisions: decisions) }
    func completeComparison(taskID: String, decisions: [PhotoDecision]) throws { try storage.completeComparison(taskID: taskID, decisions: decisions) }
    func completeArchive(transaction: MutationTransaction, decision: PhotoDecision, recentAlbumIDs: [String]) throws { try storage.completeArchive(transaction: transaction, decision: decision, recentAlbumIDs: recentAlbumIDs) }
    func removeDecision(for assetID: String) throws { try storage.removeDecision(for: assetID) }
    func removeDecisions(for assetIDs: Set<String>) throws { try storage.removeDecisions(for: assetIDs) }
    func decision(for assetID: String) throws -> PhotoDecision? { try storage.decision(for: assetID) }
    func decisions() throws -> [PhotoDecision] { try storage.decisions() }
    func save(undo: DecisionUndoEntry) throws { try storage.save(undo: undo) }
    func latestUndo() throws -> DecisionUndoEntry? { try storage.latestUndo() }
    func removeUndo(id: UUID) throws { try storage.removeUndo(id: id) }
    func save(transaction: MutationTransaction) throws { try storage.save(transaction: transaction) }
    func transactions() throws -> [MutationTransaction] { try storage.transactions() }
    func transaction(id: String) throws -> RepositoryLookup<MutationTransaction> {
        if remainingTransactionReadFailures > 0 {
            remainingTransactionReadFailures -= 1
            throw WeeklyInboxUITestFailure.forced
        }
        return try storage.transaction(id: id)
    }
    func save(settings: WorkflowSettings) throws {
        if failAllSettingsWrites { throw WeeklyInboxUITestFailure.forced }
        if remainingSettingsWriteFailures > 0 {
            remainingSettingsWriteFailures -= 1
            throw WeeklyInboxUITestFailure.forced
        }
        try storage.save(settings: settings)
    }
    func settings() throws -> WorkflowSettings { try storage.settings() }
    func save(summary: CleanupSummary) throws { try storage.save(summary: summary) }
    func summaries() throws -> [CleanupSummary] { try storage.summaries() }
    func summary(id: UUID) throws -> RepositoryLookup<CleanupSummary> { try storage.summary(id: id) }
    func reconcile(availableAssetIDs: Set<String>) throws { try storage.reconcile(availableAssetIDs: availableAssetIDs) }
    func clearHistory() throws {
        clearCallCount += 1
        if remainingClearFailures > 0 {
            remainingClearFailures -= 1
            throw WeeklyInboxUITestFailure.forced
        }
        try storage.clearHistory()
    }
}

private enum WeeklyInboxUITestFailure: LocalizedError {
    case forced

    var errorDescription: String? { "无法读取本地整理记录，请重试。" }
}
#endif

#Preview {
    ContentView()
}
