import Foundation
import Testing
@testable import PhotoBox

@Suite("Album archive flow")
@MainActor
struct AlbumArchiveFlowTests {
    // Production break: stale recent identifiers appear as selectable rows or valid recents lose their configured order.
    @Test("Accessible recent albums lead the list and missing recents are pruned from presentation")
    func recentAlbumsLeadAndMissingRecentsArePruned() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        var settings = WorkflowSettings.defaults
        settings.recentAlbumIDs = ["missing", "recent-two", "recent-one"]
        try repository.save(settings: settings)
        let mutator = SimulatedPhotoLibraryMutator(
            assetIDs: ["asset"],
            albums: [
                album(id: "system", title: "系统"),
                album(id: "recent-one", title: "最近一"),
                album(id: "recent-two", title: "最近二")
            ]
        )
        let flow = AlbumSelectionFlow(
            assetID: "asset",
            taskID: nil,
            estimatedBytes: 10,
            repository: repository,
            mutator: mutator
        )

        await flow.loadAlbums()

        #expect(flow.recentAlbums.map(\.id) == ["recent-two", "recent-one"])
        #expect(flow.systemAlbums.map(\.id) == ["system"])
        #expect(try repository.settings().recentAlbumIDs == ["missing", "recent-two", "recent-one"])
    }

    // Production break: archive success is recorded before PhotoKit succeeds, advances twice, or persists the wrong target/recent order.
    @Test("Existing-album success atomically records the submitted archive and advances exactly once")
    func existingAlbumSuccessRecordsAndAdvancesOnce() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let task = makeTask(assetIDs: ["asset", "next"])
        try repository.save(task: task)
        _ = try TaskLifecycleController(repository: repository).start(taskID: task.id)
        try repository.save(decision: PhotoDecision(
            assetID: "asset",
            kind: .deleteCandidate,
            estimatedBytes: 9_000,
            taskID: task.id
        ))
        var settings = WorkflowSettings.defaults
        settings.recentAlbumIDs = ["one", "two", "target", "three", "four", "five", "six"]
        try repository.save(settings: settings)
        let mutator = SimulatedPhotoLibraryMutator(
            assetIDs: ["asset", "next"],
            albums: [
                album(id: "target", title: "目标"),
                album(id: "one", title: "一"), album(id: "two", title: "二"),
                album(id: "three", title: "三"), album(id: "four", title: "四"),
                album(id: "five", title: "五"), album(id: "six", title: "六")
            ]
        )
        var completionCount = 0
        let flow = AlbumSelectionFlow(
            assetID: "asset",
            taskID: task.id,
            estimatedBytes: 9_000,
            repository: repository,
            mutator: mutator,
            onArchiveSucceeded: { _ in completionCount += 1 }
        )
        await flow.loadAlbums()

        await flow.selectAlbum(id: "target")
        await flow.selectAlbum(id: "target")

        let storedDecision = try repository.decision(for: "asset")
        let decision = try #require(storedDecision)
        #expect(decision.assetID == "asset")
        #expect(decision.kind == .archive)
        #expect(decision.targetAlbumID == "target")
        #expect(decision.taskID == task.id)
        #expect(decision.estimatedBytes == 9_000)
        #expect(decision.isSubmitted)
        let updatedTask = try #require(repository.tasks().first)
        #expect(updatedTask.currentAssetIndex == 1)
        #expect(updatedTask.ownedAssetIDs == ["next"])
        #expect(updatedTask.status == .inProgress)
        let transactions = try repository.transactions()
        #expect(transactions.count == 1)
        #expect(transactions.first?.operation == .archive)
        #expect(transactions.first?.targetAlbumID == "target")
        #expect(transactions.first?.items == [MutationItem(assetID: "asset", state: .succeeded)])
        #expect(try repository.settings().recentAlbumIDs == ["target", "one", "two", "three", "four"])
        #expect(completionCount == 1)
    }

    // Production break: a valid new-album name is archived with surrounding whitespace or the created target is not made recent.
    @Test("New-album creation trims the name, archives into it, and makes it recent")
    func createsTrimmedAlbumAndArchives() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let task = makeTask(assetIDs: ["asset"])
        try repository.save(task: task)
        _ = try TaskLifecycleController(repository: repository).start(taskID: task.id)
        let mutator = SimulatedPhotoLibraryMutator(assetIDs: ["asset"])
        let flow = AlbumSelectionFlow(
            assetID: "asset",
            taskID: task.id,
            estimatedBytes: 7_000,
            repository: repository,
            mutator: mutator
        )
        await flow.loadAlbums()

        await flow.createAndArchive(named: "  夏日旅行 \n")

        let created = try #require(await mutator.listAlbums().first)
        #expect(created.title == "夏日旅行")
        #expect(try repository.decision(for: "asset")?.targetAlbumID == created.id)
        #expect(try repository.settings().recentAlbumIDs == [created.id])
        #expect(await mutator.createAlbumRequests == ["夏日旅行"])
    }

    // Production break: an empty new-album name reaches the mutator or creates a mutation journal entry.
    @Test("Whitespace-only album names are rejected before any mutation call")
    func emptyAlbumNameMakesNoMutationCall() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let mutator = SimulatedPhotoLibraryMutator(assetIDs: ["asset"])
        let flow = AlbumSelectionFlow(
            assetID: "asset",
            taskID: nil,
            estimatedBytes: 0,
            repository: repository,
            mutator: mutator
        )

        await flow.createAndArchive(named: " \n\t ")

        #expect(await mutator.createAlbumRequests.isEmpty)
        #expect(await mutator.submittedAssetIDs.isEmpty)
        #expect(try repository.transactions().isEmpty)
        #expect(flow.errorGuidance == "请输入相册名称。")
    }

    // Production break: a vanished target overwrites the prior decision, releases task ownership, or silently retries it.
    @Test("Missing target preserves the prior decision and current asset while refreshing for reselection")
    func missingTargetPreservesStateAndRequestsReselection() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let task = makeTask(assetIDs: ["asset", "next"])
        try repository.save(task: task)
        _ = try TaskLifecycleController(repository: repository).start(taskID: task.id)
        let prior = PhotoDecision(assetID: "asset", kind: .keep, estimatedBytes: 7_000, taskID: task.id)
        try repository.save(decision: prior)
        let taskBefore = try #require(repository.tasks().first)
        let mutator = SimulatedPhotoLibraryMutator(
            assetIDs: ["asset", "next"],
            albums: [album(id: "missing-target", title: "即将消失"), album(id: "valid", title: "可用")],
            albumIDsMissingOnArchive: ["missing-target"]
        )
        var completionCount = 0
        let flow = AlbumSelectionFlow(
            assetID: "asset",
            taskID: task.id,
            estimatedBytes: 7_000,
            repository: repository,
            mutator: mutator,
            onArchiveSucceeded: { _ in completionCount += 1 }
        )
        await flow.loadAlbums()

        await flow.selectAlbum(id: "missing-target")

        #expect(try repository.decision(for: "asset") == prior)
        #expect(try repository.tasks().first == taskBefore)
        #expect(flow.assetID == "asset")
        #expect(flow.requiresReselection)
        #expect(flow.errorGuidance == "所选相册已不可用，请重新选择其他相册。")
        #expect(flow.systemAlbums.map(\.id) == ["valid"])
        #expect(try repository.transactions().first?.items == [MutationItem(assetID: "asset", state: .failed)])
        #expect(await mutator.submittedAssetIDs == ["asset"])
        #expect(completionCount == 0)
    }

    // Production break: failed, stale, or cancelled archive outcomes are mistaken for success and advance the task.
    @Test("Every non-success archive result preserves decisions and task position")
    func nonSuccessResultsNeverRecordOrAdvance() async throws {
        let outcomes: [(String, MutationItemState)] = [
            ("failed", .failed),
            ("stale", .stale),
            ("cancelled", .cancelled)
        ]

        for (name, outcome) in outcomes {
            let repository = try SwiftDataTaskRepository(inMemory: true)
            let task = makeTask(id: "task-\(name)", assetIDs: ["asset-\(name)", "next-\(name)"])
            try repository.save(task: task)
            let active = try TaskLifecycleController(repository: repository).start(taskID: task.id)
            let mutator = SimulatedPhotoLibraryMutator(
                assetIDs: Set(task.assetIDs),
                albums: [album(id: "target", title: "目标")],
                configuredOutcomes: ["asset-\(name)": outcome]
            )
            var completionCount = 0
            let flow = AlbumSelectionFlow(
                assetID: "asset-\(name)",
                taskID: task.id,
                estimatedBytes: 1_000,
                repository: repository,
                mutator: mutator,
                onArchiveSucceeded: { _ in completionCount += 1 }
            )
            await flow.loadAlbums()

            await flow.selectAlbum(id: "target")

            #expect(try repository.decision(for: "asset-\(name)") == nil)
            #expect(try repository.tasks().first == active)
            #expect(try repository.transactions().first?.items == [
                MutationItem(assetID: "asset-\(name)", state: outcome)
            ])
            #expect(completionCount == 0)
        }
    }

    // Production break: AppModel archives a different route asset or returns without advancing the originating decision flow.
    @Test("AppModel returns the exact archive route to the originating task's next asset")
    func appModelReturnsToNextAssetAfterArchive() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let task = makeTask(assetIDs: ["asset", "next"])
        try repository.save(task: task)
        let mutator = SimulatedPhotoLibraryMutator(
            assetIDs: ["asset", "next"],
            albums: [album(id: "target", title: "目标")]
        )
        let model = AppModel(
            library: AlbumArchiveReader(assetIDs: ["asset", "next"]),
            repository: repository,
            mutator: mutator,
            initialScan: .idle,
            initialActiveRoute: .task(task.id)
        )
        await model.prepareSingleDecision(taskID: task.id)
        let decisionFlow = try #require(model.singleDecisionFlow(for: task.id))

        decisionFlow.requestArchive()
        #expect(model.taskNavigationPath == [.task(task.id), .albumSelection("asset")])
        await model.prepareAlbumSelection(assetID: "asset")
        let albumFlow = try #require(model.albumSelectionFlow(for: "asset"))
        await albumFlow.selectAlbum(id: "target")

        #expect(model.taskNavigationPath == [.task(task.id)])
        #expect(decisionFlow.currentDescriptor?.id == "next")
        #expect(try repository.tasks().first?.currentAssetIndex == 1)
        #expect(try repository.decisions().count == 1)
    }

    // Production break: a cached album flow keeps submitting through the prior live backend after Debug opt-out.
    @Test("Debug opt-out revokes the mutator held by an already presented album flow")
    func debugOptOutRevokesCachedFlowMutator() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        var settings = WorkflowSettings.defaults
        settings.debugRealMutationEnabled = true
        try repository.save(settings: settings)
        let liveMutator = RecordingArchiveMutator()
        let model = AppModel(
            library: AlbumArchiveReader(assetIDs: ["asset"]),
            repository: repository,
            mutator: liveMutator,
            initialScan: .idle
        )
        await model.prepareAlbumSelection(assetID: "asset")
        let cachedFlow = try #require(model.albumSelectionFlow(for: "asset"))

        model.updateDebugRealMutation(false)
        await cachedFlow.selectAlbum(id: "target")

        #expect(await liveMutator.addRequests.isEmpty)
        #expect(try repository.transactions().first?.items == [
            MutationItem(assetID: "asset", state: .stale)
        ])
        #expect(try !repository.settings().debugRealMutationEnabled)
    }

    // Production break: archive completion writes a pre-await settings snapshot and restores a concurrent Debug opt-out.
    @Test("In-flight archive completion preserves a concurrent Debug opt-out")
    func inFlightArchivePreservesDebugOptOut() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        var settings = WorkflowSettings.defaults
        settings.debugRealMutationEnabled = true
        try repository.save(settings: settings)
        let mutator = SuspendedArchiveMutator()
        let model = AppModel(
            library: AlbumArchiveReader(assetIDs: ["asset"]),
            repository: repository,
            mutator: mutator,
            initialScan: .idle
        )
        await model.prepareAlbumSelection(assetID: "asset")
        let flow = try #require(model.albumSelectionFlow(for: "asset"))

        let archive = Task { await flow.selectAlbum(id: "target") }
        await mutator.waitForSubmission()
        model.updateDebugRealMutation(false)
        await mutator.finishSubmission()
        await archive.value

        #expect(try !repository.settings().debugRealMutationEnabled)
        #expect(try repository.settings().recentAlbumIDs == ["target"])
    }

    // Production break: a failed settings save leaves the visible Debug opt-out enabled while the cached flow still holds the live mutator.
    @Test("Failed Debug opt-out persistence keeps the visible setting and mutator aligned")
    func failedDebugOptOutPersistenceKeepsLiveModeVisible() async throws {
        let storage = try SwiftDataTaskRepository(inMemory: true)
        var settings = WorkflowSettings.defaults
        settings.debugRealMutationEnabled = true
        try storage.save(settings: settings)
        let repository = SettingsSaveFailingRepository(storage: storage)
        let liveMutator = RecordingArchiveMutator()
        let model = AppModel(
            library: AlbumArchiveReader(assetIDs: ["asset"]),
            repository: repository,
            mutator: liveMutator,
            initialScan: .idle
        )
        await model.prepareAlbumSelection(assetID: "asset")
        let cachedFlow = try #require(model.albumSelectionFlow(for: "asset"))

        model.updateDebugRealMutation(false)

        #expect(model.debugRealMutationEnabled)
        #expect(try storage.settings().debugRealMutationEnabled)
        #expect(model.persistenceErrorMessage != nil)

        await cachedFlow.selectAlbum(id: "target")
        #expect(await liveMutator.addRequests == [["asset"]])
    }

    // Production break: a mutator-level album creation failure is hidden behind the still-presented creation sheet.
    @Test("Album creation failure exposes sheet guidance without archiving")
    func albumCreationFailureExposesGuidance() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let mutator = SimulatedPhotoLibraryMutator(
            assetIDs: ["asset"],
            albumCreationFails: true
        )
        let flow = AlbumSelectionFlow(
            assetID: "asset",
            taskID: nil,
            estimatedBytes: 0,
            repository: repository,
            mutator: mutator
        )

        await flow.createAndArchive(named: "旅行")

        #expect(flow.errorGuidance == "无法创建相册，请稍后重试。")
        #expect(!flow.requiresReselection)
        #expect(await mutator.submittedAssetIDs.isEmpty)
    }

    private func album(id: String, title: String) -> PhotoAlbumDescriptor {
        PhotoAlbumDescriptor(id: id, title: title, assetCount: 0)
    }

    private func makeTask(id: String = "archive-task", assetIDs: [String]) -> CleanupTask {
        CleanupTask(
            id: id,
            type: .screenshots,
            title: "归档测试",
            reason: "测试归档",
            assetIDs: assetIDs,
            estimatedBytes: 10_000,
            estimatedMinutes: 1,
            risk: .low,
            confidence: 1,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
    }
}

private actor RecordingArchiveMutator: PhotoLibraryMutating {
    let backendMode = MutationBackendMode.live
    private(set) var addRequests: [[String]] = []

    func availableAssetIDs(for requestedIDs: [String]) -> Set<String> { Set(requestedIDs) }
    func listAlbums() -> [PhotoAlbumDescriptor] {
        [PhotoAlbumDescriptor(id: "target", title: "目标", assetCount: 0)]
    }
    func createAlbum(named title: String) -> PhotoAlbumDescriptor? { nil }
    func archivedAssetIDs(for requestedIDs: [String], inAlbumID albumID: String) -> Set<String> { [] }
    func addAssets(withIDs assetIDs: [String], toAlbumID albumID: String) -> PhotoMutationBatch {
        addRequests.append(assetIDs)
        return PhotoMutationBatch(
            operation: .archive,
            items: assetIDs.map { MutationItem(assetID: $0, state: .succeeded) },
            targetAlbumID: albumID
        )
    }
    func deleteAssets(withIDs assetIDs: [String]) -> PhotoMutationBatch {
        PhotoMutationBatch(operation: .delete, items: [], targetAlbumID: nil)
    }
}

private actor SuspendedArchiveMutator: PhotoLibraryMutating {
    let backendMode = MutationBackendMode.live
    private var didSubmit = false
    private var submissionWaiter: CheckedContinuation<Void, Never>?
    private var submissionFinisher: CheckedContinuation<Void, Never>?

    func availableAssetIDs(for requestedIDs: [String]) -> Set<String> { Set(requestedIDs) }
    func listAlbums() -> [PhotoAlbumDescriptor] {
        [PhotoAlbumDescriptor(id: "target", title: "目标", assetCount: 0)]
    }
    func createAlbum(named title: String) -> PhotoAlbumDescriptor? { nil }
    func archivedAssetIDs(for requestedIDs: [String], inAlbumID albumID: String) -> Set<String> {
        Set(requestedIDs)
    }
    func addAssets(withIDs assetIDs: [String], toAlbumID albumID: String) async -> PhotoMutationBatch {
        didSubmit = true
        submissionWaiter?.resume()
        submissionWaiter = nil
        await withCheckedContinuation { submissionFinisher = $0 }
        return PhotoMutationBatch(
            operation: .archive,
            items: assetIDs.map { MutationItem(assetID: $0, state: .succeeded) },
            targetAlbumID: albumID
        )
    }
    func deleteAssets(withIDs assetIDs: [String]) -> PhotoMutationBatch {
        PhotoMutationBatch(operation: .delete, items: [], targetAlbumID: nil)
    }

    func waitForSubmission() async {
        guard !didSubmit else { return }
        await withCheckedContinuation { submissionWaiter = $0 }
    }

    func finishSubmission() {
        submissionFinisher?.resume()
        submissionFinisher = nil
    }
}

private actor AlbumArchiveReader: PhotoLibraryReading {
    let assetIDs: [String]

    init(assetIDs: [String]) {
        self.assetIDs = assetIDs
    }

    func authorizationStatus() -> PhotoAuthorization { .authorized }
    func requestAuthorization() -> PhotoAuthorization { .authorized }
    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> {
        AsyncStream { $0.finish() }
    }
    func accessibleAssetDescriptors() -> [PhotoAssetDescriptor] {
        assetIDs.map {
            PhotoAssetDescriptor(
                id: $0,
                mediaType: .photo,
                creationDate: nil,
                pixelWidth: 1_200,
                pixelHeight: 900,
                duration: 0,
                estimatedBytes: 1_000,
                isFavorite: false,
                isEdited: false,
                isScreenshot: true,
                burstIdentifier: nil,
                availability: .local
            )
        }
    }
}

@MainActor
private final class SettingsSaveFailingRepository: TaskRepository {
    private let storage: SwiftDataTaskRepository

    init(storage: SwiftDataTaskRepository) {
        self.storage = storage
    }

    func save(checkpoint: ScanCheckpoint) throws { try storage.save(checkpoint: checkpoint) }
    func latestCheckpoint() throws -> ScanCheckpoint? { try storage.latestCheckpoint() }
    func save(task: CleanupTask) throws { try storage.save(task: task) }
    func tasks() throws -> [CleanupTask] { try storage.tasks() }
    func save(decision: PhotoDecision) throws { try storage.save(decision: decision) }
    func applySingleDecision(
        _ decision: PhotoDecision,
        undo: DecisionUndoEntry,
        task: CleanupTask?
    ) throws {
        try storage.applySingleDecision(decision, undo: undo, task: task)
    }
    func save(decisions: [PhotoDecision]) throws { try storage.save(decisions: decisions) }
    func completeComparison(taskID: String, decisions: [PhotoDecision]) throws {
        try storage.completeComparison(taskID: taskID, decisions: decisions)
    }
    func completeArchive(
        transaction: MutationTransaction,
        decision: PhotoDecision,
        recentAlbumIDs: [String]
    ) throws {
        try storage.completeArchive(
            transaction: transaction,
            decision: decision,
            recentAlbumIDs: recentAlbumIDs
        )
    }
    func removeDecision(for assetID: String) throws { try storage.removeDecision(for: assetID) }
    func decision(for assetID: String) throws -> PhotoDecision? { try storage.decision(for: assetID) }
    func decisions() throws -> [PhotoDecision] { try storage.decisions() }
    func save(undo: DecisionUndoEntry) throws { try storage.save(undo: undo) }
    func latestUndo() throws -> DecisionUndoEntry? { try storage.latestUndo() }
    func removeUndo(id: UUID) throws { try storage.removeUndo(id: id) }
    func save(transaction: MutationTransaction) throws { try storage.save(transaction: transaction) }
    func transactions() throws -> [MutationTransaction] { try storage.transactions() }
    func save(settings: WorkflowSettings) throws { throw SettingsSaveFailure.forced }
    func settings() throws -> WorkflowSettings { try storage.settings() }
    func save(summary: CleanupSummary) throws { try storage.save(summary: summary) }
    func summaries() throws -> [CleanupSummary] { try storage.summaries() }
    func reconcile(availableAssetIDs: Set<String>) throws {
        try storage.reconcile(availableAssetIDs: availableAssetIDs)
    }
    func clearHistory() throws { try storage.clearHistory() }
}

private enum SettingsSaveFailure: Error {
    case forced
}
