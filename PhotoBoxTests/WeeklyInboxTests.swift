import Foundation
import SwiftData
import Testing
@testable import PhotoBox

@Suite("Meaningful cleanup transition")
@MainActor
struct MeaningfulCleanupTransitionTests {
    // Production break: merely opening a real task or loading a zero-decision Result enables weekly mode.
    @Test("Empty Result and an opened task do not enable weekly mode")
    func emptyResultAndOpenedTaskRemainInitialCleanup() async throws {
        let summaryRepository = try SwiftDataTaskRepository(inMemory: true)
        let emptySummary = CleanupSummary(
            decisions: [],
            elapsedSeconds: nil,
            id: CleanupSummary.identifier(forTaskID: "empty-result")
        )
        try summaryRepository.save(summary: emptySummary)
        let summaryModel = AppModel(
            library: WeeklyInboxReader(descriptors: []),
            repository: summaryRepository,
            initialScan: .idle,
            initialActiveRoute: .result(.summary(emptySummary.id))
        )

        await summaryModel.prepareCleanupResults(source: .summary(emptySummary.id))

        #expect(!summaryModel.weeklyModeEnabled)
        #expect(!(try summaryRepository.settings().weeklyModeEnabled))

        let taskRepository = try SwiftDataTaskRepository(inMemory: true)
        let task = CleanupTask.weeklyFixture(id: "opened-without-decision", assetIDs: ["opened"])
        try taskRepository.save(task: task)
        let taskModel = AppModel(
            library: WeeklyInboxReader(descriptors: [weeklyDescriptor("opened")]),
            repository: taskRepository,
            initialScan: .idle
        )

        await taskModel.prepareSingleDecision(taskID: task.id)

        #expect(taskModel.singleDecisionFlow(for: task.id) != nil)
        #expect(try taskRepository.decisions().isEmpty)
        #expect(!taskModel.weeklyModeEnabled)
        #expect(!(try taskRepository.settings().weeklyModeEnabled))
    }

    @Test("Diagnosis-only and stale-only activity leave weekly mode disabled")
    func unsupportedActivityDoesNotEnableWeeklyMode() async throws {
        let diagnosisRepository = try SwiftDataTaskRepository(inMemory: true)
        let diagnosisModel = AppModel(
            library: WeeklyInboxReader(descriptors: []),
            repository: diagnosisRepository,
            initialScan: .idle
        )

        #expect(!diagnosisModel.weeklyModeEnabled)
        #expect(!(try diagnosisRepository.settings().weeklyModeEnabled))

        let staleRepository = try SwiftDataTaskRepository(inMemory: true)
        let transaction = MutationTransaction(
            id: "stale-only",
            operation: .delete,
            items: [MutationItem(assetID: "gone", state: .stale)],
            createdAt: Date(timeIntervalSince1970: 100),
            completedAt: Date(timeIntervalSince1970: 110),
            backendMode: .simulated
        )
        try staleRepository.save(transaction: transaction)
        let staleModel = AppModel(
            library: WeeklyInboxReader(descriptors: []),
            repository: staleRepository,
            mutator: SimulatedPhotoLibraryMutator(assetIDs: []),
            initialScan: .idle,
            initialActiveRoute: .result(.transaction(transaction.id))
        )

        await staleModel.prepareCleanupResults(source: .transaction(transaction.id))

        #expect(!staleModel.weeklyModeEnabled)
        #expect(!(try staleRepository.settings().weeklyModeEnabled))
    }

    @Test("Each supported no-delete category enables weekly mode only after Result loads")
    func supportedSummaryCategoriesEnableWeeklyMode() async throws {
        for (index, kind) in [
            PhotoDecisionKind.keep,
            .archive,
            .protect,
            .decideLater
        ].enumerated() {
            let repository = try SwiftDataTaskRepository(inMemory: true)
            let summary = CleanupSummary(
                decisions: [PhotoDecision(assetID: "asset-\(index)", kind: kind)],
                elapsedSeconds: nil,
                id: CleanupSummary.identifier(forTaskID: "meaningful-\(index)"),
                createdAt: Date(timeIntervalSince1970: TimeInterval(200 + index))
            )
            try repository.save(summary: summary)
            let model = AppModel(
                library: WeeklyInboxReader(descriptors: []),
                repository: repository,
                initialScan: .idle,
                initialActiveRoute: .result(.summary(summary.id))
            )

            #expect(!model.weeklyModeEnabled)
            await model.prepareCleanupResults(source: .summary(summary.id))

            #expect(model.weeklyModeEnabled)
            #expect(try repository.settings().weeklyModeEnabled)
        }
    }

    @Test("An executed reviewed-delete result is meaningful while unresolved items remain")
    func executedDeleteEnablesWeeklyMode() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let transaction = MutationTransaction(
            id: "reviewed-delete",
            operation: .delete,
            items: [MutationItem(assetID: "retry", state: .failed)],
            createdAt: Date(timeIntervalSince1970: 300),
            submittedAt: Date(timeIntervalSince1970: 301),
            completedAt: Date(timeIntervalSince1970: 302),
            backendMode: .simulated
        )
        try repository.save(transaction: transaction)
        let model = AppModel(
            library: WeeklyInboxReader(descriptors: [weeklyDescriptor("retry")]),
            repository: repository,
            mutator: SimulatedPhotoLibraryMutator(assetIDs: ["retry"]),
            initialScan: .idle,
            initialActiveRoute: .result(.transaction(transaction.id))
        )

        await model.prepareCleanupResults(source: .transaction(transaction.id))

        #expect(model.weeklyModeEnabled)
        #expect(try repository.settings().weeklyModeEnabled)
    }

    @Test("A stale-only delete journal is meaningful when its completed task has a supported decision")
    func staleDeleteWithSupportedDecisionEnablesWeeklyMode() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        try repository.save(decisions: [
            PhotoDecision(assetID: "gone", kind: .deleteCandidate, taskID: "mixed"),
            PhotoDecision(assetID: "kept", kind: .keep, taskID: "mixed")
        ])
        let transaction = MutationTransaction(
            id: "stale-with-keep",
            operation: .delete,
            items: [MutationItem(assetID: "gone", state: .stale)],
            createdAt: Date(timeIntervalSince1970: 320),
            completedAt: Date(timeIntervalSince1970: 321),
            backendMode: .simulated
        )
        try repository.save(transaction: transaction)
        let model = AppModel(
            library: WeeklyInboxReader(descriptors: [weeklyDescriptor("kept")]),
            repository: repository,
            mutator: SimulatedPhotoLibraryMutator(assetIDs: ["kept"]),
            initialScan: .idle,
            initialActiveRoute: .result(.transaction(transaction.id))
        )

        await model.prepareCleanupResults(source: .transaction(transaction.id))

        #expect(model.weeklyModeEnabled)
        #expect(try repository.settings().weeklyModeEnabled)
    }

    @Test("Weekly transition is persistent, idempotent, and lower priority than Result and task recovery")
    func transitionPersistsWithRoutePriority() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let summary = CleanupSummary(
            decisions: [PhotoDecision(assetID: "keep", kind: .keep)],
            elapsedSeconds: nil,
            id: CleanupSummary.identifier(forTaskID: "persistent"),
            createdAt: Date(timeIntervalSince1970: 400)
        )
        try repository.save(summary: summary)
        var settings = WorkflowSettings.defaults
        settings.pendingResultSource = .summary(summary.id)
        try repository.save(settings: settings)
        let model = AppModel(library: WeeklyInboxReader(descriptors: []), repository: repository)

        var simultaneousActive = CleanupTask.weeklyFixture(id: "simultaneous-active", assetIDs: ["active"])
        simultaneousActive.status = .paused
        try repository.save(task: simultaneousActive)
        let simultaneousRelaunch = AppModel(
            library: WeeklyInboxReader(descriptors: []),
            repository: repository
        )
        #expect(simultaneousRelaunch.activeRoute == .result(.summary(summary.id)))
        try repository.save(task: {
            var completed = simultaneousActive
            completed.status = .completed
            return completed
        }())

        await model.prepareCleanupResults(source: .summary(summary.id))
        await model.prepareCleanupResults(source: .summary(summary.id))

        #expect(try repository.summaries() == [summary])
        #expect(try repository.settings().weeklyModeEnabled)
        #expect(model.taskNavigationPath == [.result(.summary(summary.id))])

        let resultRelaunch = AppModel(library: WeeklyInboxReader(descriptors: []), repository: repository)
        #expect(resultRelaunch.activeRoute == .result(.summary(summary.id)))

        resultRelaunch.returnFromCleanupResults()
        #expect(resultRelaunch.activeRoute == nil)
        #expect(resultRelaunch.taskNavigationPath.isEmpty)

        let weeklyRelaunch = AppModel(library: WeeklyInboxReader(descriptors: []), repository: repository)
        #expect(weeklyRelaunch.activeRoute == nil)

        var active = CleanupTask.weeklyFixture(id: "active", assetIDs: ["active-2"])
        active.status = .paused
        try repository.save(task: active)
        let taskRelaunch = AppModel(library: WeeklyInboxReader(descriptors: []), repository: repository)
        #expect(taskRelaunch.activeRoute == nil)
        #expect(taskRelaunch.cleanupTasks.contains { $0.id == active.id && $0.status == .paused })
    }

    @Test("A settings write failure does not optimistically enable weekly mode and can retry")
    func transitionWriteFailureIsRecoverable() async throws {
        let storage = try SwiftDataTaskRepository(inMemory: true)
        let summary = CleanupSummary(
            decisions: [PhotoDecision(assetID: "keep", kind: .keep)],
            elapsedSeconds: nil,
            id: CleanupSummary.identifier(forTaskID: "write-failure")
        )
        try storage.save(summary: summary)
        var settings = WorkflowSettings.defaults
        settings.pendingResultSource = .summary(summary.id)
        try storage.save(settings: settings)
        let repository = WeeklyFailingRepository(storage: storage)
        repository.failSettingsWrites = true
        let model = AppModel(
            library: WeeklyInboxReader(descriptors: []),
            repository: repository,
            initialScan: .idle,
            initialActiveRoute: .result(.summary(summary.id))
        )

        await model.prepareCleanupResults(source: .summary(summary.id))

        #expect(!model.weeklyModeEnabled)
        #expect(!(try storage.settings().weeklyModeEnabled))
        #expect(model.persistenceErrorMessage != nil)
        #expect(model.weeklyTransitionNeedsRetry)

        model.returnFromCleanupResults()

        #expect(model.activeRoute == .result(.summary(summary.id)))
        #expect(model.taskNavigationPath == [.result(.summary(summary.id))])
        #expect(try storage.settings().pendingResultSource == .summary(summary.id))

        repository.failSettingsWrites = false
        model.retryWeeklyModeTransition()

        #expect(model.weeklyModeEnabled)
        #expect(try storage.settings().weeklyModeEnabled)
        #expect(!model.weeklyTransitionNeedsRetry)

        model.returnFromCleanupResults()
        #expect(model.activeRoute == nil)
        #expect(try storage.settings().pendingResultSource == nil)
    }

    // Production break: a repository that never accepts the weekly setting traps Result forever.
    @Test("A permanent weekly transition failure can exit while preserving relaunch recovery")
    func permanentTransitionFailureCanExitWithRecovery() async throws {
        let storage = try SwiftDataTaskRepository(inMemory: true)
        let summary = CleanupSummary(
            decisions: [PhotoDecision(assetID: "permanent-keep", kind: .keep)],
            elapsedSeconds: nil,
            id: CleanupSummary.identifier(forTaskID: "permanent-write-failure")
        )
        try storage.save(summary: summary)
        var settings = WorkflowSettings.defaults
        settings.pendingResultSource = .summary(summary.id)
        try storage.save(settings: settings)
        let repository = WeeklyFailingRepository(storage: storage)
        repository.failSettingsWrites = true
        let source = CleanupResultSource.summary(summary.id)
        let model = AppModel(
            library: WeeklyInboxReader(descriptors: []),
            repository: repository,
            initialScan: .idle,
            initialActiveRoute: .result(source)
        )
        await model.prepareCleanupResults(source: source)

        model.leaveCleanupResultsKeepingRecovery()

        #expect(model.activeRoute == nil)
        #expect(model.taskNavigationPath.isEmpty)
        #expect(!model.weeklyModeEnabled)
        #expect(model.weeklyTransitionNeedsRetry)
        #expect(model.cleanupResultsSource == source)
        #expect(try storage.settings().pendingResultSource == source)

        let relaunched = AppModel(library: WeeklyInboxReader(descriptors: []), repository: repository)
        #expect(relaunched.activeRoute == .result(source))
    }
}

@Suite("Weekly inbox generation")
@MainActor
struct WeeklyInboxGenerationTests {
    @Test("All four real sources preserve exact identifiers and de-duplicate active ownership")
    func includesAllSourcesWithExactOwnership() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let meaningfulDate = now.addingTimeInterval(-20 * 86_400)
        var unfinished = CleanupTask.weeklyFixture(id: "unfinished-task", assetIDs: ["unfinished"])
        unfinished.status = .inProgress
        unfinished.ownedAssetIDs = ["unfinished"]
        let descriptors = [
            weeklyDescriptor("unfinished", createdAt: meaningfulDate.addingTimeInterval(-100)),
            weeklyDescriptor("expired", createdAt: now.addingTimeInterval(-40 * 86_400), isScreenshot: true),
            weeklyDescriptor("new", createdAt: now.addingTimeInterval(-60)),
            weeklyDescriptor("deferred", createdAt: meaningfulDate.addingTimeInterval(-100)),
            weeklyDescriptor("duplicate-owned", createdAt: now.addingTimeInterval(-30), isScreenshot: true)
        ]
        var duplicateOwner = CleanupTask.weeklyFixture(id: "owner", assetIDs: ["duplicate-owned"])
        duplicateOwner.status = .inProgress
        duplicateOwner.ownedAssetIDs = ["duplicate-owned"]
        let decisions = [
            PhotoDecision(
                assetID: "deferred",
                kind: .decideLater,
                taskID: "original-task",
                createdAt: now.addingTimeInterval(-8 * 86_400)
            )
        ]

        let plan = WeeklyInboxGenerator().generate(
            descriptors: descriptors,
            tasks: [unfinished, duplicateOwner],
            decisions: decisions,
            previouslyAccessibleAssetIDs: ["unfinished", "expired", "deferred", "duplicate-owned"],
            screenshotRetentionDays: 30,
            meaningfulCleanupDate: meaningfulDate,
            now: now
        )

        let expectedSources: Set<WeeklyInboxSource> = [.unfinished, .expiredScreenshot, .newAsset, .deferred]
        #expect(Set(plan.items.map(\.source)) == expectedSources)
        #expect(Set(plan.items.flatMap(\.assetIDs)) == ["unfinished", "duplicate-owned", "expired", "new", "deferred"])
        #expect(plan.items.first(where: { $0.source == .unfinished && $0.assetIDs == ["unfinished"] })?.task?.id == unfinished.id)
        #expect(plan.items.first(where: { $0.source == .deferred })?.decision?.taskID == "original-task")
        #expect(plan.items.flatMap(\.assetIDs).count == Set(plan.items.flatMap(\.assetIDs)).count)

        let unfinishedItem = try #require(plan.items.first { $0.source == .unfinished && $0.task?.id == unfinished.id })
        #expect(unfinishedItem.title == "整理")
        #expect(unfinishedItem.reason == "测试")
        #expect(unfinishedItem.task?.type == .screenshots)
        let expiredItem = try #require(plan.items.first { $0.source == .expiredScreenshot })
        #expect(expiredItem.title == WeeklyInboxSource.expiredScreenshot.title)
        #expect(expiredItem.reason == "超过 30 天且仍可在本机访问")
        #expect(expiredItem.task?.type == .screenshots)
        let newItem = try #require(plan.items.first { $0.source == .newAsset })
        #expect(newItem.title == WeeklyInboxSource.newAsset.title)
        #expect(newItem.reason == "上次整理后新增且尚未决定")
        #expect(newItem.task?.type == .weekly)
        let deferredItem = try #require(plan.items.first { $0.source == .deferred })
        #expect(deferredItem.title == WeeklyInboxSource.deferred.title)
        #expect(deferredItem.reason == "已到再次查看的时间，可继续稍后决定")
        #expect(deferredItem.task == nil)
    }

    @Test("Favorited expired screenshots are not added to the weekly inbox")
    func favoriteExpiredScreenshotIsExcluded() {
        let now = Date(timeIntervalSince1970: 2_100_000)
        let plan = WeeklyInboxGenerator().generate(
            descriptors: [weeklyDescriptor(
                "favorite-expired",
                createdAt: now.addingTimeInterval(-40 * 86_400),
                isScreenshot: true,
                isFavorite: true
            )],
            tasks: [],
            decisions: [],
            previouslyAccessibleAssetIDs: ["favorite-expired"],
            screenshotRetentionDays: 30,
            meaningfulCleanupDate: now.addingTimeInterval(-10 * 86_400),
            now: now
        )

        #expect(plan.items.isEmpty)
    }

    @Test("Repeated deferral follows the existing monotonic timestamp and is not due again early")
    func repeatedDeferralReschedulesEligibility() async throws {
        let now = Date(timeIntervalSince1970: 3_000_000)
        let repository = try SwiftDataTaskRepository(inMemory: true)
        try repository.save(decision: PhotoDecision(
            assetID: "later",
            kind: .decideLater,
            taskID: "original",
            createdAt: now.addingTimeInterval(-8 * 86_400)
        ))
        let futureQueueDate = now.addingTimeInterval(30)
        try repository.save(decision: PhotoDecision(
            assetID: "future-queue-item",
            kind: .decideLater,
            taskID: "other",
            createdAt: futureQueueDate
        ))
        let descriptor = weeklyDescriptor("later", createdAt: now.addingTimeInterval(-100))
        let futureDescriptor = weeklyDescriptor("future-queue-item", createdAt: now.addingTimeInterval(-100))
        let queue = DecisionQueueModel(
            repository: repository,
            library: WeeklyInboxReader(descriptors: [descriptor, futureDescriptor]),
            now: { now }
        )
        await queue.load()
        queue.deferAgain(assetID: "later")
        let storedDecision = try repository.decision(for: "later")
        let replacement = try #require(storedDecision)

        let plan = WeeklyInboxGenerator().generate(
            descriptors: [descriptor],
            tasks: [],
            decisions: [replacement],
            previouslyAccessibleAssetIDs: ["later"],
            screenshotRetentionDays: 30,
            meaningfulCleanupDate: now.addingTimeInterval(-30 * 86_400),
            now: now
        )

        #expect(replacement.kind == .decideLater)
        #expect(replacement.taskID == "original")
        #expect(replacement.createdAt == futureQueueDate.addingTimeInterval(0.001))
        #expect(plan.items.isEmpty)

        queue.deferAgain(assetID: "later")
        let storedSecondReplacement = try repository.decision(for: "later")
        let secondReplacement = try #require(storedSecondReplacement)
        #expect(secondReplacement.createdAt == replacement.createdAt.addingTimeInterval(0.001))
    }

    @Test("Five-minute selection keeps whole tasks at the exact boundary and reports real progress")
    func deterministicFiveMinuteBoundaryAndProgress() {
        let now = Date(timeIntervalSince1970: 4_000_000)
        var first = CleanupTask.weeklyFixture(id: "a", assetIDs: ["a1", "a2", "a3"], estimatedMinutes: 3, confidence: 1)
        first.status = .paused
        first.currentAssetIndex = 1
        var second = CleanupTask.weeklyFixture(id: "b", assetIDs: ["b1", "b2"], estimatedMinutes: 2, confidence: 0.9)
        second.status = .queued
        let third = CleanupTask.weeklyFixture(id: "c", assetIDs: ["c1"], estimatedMinutes: 1, confidence: 0.1)
        let descriptors = (first.assetIDs + second.assetIDs + third.assetIDs).map {
            weeklyDescriptor($0, createdAt: now.addingTimeInterval(-100))
        }

        let plan = WeeklyInboxGenerator().generate(
            descriptors: descriptors,
            tasks: [third, second, first],
            decisions: [],
            previouslyAccessibleAssetIDs: Set(descriptors.map(\.id)),
            screenshotRetentionDays: 30,
            meaningfulCleanupDate: now.addingTimeInterval(-10 * 86_400),
            now: now
        )

        #expect(plan.items.compactMap { $0.task?.id } == ["a", "b"])
        #expect(plan.taskCount == 2)
        #expect(plan.estimatedMinutes == 5)
        #expect(plan.completedUnitCount == 1)
        #expect(plan.totalUnitCount == 5)
        #expect(plan.progress == 0.2)
        #expect(plan.items.allSatisfy { item in
            guard let task = item.task else { return true }
            return item.assetIDs == Array(task.assetIDs.dropFirst(task.currentAssetIndex))
        })
    }

    @Test("Inaccessible, protected, not-yet-due, and diagnostic-only records produce a truthful empty plan")
    func noEligibleWorkIsTrulyEmpty() {
        let now = Date(timeIntervalSince1970: 5_000_000)
        let descriptors = [
            weeklyDescriptor("cloud", availability: .iCloudOnly),
            weeklyDescriptor("protected"),
            weeklyDescriptor("later")
        ]
        let plan = WeeklyInboxGenerator().generate(
            descriptors: descriptors,
            tasks: [CleanupTask.weeklyFixture(id: "video", assetIDs: ["cloud"], type: .largeVideos)],
            decisions: [
                PhotoDecision(assetID: "protected", kind: .protect),
                PhotoDecision(assetID: "later", kind: .decideLater, createdAt: now.addingTimeInterval(-6 * 86_400))
            ],
            previouslyAccessibleAssetIDs: Set(descriptors.map(\.id)),
            screenshotRetentionDays: 30,
            meaningfulCleanupDate: now.addingTimeInterval(-30 * 86_400),
            now: now
        )

        #expect(plan.items.isEmpty)
        #expect(plan.taskCount == 0)
        #expect(plan.estimatedMinutes == 0)
        #expect(plan.progress == 1)
    }

    @Test("An in-progress task is omitted rather than split when it owns only part of its remaining assets")
    func partialTaskOwnershipIsNotSplit() {
        let now = Date(timeIntervalSince1970: 5_500_000)
        var owner = CleanupTask.weeklyFixture(id: "owner", assetIDs: ["shared"])
        owner.status = .inProgress
        owner.ownedAssetIDs = ["shared"]
        var partial = CleanupTask.weeklyFixture(id: "partial", assetIDs: ["shared", "exclusive"])
        partial.status = .inProgress
        partial.ownedAssetIDs = ["exclusive"]
        let descriptors = [weeklyDescriptor("shared"), weeklyDescriptor("exclusive")]

        let plan = WeeklyInboxGenerator().generate(
            descriptors: descriptors,
            tasks: [partial, owner],
            decisions: [],
            previouslyAccessibleAssetIDs: ["shared", "exclusive"],
            screenshotRetentionDays: 30,
            meaningfulCleanupDate: now.addingTimeInterval(-10 * 86_400),
            now: now
        )

        #expect(plan.items.compactMap { $0.task?.id } == ["owner"])
        #expect(plan.items.flatMap(\.assetIDs) == ["shared"])
    }

    // Production break: an omitted partial owner releases its authoritative asset into generated work.
    @Test("All active ownership is reserved before weekly ranking")
    func omittedOwnerStillReservesItsAssets() {
        let now = Date(timeIntervalSince1970: 5_600_000)
        var partial = CleanupTask.weeklyFixture(id: "partial-owner", assetIDs: ["shared", "exclusive"])
        partial.status = .inProgress
        partial.ownedAssetIDs = ["exclusive"]
        let plan = WeeklyInboxGenerator().generate(
            descriptors: [
                weeklyDescriptor("shared"),
                weeklyDescriptor("exclusive", createdAt: now.addingTimeInterval(-40 * 86_400), isScreenshot: true)
            ],
            tasks: [partial],
            decisions: [],
            previouslyAccessibleAssetIDs: ["shared", "exclusive"],
            screenshotRetentionDays: 30,
            meaningfulCleanupDate: now.addingTimeInterval(-10 * 86_400),
            now: now
        )

        #expect(!plan.items.flatMap(\.assetIDs).contains("exclusive"))
    }

    // Production break: filtering diagnostic task types before ownership collection leaks their active assets.
    @Test("Active large-video ownership is reserved from weekly generation")
    func activeLargeVideoOwnershipIsReserved() {
        let now = Date(timeIntervalSince1970: 5_650_000)
        var video = CleanupTask.weeklyFixture(
            id: "active-video",
            assetIDs: ["owned-video"],
            type: .largeVideos
        )
        video.status = .inProgress
        video.ownedAssetIDs = ["owned-video"]
        let plan = WeeklyInboxGenerator().generate(
            descriptors: [weeklyDescriptor(
                "owned-video",
                createdAt: now.addingTimeInterval(-40 * 86_400),
                isScreenshot: true
            )],
            tasks: [video],
            decisions: [],
            previouslyAccessibleAssetIDs: [],
            screenshotRetentionDays: 30,
            meaningfulCleanupDate: now.addingTimeInterval(-10 * 86_400),
            now: now
        )

        #expect(!plan.items.flatMap(\.assetIDs).contains("owned-video"))
    }

    // Production break: a qualifying whole task above the cap is reported as a tidy week.
    @Test("Work above the five-minute cap is not a tidy empty plan")
    func oversizedWholeTaskRemainsTruthful() {
        let now = Date(timeIntervalSince1970: 5_700_000)
        let oversized = CleanupTask.weeklyFixture(
            id: "oversized",
            assetIDs: ["oversized"],
            estimatedMinutes: 6
        )
        let plan = WeeklyInboxGenerator().generate(
            descriptors: [weeklyDescriptor("oversized")],
            tasks: [oversized],
            decisions: [],
            previouslyAccessibleAssetIDs: ["oversized"],
            screenshotRetentionDays: 30,
            meaningfulCleanupDate: now.addingTimeInterval(-10 * 86_400),
            now: now
        )

        #expect(plan.items.isEmpty)
        #expect(plan.estimatedMinutes == 0)
        #expect(plan.remainingTaskCount == 1)
        #expect(!plan.isTrulyEmpty)
    }

    // Production break: equal-ranked tasks inherit repository/input order when stable-ID tie-breaking is removed.
    @Test("Equal-ranked weekly tasks use stable identifier order")
    func equalRankUsesStableIDOrder() {
        let now = Date(timeIntervalSince1970: 5_800_000)
        let first = CleanupTask.weeklyFixture(id: "a-stable", assetIDs: ["a"])
        let second = CleanupTask.weeklyFixture(id: "b-stable", assetIDs: ["b"])
        let plan = WeeklyInboxGenerator().generate(
            descriptors: [weeklyDescriptor("b"), weeklyDescriptor("a")],
            tasks: [second, first],
            decisions: [],
            previouslyAccessibleAssetIDs: ["a", "b"],
            screenshotRetentionDays: 30,
            meaningfulCleanupDate: now.addingTimeInterval(-10 * 86_400),
            now: now
        )

        #expect(plan.items.compactMap { $0.task?.id } == ["a-stable", "b-stable"])
    }

    // Production break: one inaccessible descriptor suppresses otherwise eligible local weekly work.
    @Test("Mixed availability keeps eligible local work")
    func mixedAvailabilityKeepsLocalWork() {
        let now = Date(timeIntervalSince1970: 5_900_000)
        let plan = WeeklyInboxGenerator().generate(
            descriptors: [
                weeklyDescriptor("local-new", createdAt: now),
                weeklyDescriptor("cloud-new", createdAt: now, availability: .iCloudOnly)
            ],
            tasks: [],
            decisions: [],
            previouslyAccessibleAssetIDs: [],
            screenshotRetentionDays: 30,
            meaningfulCleanupDate: now.addingTimeInterval(-10 * 86_400),
            now: now
        )

        #expect(plan.items.flatMap(\.assetIDs) == ["local-new"])
        #expect(plan.remainingTaskCount == 0)
    }
}

@Suite("Weekly inbox loading and routing")
@MainActor
struct WeeklyInboxLoadingTests {
    @Test("A failed refresh preserves the last valid plan and reports recovery")
    func refreshFailurePreservesLastPlan() async throws {
        let now = Date(timeIntervalSince1970: 6_000_000)
        let storage = try weeklyEnabledRepository(at: now.addingTimeInterval(-10 * 86_400))
        let repository = WeeklyFailingRepository(storage: storage)
        let model = WeeklyInboxModel(
            repository: repository,
            library: WeeklyInboxReader(descriptors: [weeklyDescriptor("new", createdAt: now)]),
            previouslyAccessibleAssetIDs: [],
            now: { now }
        )
        await model.refresh(screenshotRetentionDays: 30)
        let firstPlan = model.plan

        repository.failReads = true
        await model.refresh(screenshotRetentionDays: 30)

        #expect(firstPlan?.items.map(\.assetIDs) == [["new"]])
        #expect(model.plan == firstPlan)
        #expect(model.errorMessage != nil)
        #expect(!model.isLoading)
    }

    @Test("Overlapping refreshes publish only the latest descriptor response")
    func overlappingRefreshIsLatestWins() async throws {
        let now = Date(timeIntervalSince1970: 7_000_000)
        let repository = try weeklyEnabledRepository(at: now.addingTimeInterval(-10 * 86_400))
        let reader = ControlledWeeklyInboxReader()
        let model = WeeklyInboxModel(
            repository: repository,
            library: reader,
            previouslyAccessibleAssetIDs: [],
            now: { now }
        )

        let first = Task { await model.refresh(screenshotRetentionDays: 30) }
        await reader.waitForRequestCount(1)
        let second = Task { await model.refresh(screenshotRetentionDays: 30) }
        await reader.waitForRequestCount(2)
        await reader.resolve(request: 2, descriptors: [weeklyDescriptor("latest", createdAt: now)])
        await second.value
        await reader.resolve(request: 1, descriptors: [weeklyDescriptor("stale", createdAt: now)])
        await first.value

        #expect(model.plan?.items.flatMap(\.assetIDs) == ["latest"])
        #expect(model.errorMessage == nil)
        #expect(!(try repository.tasks().contains { $0.assetIDs.contains("stale") }))
    }

    // Production break: cancelling the only current refresh leaves the model permanently loading.
    @Test("Cancelling the current refresh clears loading without publishing")
    func cancelledRefreshClearsLoading() async throws {
        let repository = try weeklyEnabledRepository(at: Date(timeIntervalSince1970: 7_100_000))
        let reader = ControlledWeeklyInboxReader()
        let model = WeeklyInboxModel(
            repository: repository,
            library: reader,
            previouslyAccessibleAssetIDs: []
        )
        let refresh = Task { await model.refresh(screenshotRetentionDays: 30) }
        await reader.waitForRequestCount(1)

        refresh.cancel()
        await reader.resolve(request: 1, descriptors: [weeklyDescriptor("cancelled")])
        await refresh.value

        #expect(!model.isLoading)
        #expect(model.plan == nil)
        #expect(try repository.tasks().isEmpty)
    }

    @Test("Weekly work starts explicitly through the existing task route")
    func productionRoutingUsesTaskLifecycle() async throws {
        let now = Date(timeIntervalSince1970: 8_000_000)
        let repository = try weeklyEnabledRepository(at: now.addingTimeInterval(-10 * 86_400))
        let model = AppModel(
            library: WeeklyInboxReader(descriptors: [weeklyDescriptor("new", createdAt: now)]),
            repository: repository
        )

        #expect(model.activeRoute == nil)
        await model.prepareWeeklyInbox()
        let item = try #require(model.weeklyInboxFlow?.plan?.items.first)

        model.startWeeklyInboxItem(item)

        let stored = try #require(repository.tasks().first(where: { $0.id == item.task?.id }))
        #expect(stored.assetIDs == ["new"])
        #expect(model.taskNavigationPath.last == .task(stored.id))
    }

    @Test("Generated work persists once and remains unfinished after a newer scan baseline")
    func generatedWorkSurvivesRelaunchWithoutDuplicates() async throws {
        let now = Date(timeIntervalSince1970: 8_500_000)
        let repository = try weeklyEnabledRepository(at: now.addingTimeInterval(-10 * 86_400))
        let descriptor = weeklyDescriptor("newly-accessible-old", createdAt: now.addingTimeInterval(-30 * 86_400))
        let first = WeeklyInboxModel(
            repository: repository,
            library: WeeklyInboxReader(descriptors: [descriptor]),
            previouslyAccessibleAssetIDs: [],
            now: { now }
        )

        await first.refresh(screenshotRetentionDays: 30)
        await first.refresh(screenshotRetentionDays: 30)

        let storedTasks = try repository.tasks()
        #expect(storedTasks.count == 1)
        #expect(storedTasks[0].assetIDs == [descriptor.id])

        let relaunched = WeeklyInboxModel(
            repository: repository,
            library: WeeklyInboxReader(descriptors: [descriptor]),
            previouslyAccessibleAssetIDs: [descriptor.id],
            now: { now.addingTimeInterval(60) }
        )
        await relaunched.refresh(screenshotRetentionDays: 30)

        #expect(relaunched.plan?.items.count == 1)
        #expect(relaunched.plan?.items.first?.source == .unfinished)
        #expect(relaunched.plan?.items.first?.task?.id == storedTasks[0].id)
    }

    @Test("Generated-task write failure publishes no unpersisted inbox and can retry")
    func generatedTaskWriteFailureIsRecoverable() async throws {
        let now = Date(timeIntervalSince1970: 8_700_000)
        let storage = try weeklyEnabledRepository(at: now.addingTimeInterval(-10 * 86_400))
        let repository = WeeklyFailingRepository(storage: storage)
        repository.failTaskWrites = true
        let model = WeeklyInboxModel(
            repository: repository,
            library: WeeklyInboxReader(descriptors: [weeklyDescriptor("new", createdAt: now)]),
            previouslyAccessibleAssetIDs: [],
            now: { now }
        )

        await model.refresh(screenshotRetentionDays: 30)

        #expect(model.plan == nil)
        #expect(model.errorMessage != nil)
        #expect(try storage.tasks().isEmpty)

        repository.failTaskWrites = false
        await model.refresh(screenshotRetentionDays: 30)

        #expect(model.plan?.items.count == 1)
        #expect(try storage.tasks().count == 1)
    }

    // Production break: replacing the atomic generated-task batch with per-item writes leaves a partial owner.
    @Test("A multi-task batch failure publishes and persists no partial weekly plan")
    func multiGeneratedTaskBatchFailureIsAtomic() async throws {
        let now = Date(timeIntervalSince1970: 8_800_000)
        let storage = try weeklyEnabledRepository(at: now.addingTimeInterval(-10 * 86_400))
        let repository = WeeklyFailingRepository(storage: storage)
        repository.failTaskWriteAtCall = 2
        let model = WeeklyInboxModel(
            repository: repository,
            library: WeeklyInboxReader(descriptors: [
                weeklyDescriptor("batch-a", createdAt: now),
                weeklyDescriptor("batch-b", createdAt: now)
            ]),
            previouslyAccessibleAssetIDs: [],
            now: { now }
        )

        await model.refresh(screenshotRetentionDays: 30)

        #expect(model.plan == nil)
        #expect(model.errorMessage != nil)
        #expect(try storage.tasks().isEmpty)
    }

    // Production break: a completed scan updates persistence but not the same AppModel's weekly baseline.
    @Test("A same-session completed scan becomes the persisted weekly baseline")
    func sameSessionCompletedScanUpdatesWeeklyBaseline() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let summary = CleanupSummary(
            decisions: [PhotoDecision(assetID: "meaningful", kind: .keep)],
            elapsedSeconds: nil,
            id: CleanupSummary.identifier(forTaskID: "same-session")
        )
        try repository.save(summary: summary)
        let model = AppModel(
            library: WeeklyInboxReader(descriptors: [weeklyDescriptor("preexisting")]),
            repository: repository,
            initialScan: .idle,
            initialActiveRoute: .result(.summary(summary.id))
        )

        await model.refreshAuthorization()
        try await waitForWeeklyCondition { model.scan.phase == .completed }
        await model.prepareCleanupResults(source: .summary(summary.id))
        await model.prepareWeeklyInbox()

        #expect(model.weeklyInboxFlow?.plan?.isTrulyEmpty == true)
        #expect(try repository.latestCompletedCheckpoint()?.processedAssetIDs == ["preexisting"])

        let relaunched = AppModel(
            library: WeeklyInboxReader(descriptors: [weeklyDescriptor("preexisting")]),
            repository: repository
        )
        await relaunched.prepareWeeklyInbox()
        #expect(relaunched.weeklyInboxFlow?.plan?.isTrulyEmpty == true)
    }

    // Production break: a later completed scan replaces the initial baseline and swallows a real delta.
    @Test("Later scans preserve the initial baseline for newly accessible work")
    func laterScanDoesNotReplaceInitialBaseline() async throws {
        let now = Date(timeIntervalSince1970: 8_920_000)
        let repository = try weeklyEnabledRepository(
            at: now.addingTimeInterval(-10 * 86_400),
            baselineAssetIDs: ["known"]
        )
        let newlyAccessible = weeklyDescriptor(
            "newly-accessible",
            createdAt: now.addingTimeInterval(-30 * 86_400)
        )
        let model = AppModel(
            library: WeeklyInboxReader(descriptors: [weeklyDescriptor("known"), newlyAccessible]),
            repository: repository
        )

        await model.refreshAuthorization()
        try await waitForWeeklyCondition { model.scan.phase == .completed }
        await model.prepareWeeklyInbox()

        #expect(model.weeklyInboxFlow?.plan?.items.flatMap(\.assetIDs) == [newlyAccessible.id])
    }

    // Production break: an absent or corrupt baseline is coerced to empty and classifies the library as all-new.
    @Test("Missing and corrupt initial baselines fail closed")
    func unavailableInitialBaselineFailsClosed() async throws {
        let now = Date(timeIntervalSince1970: 8_940_000)
        let descriptor = weeklyDescriptor(
            "existing-old",
            createdAt: now.addingTimeInterval(-30 * 86_400)
        )
        let missingRepository = try weeklyEnabledRepository(
            at: now.addingTimeInterval(-10 * 86_400),
            baselineAssetIDs: nil
        )
        let missingModel = AppModel(
            library: WeeklyInboxReader(descriptors: [descriptor]),
            repository: missingRepository
        )
        await missingModel.prepareWeeklyInbox()

        #expect(missingModel.weeklyInboxFlow?.plan == nil)
        #expect(missingModel.weeklyInboxFlow?.errorMessage != nil)

        let container = try weeklyModelContainer()
        let corruptRepository = SwiftDataTaskRepository(container: container)
        let summary = CleanupSummary(
            decisions: [PhotoDecision(assetID: "meaningful-corrupt", kind: .keep)],
            elapsedSeconds: nil,
            id: CleanupSummary.identifier(forTaskID: "corrupt-baseline"),
            createdAt: now.addingTimeInterval(-10 * 86_400)
        )
        var settings = WorkflowSettings.defaults
        settings.weeklyModeEnabled = true
        try corruptRepository.save(summary: summary)
        try corruptRepository.save(settings: settings)
        try corruptRepository.save(checkpoint: ScanCheckpoint(
            id: "corrupt-baseline",
            stage: .completed,
            processedAssetIDs: [descriptor.id],
            discoveredCount: 1,
            updatedAt: now.addingTimeInterval(-10 * 86_400)
        ))
        let checkpointID = "corrupt-baseline"
        let record = try #require(container.mainContext.fetch(FetchDescriptor<PersistedScanCheckpoint>(
            predicate: #Predicate { $0.identifier == checkpointID }
        )).first)
        record.payload = Data([0xFF])
        try container.mainContext.save()
        let corruptModel = AppModel(
            library: WeeklyInboxReader(descriptors: [descriptor]),
            repository: corruptRepository
        )
        await corruptModel.prepareWeeklyInbox()

        #expect(corruptModel.weeklyInboxFlow?.plan == nil)
        #expect(corruptModel.weeklyInboxFlow?.errorMessage != nil)
    }

    // Production break: corrupt task or decision rows disappear and permit unsafe duplicate generation.
    @Test("Corrupt task and decision bulk reads fail closed")
    func corruptBulkRowsFailClosed() throws {
        let taskContainer = try weeklyModelContainer()
        let taskRepository = SwiftDataTaskRepository(container: taskContainer)
        try taskRepository.save(task: CleanupTask.weeklyFixture(id: "corrupt-task", assetIDs: ["owned"]))
        let taskID = "corrupt-task"
        let taskRecord = try #require(taskContainer.mainContext.fetch(FetchDescriptor<PersistedCleanupTask>(
            predicate: #Predicate { $0.identifier == taskID }
        )).first)
        taskRecord.payload = Data([0xFF])
        try taskContainer.mainContext.save()

        #expect(throws: (any Error).self) { try taskRepository.tasks() }

        let decisionContainer = try weeklyModelContainer()
        let decisionRepository = SwiftDataTaskRepository(container: decisionContainer)
        try decisionRepository.save(decision: PhotoDecision(assetID: "corrupt-decision", kind: .protect))
        let assetID = "corrupt-decision"
        let decisionRecord = try #require(decisionContainer.mainContext.fetch(FetchDescriptor<PersistedPhotoDecision>(
            predicate: #Predicate { $0.assetID == assetID }
        )).first)
        decisionRecord.kindRawValue = "not-a-decision"
        try decisionContainer.mainContext.save()

        #expect(throws: (any Error).self) { try decisionRepository.decisions() }
    }

    // Production break: full rescan leaves the Tasks stack trapped on the stale weekly destination.
    @Test("Full rescan exits weekly mode to the Tasks root")
    func fullRescanReturnsToTasksRoot() async throws {
        let repository = try weeklyEnabledRepository(at: Date(timeIntervalSince1970: 9_000_000))
        let model = AppModel(
            library: WeeklyInboxReader(descriptors: []),
            repository: repository,
            initialActiveRoute: .weeklyInbox
        )
        #expect(model.activeRoute == .weeklyInbox)

        await model.refreshAuthorization()
        model.rescan()

        #expect(model.activeRoute == nil)
        #expect(model.taskNavigationPath.isEmpty)
    }

    // Production break: a full rescan checks only the last route and retains a weekly-origin descendant.
    @Test("Full rescan clears a weekly descendant route")
    func fullRescanClearsWeeklyDescendantRoute() async throws {
        let repository = try weeklyEnabledRepository(at: Date(timeIntervalSince1970: 9_100_000))
        let model = AppModel(
            library: WeeklyInboxReader(descriptors: []),
            repository: repository,
            initialActiveRoute: .weeklyInbox
        )
        await model.refreshAuthorization()
        let task = CleanupTask.weeklyFixture(id: "weekly-descendant", assetIDs: ["descendant"])
        model.startWeeklyInboxItem(WeeklyInboxItem(
            id: "unfinished:\(task.id)",
            source: .unfinished,
            title: task.title,
            reason: task.reason,
            assetIDs: task.assetIDs,
            estimatedMinutes: 1,
            completedUnitCount: 0,
            totalUnitCount: 1,
            task: task,
            decision: nil
        ))
        #expect(model.taskNavigationPath == [.weeklyInbox, .task(task.id)])

        model.rescan()

        #expect(model.activeRoute == nil)
        #expect(model.taskNavigationPath.isEmpty)
    }

    // Production break: the inherited batch implementation commits item one before item two fails.
    @Test("The default task batch contract fails closed without partial persistence")
    func inheritedTaskBatchContractDoesNotPersistPartially() throws {
        let storage = try SwiftDataTaskRepository(inMemory: true)
        let repository = WeeklyInheritedBatchRepository(storage: storage)

        #expect(throws: (any Error).self) {
            try repository.save(tasks: [
                CleanupTask.weeklyFixture(id: "batch-first", assetIDs: ["first"]),
                CleanupTask.weeklyFixture(id: "batch-second", assetIDs: ["second"])
            ])
        }
        #expect(try storage.tasks().isEmpty)
    }

    @Test("The repository retains the last completed scan baseline behind a newer unfinished scan")
    func completedScanBaselineIsStable() throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let completed = ScanCheckpoint(
            id: "completed",
            stage: .completed,
            processedAssetIDs: ["known"],
            discoveredCount: 1,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let active = ScanCheckpoint(
            id: "active",
            stage: .checkingAvailability,
            processedAssetIDs: ["new"],
            discoveredCount: 2,
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        try repository.save(checkpoint: completed)
        try repository.save(checkpoint: active)

        #expect(try repository.latestCompletedCheckpoint() == completed)
    }
}

private actor WeeklyInboxReader: PhotoLibraryReading {
    let descriptors: [PhotoAssetDescriptor]

    init(descriptors: [PhotoAssetDescriptor]) { self.descriptors = descriptors }
    func authorizationStatus() -> PhotoAuthorization { .authorized }
    func requestAuthorization() -> PhotoAuthorization { .authorized }
    func accessibleAssetDescriptors() -> [PhotoAssetDescriptor] { descriptors }
    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> {
        AsyncStream { $0.finish() }
    }
}

private actor ControlledWeeklyInboxReader: PhotoLibraryReading {
    private var continuations: [Int: CheckedContinuation<[PhotoAssetDescriptor], Error>] = [:]
    private var requestCount = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func authorizationStatus() -> PhotoAuthorization { .authorized }
    func requestAuthorization() -> PhotoAuthorization { .authorized }
    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> {
        AsyncStream { $0.finish() }
    }

    func accessibleAssetDescriptors() async throws -> [PhotoAssetDescriptor] {
        requestCount += 1
        let request = requestCount
        resumeWaiters()
        return try await withCheckedThrowingContinuation { continuation in
            continuations[request] = continuation
        }
    }

    func waitForRequestCount(_ count: Int) async {
        guard requestCount < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }

    func resolve(request: Int, descriptors: [PhotoAssetDescriptor]) {
        continuations.removeValue(forKey: request)?.resume(returning: descriptors)
    }

    private func resumeWaiters() {
        let ready = waiters.filter { requestCount >= $0.0 }
        waiters.removeAll { requestCount >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
}

@MainActor
private final class WeeklyFailingRepository: TaskRepository {
    let storage: SwiftDataTaskRepository
    var failReads = false
    var failSettingsWrites = false
    var failTaskWrites = false
    var failTaskWriteAtCall: Int?
    private var taskWriteCallCount = 0

    init(storage: SwiftDataTaskRepository) { self.storage = storage }

    func save(checkpoint: ScanCheckpoint) throws { try storage.save(checkpoint: checkpoint) }
    func latestCheckpoint() throws -> ScanCheckpoint? { try read { try storage.latestCheckpoint() } }
    func save(task: CleanupTask) throws {
        taskWriteCallCount += 1
        if taskWriteCallCount == failTaskWriteAtCall { throw WeeklyInboxTestFailure.forced }
        if failTaskWrites { throw WeeklyInboxTestFailure.forced }
        try storage.save(task: task)
    }
    func save(tasks: [CleanupTask]) throws {
        if failTaskWrites || failTaskWriteAtCall != nil { throw WeeklyInboxTestFailure.forced }
        try storage.save(tasks: tasks)
    }
    func tasks() throws -> [CleanupTask] { try read { try storage.tasks() } }
    func applySingleDecision(_ decision: PhotoDecision, undo: DecisionUndoEntry, task: CleanupTask?) throws { try storage.applySingleDecision(decision, undo: undo, task: task) }
    func save(decision: PhotoDecision) throws { try storage.save(decision: decision) }
    func save(decisions: [PhotoDecision]) throws { try storage.save(decisions: decisions) }
    func completeComparison(taskID: String, decisions: [PhotoDecision]) throws { try storage.completeComparison(taskID: taskID, decisions: decisions) }
    func completeArchive(transaction: MutationTransaction, decision: PhotoDecision, recentAlbumIDs: [String]) throws { try storage.completeArchive(transaction: transaction, decision: decision, recentAlbumIDs: recentAlbumIDs) }
    func removeDecision(for assetID: String) throws { try storage.removeDecision(for: assetID) }
    func removeDecisions(for assetIDs: Set<String>) throws { try storage.removeDecisions(for: assetIDs) }
    func decision(for assetID: String) throws -> PhotoDecision? { try read { try storage.decision(for: assetID) } }
    func decisions() throws -> [PhotoDecision] { try read { try storage.decisions() } }
    func save(undo: DecisionUndoEntry) throws { try storage.save(undo: undo) }
    func latestUndo() throws -> DecisionUndoEntry? { try read { try storage.latestUndo() } }
    func removeUndo(id: UUID) throws { try storage.removeUndo(id: id) }
    func save(transaction: MutationTransaction) throws { try storage.save(transaction: transaction) }
    func transactions() throws -> [MutationTransaction] { try read { try storage.transactions() } }
    func transaction(id: String) throws -> RepositoryLookup<MutationTransaction> { try read { try storage.transaction(id: id) } }
    func save(settings: WorkflowSettings) throws {
        if failSettingsWrites { throw WeeklyInboxTestFailure.forced }
        try storage.save(settings: settings)
    }
    func settings() throws -> WorkflowSettings { try read { try storage.settings() } }
    func save(summary: CleanupSummary) throws { try storage.save(summary: summary) }
    func summaries() throws -> [CleanupSummary] { try read { try storage.summaries() } }
    func summary(id: UUID) throws -> RepositoryLookup<CleanupSummary> { try read { try storage.summary(id: id) } }
    func reconcile(availableAssetIDs: Set<String>) throws { try storage.reconcile(availableAssetIDs: availableAssetIDs) }
    func clearHistory() throws { try storage.clearHistory() }

    private func read<T>(_ body: () throws -> T) throws -> T {
        if failReads { throw WeeklyInboxTestFailure.forced }
        return try body()
    }
}

@MainActor
private final class WeeklyInheritedBatchRepository: TaskRepository {
    let storage: SwiftDataTaskRepository
    private var taskWriteCount = 0

    init(storage: SwiftDataTaskRepository) { self.storage = storage }

    func save(checkpoint: ScanCheckpoint) throws { try storage.save(checkpoint: checkpoint) }
    func latestCheckpoint() throws -> ScanCheckpoint? { try storage.latestCheckpoint() }
    func save(task: CleanupTask) throws {
        taskWriteCount += 1
        if taskWriteCount == 2 { throw WeeklyInboxTestFailure.forced }
        try storage.save(task: task)
    }
    func tasks() throws -> [CleanupTask] { try storage.tasks() }
    func applySingleDecision(_ decision: PhotoDecision, undo: DecisionUndoEntry, task: CleanupTask?) throws { try storage.applySingleDecision(decision, undo: undo, task: task) }
    func save(decision: PhotoDecision) throws { try storage.save(decision: decision) }
    func save(decisions: [PhotoDecision]) throws { try storage.save(decisions: decisions) }
    func completeComparison(taskID: String, decisions: [PhotoDecision]) throws { try storage.completeComparison(taskID: taskID, decisions: decisions) }
    func completeArchive(transaction: MutationTransaction, decision: PhotoDecision, recentAlbumIDs: [String]) throws { try storage.completeArchive(transaction: transaction, decision: decision, recentAlbumIDs: recentAlbumIDs) }
    func removeDecision(for assetID: String) throws { try storage.removeDecision(for: assetID) }
    func decision(for assetID: String) throws -> PhotoDecision? { try storage.decision(for: assetID) }
    func decisions() throws -> [PhotoDecision] { try storage.decisions() }
    func save(undo: DecisionUndoEntry) throws { try storage.save(undo: undo) }
    func latestUndo() throws -> DecisionUndoEntry? { try storage.latestUndo() }
    func removeUndo(id: UUID) throws { try storage.removeUndo(id: id) }
    func save(transaction: MutationTransaction) throws { try storage.save(transaction: transaction) }
    func transactions() throws -> [MutationTransaction] { try storage.transactions() }
    func save(settings: WorkflowSettings) throws { try storage.save(settings: settings) }
    func settings() throws -> WorkflowSettings { try storage.settings() }
    func save(summary: CleanupSummary) throws { try storage.save(summary: summary) }
    func summaries() throws -> [CleanupSummary] { try storage.summaries() }
    func reconcile(availableAssetIDs: Set<String>) throws { try storage.reconcile(availableAssetIDs: availableAssetIDs) }
    func clearHistory() throws { try storage.clearHistory() }
}

private enum WeeklyInboxTestFailure: Error { case forced }

@MainActor
private func weeklyModelContainer() throws -> ModelContainer {
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(
        for: Schema(versionedSchema: PhotoBoxSchemaV1.self),
        configurations: [configuration]
    )
}

@MainActor
private func waitForWeeklyCondition(
    _ condition: @escaping @MainActor () -> Bool
) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for weekly condition")
}

@MainActor
private func weeklyEnabledRepository(
    at date: Date,
    baselineAssetIDs: [String]? = []
) throws -> SwiftDataTaskRepository {
    let repository = try SwiftDataTaskRepository(inMemory: true)
    let summary = CleanupSummary(
        decisions: [PhotoDecision(assetID: "meaningful", kind: .keep)],
        elapsedSeconds: nil,
        id: CleanupSummary.identifier(forTaskID: "weekly-enabled"),
        createdAt: date
    )
    var settings = WorkflowSettings.defaults
    settings.weeklyModeEnabled = true
    try repository.save(summary: summary)
    try repository.save(settings: settings)
    if let baselineAssetIDs {
        try repository.save(checkpoint: ScanCheckpoint(
            id: "weekly-initial-baseline",
            stage: .completed,
            processedAssetIDs: baselineAssetIDs,
            discoveredCount: baselineAssetIDs.count,
            updatedAt: date.addingTimeInterval(-60)
        ))
    }
    return repository
}

private func weeklyDescriptor(
    _ id: String,
    createdAt: Date = Date(timeIntervalSince1970: 1_000),
    isScreenshot: Bool = false,
    availability: AssetAvailability = .local,
    isFavorite: Bool = false
) -> PhotoAssetDescriptor {
    PhotoAssetDescriptor(
        id: id,
        mediaType: .photo,
        creationDate: createdAt,
        pixelWidth: 1_000,
        pixelHeight: 1_000,
        duration: 0,
        estimatedBytes: 1_000,
        isFavorite: isFavorite,
        isEdited: false,
        isScreenshot: isScreenshot,
        burstIdentifier: nil,
        availability: availability
    )
}

private extension CleanupTask {
    static func weeklyFixture(
        id: String,
        assetIDs: [String],
        estimatedMinutes: Int = 1,
        type: CleanupTaskType = .screenshots,
        confidence: Double = 1
    ) -> CleanupTask {
        CleanupTask(
            id: id,
            type: type,
            title: "整理",
            reason: "测试",
            assetIDs: assetIDs,
            estimatedBytes: Int64(assetIDs.count) * 1_000,
            estimatedMinutes: estimatedMinutes,
            risk: .low,
            confidence: confidence,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
    }
}
