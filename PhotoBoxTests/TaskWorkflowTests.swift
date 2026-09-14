import Foundation
import Testing
@testable import PhotoBox

@Suite("Task diagnosis and ranking")
struct TaskRankingTests {
    @Test("Low-risk trusted work ranks ahead of a larger high-risk task")
    func trustRanksBeforeSpace() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let lowRisk = CleanupTask.fixture(
            id: "low",
            estimatedBytes: 10_000,
            risk: .low,
            confidence: 0.85,
            createdAt: now
        )
        let highRisk = CleanupTask.fixture(
            id: "high",
            estimatedBytes: 10_000 * 1_000_000,
            risk: .high,
            confidence: 1,
            createdAt: now
        )

        let ranked = TaskRanker().rank([highRisk, lowRisk], now: now)

        #expect(ranked.map(\.id) == ["low", "high"])
    }

    @Test("Recent skip history lowers otherwise equal priority")
    func recentSkipLowersPriority() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let ready = CleanupTask.fixture(id: "ready", createdAt: now)
        let skipped = CleanupTask.fixture(
            id: "skipped",
            skipCount: 1,
            lastSkippedAt: now,
            createdAt: now
        )

        #expect(TaskRanker().rank([skipped, ready], now: now).map(\.id) == ["ready", "skipped"])
    }

    @Test("Diagnosis keeps current storage distinct from estimated reclaimable space")
    func diagnosisSummary() {
        let tasks = [
            CleanupTask.fixture(id: "one", assetIDs: ["a", "b"], estimatedBytes: 4_000),
            CleanupTask.fixture(id: "two", assetIDs: ["b", "c"], estimatedBytes: 6_000)
        ]

        let summary = DiagnosisSummary(tasks: tasks, currentPhotoStorageBytes: 500_000)

        #expect(summary.taskCount == 2)
        #expect(summary.uniqueAssetCount == 3)
        #expect(summary.currentPhotoStorageBytes == 500_000)
        #expect(summary.estimatedReclaimableBytes == 10_000)
        #expect(!summary.isHealthy)
        #expect(DiagnosisSummary(tasks: [], currentPhotoStorageBytes: 500_000).isHealthy)
    }

    @Test("Large-video diagnosis bytes are not reclaimable deletion space")
    func largeVideoBytesAreExcludedFromReclaimableSpace() {
        let tasks = [
            CleanupTask.fixture(id: "duplicates", estimatedBytes: 4_000),
            CleanupTask.fixture(id: "large-video", estimatedBytes: 90_000, type: .largeVideos)
        ]

        let summary = DiagnosisSummary(tasks: tasks, currentPhotoStorageBytes: 500_000)

        #expect(summary.estimatedReclaimableBytes == 4_000)
    }

    @Test("Diagnosis excludes completed and invalid tasks from available candidates")
    func terminalTasksAreExcludedFromDiagnosis() {
        let tasks = [
            CleanupTask.fixture(
                id: "completed",
                assetIDs: ["completed-asset"],
                estimatedBytes: 4_000,
                status: .completed
            ),
            CleanupTask.fixture(
                id: "invalid",
                assetIDs: ["invalid-asset"],
                estimatedBytes: 6_000,
                status: .invalid
            )
        ]

        let summary = DiagnosisSummary(tasks: tasks, currentPhotoStorageBytes: 500_000)

        #expect(summary.taskCount == 0)
        #expect(summary.uniqueAssetCount == 0)
        #expect(summary.estimatedReclaimableBytes == 0)
        #expect(summary.isHealthy)
    }
}

@Suite("Persistent task lifecycle")
@MainActor
struct TaskLifecycleTests {
    @Test("Overlapping in-progress tasks never own the same asset")
    func exclusiveOwnership() throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        try repository.save(task: .fixture(id: "first", assetIDs: ["a", "b"]))
        try repository.save(task: .fixture(id: "second", assetIDs: ["b", "c"]))
        let lifecycle = TaskLifecycleController(repository: repository)

        let first = try lifecycle.start(taskID: "first")
        let second = try lifecycle.start(taskID: "second")

        #expect(first.ownedAssetIDs == ["a", "b"])
        #expect(second.ownedAssetIDs == ["c"])
        #expect(Set(first.ownedAssetIDs).isDisjoint(with: second.ownedAssetIDs))
    }

    @Test("Pause releases ownership and resume restores persisted work")
    func pauseResumeAndRelaunch() throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        try repository.save(task: .fixture(id: "task", assetIDs: ["a", "b"]))
        let lifecycle = TaskLifecycleController(repository: repository)

        _ = try lifecycle.start(taskID: "task")
        let paused = try lifecycle.pause(taskID: "task")
        #expect(paused.status == .paused)
        #expect(paused.ownedAssetIDs.isEmpty)

        let relaunched = TaskLifecycleController(repository: repository)
        let resumed = try relaunched.resume(taskID: "task")
        #expect(resumed.status == .inProgress)
        #expect(resumed.ownedAssetIDs == ["a", "b"])
        #expect(try relaunched.activeTasks().map(\.id) == ["task"])
    }

    @Test("Skip records lifecycle history without creating a photo decision")
    func skipDoesNotDecide() throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        try repository.save(task: .fixture(id: "task"))
        let lifecycle = TaskLifecycleController(repository: repository)
        _ = try lifecycle.start(taskID: "task")

        let skipped = try lifecycle.skip(
            taskID: "task",
            at: Date(timeIntervalSince1970: 2_000)
        )

        #expect(skipped.status == .skipped)
        #expect(skipped.skipCount == 1)
        #expect(skipped.ownedAssetIDs.isEmpty)
        #expect(try repository.decisions().isEmpty)
    }
}

@Suite("Single decision and undo workflow")
@MainActor
struct DecisionWorkflowTests {
    @Test("A new decision replaces the prior state and updates aggregates")
    func decisionReplacement() throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let workflow = DecisionWorkflow(repository: repository)

        try workflow.apply(PhotoDecision(
            assetID: "asset",
            kind: .deleteCandidate,
            estimatedBytes: 4_000
        ))
        try workflow.apply(PhotoDecision(
            assetID: "asset",
            kind: .archive,
            estimatedBytes: 4_000,
            targetAlbumID: "album"
        ))

        #expect(try repository.decisions().count == 1)
        #expect(try repository.decision(for: "asset")?.kind == .archive)
        let summary = try workflow.currentSummary(elapsedSeconds: 5)
        #expect(summary.archivedCount == 1)
        #expect(summary.deleteCandidateCount == 0)
        #expect(summary.estimatedReclaimableBytes == 0)
    }

    @Test("Undo restores the previous decision and task position")
    func undoRestoresState() throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        try repository.save(task: .fixture(id: "task", assetIDs: ["asset", "next"]))
        let workflow = DecisionWorkflow(repository: repository)

        try workflow.apply(PhotoDecision(assetID: "asset", kind: .keep, taskID: "task"))
        #expect(try repository.tasks().first?.currentAssetIndex == 1)

        #expect(try workflow.undoLatest() == .restored)
        #expect(try repository.decision(for: "asset") == nil)
        #expect(try repository.tasks().first?.currentAssetIndex == 0)
    }

    @Test("Submitted deletion directs recovery to Recently Deleted")
    func submittedBoundary() throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let workflow = DecisionWorkflow(repository: repository)
        try workflow.apply(PhotoDecision(assetID: "asset", kind: .deleteCandidate))
        try workflow.markSubmitted(assetID: "asset")

        #expect(try workflow.undoLatest() == .requiresRecentlyDeleted)
        #expect(try repository.decision(for: "asset")?.isSubmitted == true)
    }
}

@Suite("Repository-backed app restoration")
@MainActor
struct AppModelRestorationTests {
    @Test("Reconstruction retains work and decisions while landing on home")
    func restoresWorkflow() throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        var task = CleanupTask.fixture(
            id: "task",
            assetIDs: ["done", "pending"],
            type: .screenshots
        )
        task.status = .inProgress
        task.ownedAssetIDs = ["pending"]
        task.currentAssetIndex = 1
        try repository.save(task: task)
        let decision = PhotoDecision(assetID: "done", kind: .keep, taskID: "task")
        try repository.save(decision: decision)
        var settings = WorkflowSettings.defaults
        settings.screenshotRetentionDays = 45
        try repository.save(settings: settings)

        let first = AppModel(library: RestorationReader(), repository: repository)
        let reconstructed = AppModel(library: RestorationReader(), repository: repository)

        #expect(first.cleanupTasks == [task])
        #expect(reconstructed.cleanupTasks == [task])
        #expect(reconstructed.pendingDecisions == [decision])
        #expect(reconstructed.activeRoute == nil)
        #expect(reconstructed.taskNavigationPath.isEmpty)
        #expect(reconstructed.screenshotAgeDays == 45)
    }

    @Test("Restored comparison work remains reachable explicitly from home")
    func restoresSimilarTaskToComparison() throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        var task = CleanupTask.fixture(id: "similar", type: .similar)
        task.status = .inProgress
        task.ownedAssetIDs = task.assetIDs
        try repository.save(task: task)

        let reconstructed = AppModel(library: RestorationReader(), repository: repository)

        #expect(reconstructed.activeRoute == nil)
        reconstructed.openTask(task)
        #expect(reconstructed.activeRoute == .comparison("similar"))
        #expect(reconstructed.taskNavigationPath == [.comparison("similar")])
    }

    @Test("Preparing a persisted similar task uses current descriptors without fabricating a recommendation")
    func preparesPersistedComparisonTask() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        try repository.save(task: .fixture(
            id: "similar",
            assetIDs: ["available", "missing"],
            estimatedBytes: 9_000,
            type: .similar,
            confidence: 1
        ))
        let model = AppModel(
            library: ComparisonReader(descriptors: [
                PhotoAssetDescriptor(
                    id: "available",
                    mediaType: .photo,
                    creationDate: Date(timeIntervalSince1970: 1_000),
                    pixelWidth: 1_200,
                    pixelHeight: 900,
                    duration: 0,
                    estimatedBytes: 4_000,
                    isFavorite: false,
                    isEdited: false,
                    isScreenshot: false,
                    burstIdentifier: nil,
                    availability: .local
                )
            ]),
            repository: repository
        )

        await model.prepareComparison(taskID: "similar")

        let flow = try #require(model.comparisonFlow)
        #expect(flow.currentGroup?.candidates.map(\.id) == ["available", "missing"])
        #expect(flow.currentGroup?.candidates.last?.asset.availability == .unavailable)
        #expect(flow.isLowConfidence)
        #expect(flow.selectedKeepIDs.isEmpty)
        #expect(try repository.tasks().first?.status == .inProgress)
    }

    @Test("A newer comparison route supersedes a stale descriptor load and error")
    func newerComparisonPreparationWinsOverStaleLoad() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        try repository.save(task: .fixture(id: "first", assetIDs: ["first"], type: .similar))
        try repository.save(task: .fixture(id: "second", assetIDs: ["second"], type: .bursts))
        let reader = SwitchingComparisonReader()
        let model = AppModel(library: reader, repository: repository)

        let first = Task { await model.prepareComparison(taskID: "first") }
        await reader.waitForFirstDescriptorRequest()

        let second = Task { await model.prepareComparison(taskID: "second") }
        await second.value
        await reader.failFirstDescriptorRequest()
        await first.value

        #expect(model.comparisonFlow?.currentGroup?.id == "task:second")
        #expect(model.comparisonLoadError == nil)
        #expect(!model.isLoadingComparison)
    }
}

private actor RestorationReader: PhotoLibraryReading {
    func authorizationStatus() -> PhotoAuthorization { .authorized }
    func requestAuthorization() -> PhotoAuthorization { .authorized }
    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> {
        AsyncStream { $0.finish() }
    }
}

private actor ComparisonReader: PhotoLibraryReading {
    private let descriptors: [PhotoAssetDescriptor]

    init(descriptors: [PhotoAssetDescriptor]) {
        self.descriptors = descriptors
    }

    func authorizationStatus() -> PhotoAuthorization { .authorized }
    func requestAuthorization() -> PhotoAuthorization { .authorized }
    func accessibleAssetDescriptors() throws -> [PhotoAssetDescriptor] { descriptors }
    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> {
        AsyncStream { $0.finish() }
    }
}

private actor SwitchingComparisonReader: PhotoLibraryReading {
    private var requestCount = 0
    private var firstRequestContinuation: CheckedContinuation<Void, Never>?
    private var firstRequestStartedContinuation: CheckedContinuation<Void, Never>?

    func authorizationStatus() -> PhotoAuthorization { .authorized }
    func requestAuthorization() -> PhotoAuthorization { .authorized }

    func accessibleAssetDescriptors() async throws -> [PhotoAssetDescriptor] {
        requestCount += 1
        if requestCount == 1 {
            firstRequestStartedContinuation?.resume()
            firstRequestStartedContinuation = nil
            await withCheckedContinuation { continuation in
                firstRequestContinuation = continuation
            }
            throw ReaderError.staleRequest
        }
        return [descriptor(id: "second")]
    }

    func waitForFirstDescriptorRequest() async {
        guard requestCount > 0 else {
            await withCheckedContinuation { continuation in
                firstRequestStartedContinuation = continuation
            }
            return
        }
    }

    func failFirstDescriptorRequest() {
        firstRequestContinuation?.resume()
        firstRequestContinuation = nil
    }

    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> {
        AsyncStream { $0.finish() }
    }

    private func descriptor(id: String) -> PhotoAssetDescriptor {
        PhotoAssetDescriptor(
            id: id,
            mediaType: .photo,
            creationDate: Date(timeIntervalSince1970: 1_000),
            pixelWidth: 1_200,
            pixelHeight: 900,
            duration: 0,
            estimatedBytes: 4_000,
            isFavorite: false,
            isEdited: false,
            isScreenshot: false,
            burstIdentifier: nil,
            availability: .local
        )
    }

    private enum ReaderError: Error {
        case staleRequest
    }
}

private extension CleanupTask {
    static func fixture(
        id: String,
        assetIDs: [String] = ["asset-1"],
        estimatedBytes: Int64 = 1_000,
        type: CleanupTaskType = .similar,
        risk: CleanupTaskRisk = .low,
        confidence: Double = 0.9,
        status: CleanupTaskStatus = .queued,
        skipCount: Int = 0,
        lastSkippedAt: Date? = nil,
        createdAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> CleanupTask {
        CleanupTask(
            id: id,
            type: type,
            title: id,
            reason: "测试",
            assetIDs: assetIDs,
            estimatedBytes: estimatedBytes,
            estimatedMinutes: 2,
            risk: risk,
            confidence: confidence,
            status: status,
            skipCount: skipCount,
            lastSkippedAt: lastSkippedAt,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }
}
