import Foundation
import Testing
@testable import PhotoBox

@Suite("Repository-backed decision queues")
@MainActor
struct DecisionQueueTests {
    // Production break: queue projection admits another decision kind, changes repository order, or substitutes a descriptor ID.
    @Test("Projection keeps exact decision kinds, deterministic order, and stable identifiers")
    func projectionFiltersAndOrdersExactAssets() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let task = queueTask()
        try repository.save(task: task)
        try repository.save(decisions: [
            decision("later-b", .decideLater, at: 20),
            decision("protected", .protect, at: 5),
            decision("later-a", .decideLater, at: 10),
            decision("kept", .keep, at: 1),
            decision("missing", .decideLater, at: 2),
            decision("unavailable", .protect, at: 3)
        ])
        var decisionsChangedCount = 0
        let model = DecisionQueueModel(
            repository: repository,
            library: DecisionQueueReader(descriptors: [
                descriptor("later-b"),
                descriptor("protected"),
                descriptor("kept"),
                descriptor("later-a"),
                descriptor("unavailable", availability: .unavailable)
            ]),
            onDecisionsChanged: { decisionsChangedCount += 1 }
        )
        await model.load()

        #expect(model.decideLaterItems.map(\.id) == ["later-a", "later-b"])
        #expect(model.protectedItems.map(\.id) == ["protected"])
        #expect(model.decideLaterItems.allSatisfy { $0.descriptor.id == $0.decision.assetID })
        #expect(model.protectedItems.allSatisfy { $0.descriptor.id == $0.decision.assetID })
        #expect(try repository.decision(for: "missing") == nil)
        #expect(try repository.decision(for: "unavailable") == nil)
        #expect(try repository.decision(for: "kept")?.kind == .keep)
        #expect(try repository.tasks().first == task)
        #expect(model.reconciliationMessage == "已移除 2 项无法访问的队列记录。")
        #expect(decisionsChangedCount == 1)
    }

    // Production break: equal timestamps fall back to repository iteration order instead of the stable asset identifier.
    @Test("Equal timestamps use stable identifier ordering")
    func equalTimestampsUseStableIdentifierOrdering() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        try repository.save(decisions: [
            decision("same-b", .decideLater, at: 100),
            decision("same-a", .decideLater, at: 100)
        ])
        let model = DecisionQueueModel(
            repository: repository,
            library: DecisionQueueReader(descriptors: [descriptor("same-b"), descriptor("same-a")])
        )

        await model.load()

        #expect(model.decideLaterItems.map(\.id) == ["same-a", "same-b"])
    }

    // Production break: a failed stale-decision reconciliation hides the row or partially removes persisted state.
    @Test("Failed reconciliation retains prior content and retries exact stale decisions")
    func failedReconciliationRetainsContentAndRetries() async throws {
        let storage = try SwiftDataTaskRepository(inMemory: true)
        let original = decision("later", .decideLater, at: 100)
        let kept = decision("kept", .keep, at: 90)
        try storage.save(decisions: [original, kept])
        let repository = FailingDecisionQueueRepository(storage: storage)
        let reader = SequencedDecisionQueueReader(responses: [
            .success([descriptor("later"), descriptor("kept")]),
            .success([descriptor("kept")]),
            .success([descriptor("kept")])
        ])
        let model = DecisionQueueModel(repository: repository, library: reader)
        await model.load()
        repository.failReconciliation = true

        await model.load()

        #expect(model.loadState == .failed("无法更新失效的整理记录，请重试。"))
        #expect(model.decideLaterItems.map(\.decision) == [original])
        #expect(try storage.decision(for: "later") == original)
        #expect(try storage.decision(for: "kept") == kept)

        repository.failReconciliation = false
        await model.load()
        #expect(model.loadState == .loaded)
        #expect(model.decideLaterItems.isEmpty)
        #expect(try storage.decision(for: "later") == nil)
        #expect(try storage.decision(for: "kept") == kept)
        #expect(model.reconciliationMessage == "已移除 1 项无法访问的队列记录。")
    }

    // Production break: an older overlapping load overwrites the newer complete queue result.
    @Test("Only the latest overlapping load publishes queue state")
    func latestOverlappingLoadWins() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        try repository.save(decisions: [
            decision("stale", .decideLater, at: 10),
            decision("latest", .decideLater, at: 20)
        ])
        let reader = ControlledDecisionQueueReader()
        let model = DecisionQueueModel(repository: repository, library: reader)

        let first = Task { await model.load() }
        await reader.waitForRequestCount(1)
        let second = Task { await model.load() }
        await reader.waitForRequestCount(2)
        await reader.resolve(request: 2, descriptors: [descriptor("latest")])
        await second.value
        await reader.resolve(request: 1, descriptors: [descriptor("stale")])
        await first.value

        #expect(model.loadState == .loaded)
        #expect(model.decideLaterItems.map(\.id) == ["latest"])
        #expect(try repository.decision(for: "stale") == nil)
        #expect(try repository.decision(for: "latest")?.kind == .decideLater)
    }

    // Production break: cancellation-produced partial descriptors replace the last complete queue.
    @Test("Cancelled load preserves the last complete queue")
    func cancelledLoadPreservesLastCompleteQueue() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        try repository.save(decision: decision("existing", .decideLater, at: 10))
        let reader = ControlledDecisionQueueReader()
        let model = DecisionQueueModel(repository: repository, library: reader)

        let initial = Task { await model.load() }
        await reader.waitForRequestCount(1)
        await reader.resolve(request: 1, descriptors: [descriptor("existing")])
        await initial.value
        try repository.save(decision: decision("partial", .decideLater, at: 20))

        let cancelled = Task { await model.load() }
        await reader.waitForRequestCount(2)
        cancelled.cancel()
        await reader.resolve(request: 2, descriptors: [descriptor("partial")])
        await cancelled.value

        #expect(model.loadState == .loaded)
        #expect(model.decideLaterItems.map(\.id) == ["existing"])
        #expect(try repository.decision(for: "partial")?.kind == .decideLater)
    }

    // Production break: deferring again advances the task, loses decision metadata, changes kind, or leaves the row in its old order.
    @Test("Repeated deferral refreshes order without changing task progress or delete candidates")
    func repeatedDeferralRefreshesOnlyItsDecision() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        var task = queueTask()
        task.status = .inProgress
        task.currentAssetIndex = 1
        task.ownedAssetIDs = ["later-first", "later-second"]
        try repository.save(task: task)
        try repository.save(decisions: [
            PhotoDecision(
                assetID: "later-first",
                kind: .decideLater,
                estimatedBytes: 4_000,
                taskID: task.id,
                createdAt: Date(timeIntervalSince1970: 100)
            ),
            PhotoDecision(
                assetID: "later-second",
                kind: .decideLater,
                estimatedBytes: 5_000,
                taskID: "other-task",
                createdAt: Date(timeIntervalSince1970: 150)
            ),
            decision("delete", .deleteCandidate, at: 50)
        ])
        let refreshedAt = Date(timeIntervalSince1970: 200)
        let model = DecisionQueueModel(
            repository: repository,
            library: DecisionQueueReader(descriptors: [
                descriptor("later-first"), descriptor("later-second"), descriptor("delete")
            ]),
            now: { refreshedAt }
        )
        await model.load()
        let storedTasks = try repository.tasks()
        let taskBefore = try #require(storedTasks.first)
        let deleteCountBefore = try repository.decisions().count { $0.kind == .deleteCandidate }

        model.deferAgain(assetID: "later-first")

        let storedReplacement = try repository.decision(for: "later-first")
        let replacement = try #require(storedReplacement)
        #expect(replacement.kind == .decideLater)
        #expect(replacement.taskID == task.id)
        #expect(replacement.estimatedBytes == 4_000)
        #expect(replacement.createdAt == refreshedAt)
        #expect(model.decideLaterItems.map(\.id) == ["later-second", "later-first"])
        #expect(try repository.tasks().first == taskBefore)
        #expect(try repository.decisions().count { $0.kind == .deleteCandidate } == deleteCountBefore)
    }

    // Production break: an equal or earlier clock leaves repeated deferral at its old timestamp/order.
    @Test("Repeated deferral advances beyond stored ordering when the clock does not")
    func repeatedDeferralAlwaysAdvancesTimestampAndOrder() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        try repository.save(decisions: [
            decision("later-a", .decideLater, at: 200),
            decision("later-b", .decideLater, at: 250)
        ])
        let model = DecisionQueueModel(
            repository: repository,
            library: DecisionQueueReader(descriptors: [descriptor("later-a"), descriptor("later-b")]),
            now: { Date(timeIntervalSince1970: 100) }
        )
        await model.load()

        model.deferAgain(assetID: "later-a")

        let storedReplacement = try repository.decision(for: "later-a")
        let replacement = try #require(storedReplacement)
        #expect(replacement.createdAt > Date(timeIntervalSince1970: 250))
        #expect(model.decideLaterItems.map(\.id) == ["later-b", "later-a"])
    }

    // Production break: unprotect removes another record, mutates task progress, or converts protection into a delete candidate.
    @Test("Unprotect removes only the exact protection decision")
    func unprotectRemovesOnlyExactDecision() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let task = queueTask()
        try repository.save(task: task)
        try repository.save(decisions: [
            PhotoDecision(assetID: "protected", kind: .protect, estimatedBytes: 7_000, taskID: task.id),
            decision("other-protected", .protect, at: 20),
            decision("delete", .deleteCandidate, at: 30)
        ])
        let model = DecisionQueueModel(
            repository: repository,
            library: DecisionQueueReader(descriptors: [
                descriptor("protected"), descriptor("other-protected"), descriptor("delete")
            ])
        )
        await model.load()
        let storedTasks = try repository.tasks()
        let taskBefore = try #require(storedTasks.first)

        model.unprotect(assetID: "protected")

        #expect(try repository.decision(for: "protected") == nil)
        #expect(try repository.decision(for: "other-protected")?.kind == .protect)
        #expect(try repository.decision(for: "delete")?.kind == .deleteCandidate)
        #expect(model.protectedItems.map(\.id) == ["other-protected"])
        #expect(try repository.tasks().first == taskBefore)
    }

    // Production break: a failed repeated-deferral save optimistically reorders the row or replaces its persisted timestamp.
    @Test("Repeated-deferral failure preserves state and can retry")
    func repeatedDeferralFailurePreservesStateAndRetries() async throws {
        let storage = try SwiftDataTaskRepository(inMemory: true)
        var task = queueTask()
        task.status = .inProgress
        task.currentAssetIndex = 1
        try storage.save(task: task)
        let original = PhotoDecision(
            assetID: "later",
            kind: .decideLater,
            estimatedBytes: 4_000,
            taskID: task.id,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let other = decision("later-other", .decideLater, at: 150)
        try storage.save(decisions: [
            original,
            other,
            decision("delete", .deleteCandidate, at: 50)
        ])
        let repository = FailingDecisionQueueRepository(storage: storage)
        let model = DecisionQueueModel(
            repository: repository,
            library: DecisionQueueReader(descriptors: [
                descriptor("later"), descriptor("later-other"), descriptor("delete")
            ]),
            now: { Date(timeIntervalSince1970: 100) }
        )
        await model.load()
        let taskBefore = try #require(storage.tasks().first)
        let deleteCountBefore = try storage.decisions().count { $0.kind == .deleteCandidate }
        repository.failSave = true

        model.deferAgain(assetID: "later")

        #expect(model.decideLaterItems.map(\.decision) == [original, other])
        #expect(try storage.decision(for: "later") == original)
        #expect(model.errorMessage == "无法保存决定，请重试。")
        #expect(model.canRetry)

        repository.failSave = false
        model.retryLastAction()
        let storedReplacement = try storage.decision(for: "later")
        let replacement = try #require(storedReplacement)
        #expect(replacement.assetID == original.assetID)
        #expect(replacement.kind == .decideLater)
        #expect(replacement.taskID == task.id)
        #expect(replacement.estimatedBytes == 4_000)
        #expect(replacement.createdAt > Date(timeIntervalSince1970: 150))
        #expect(model.decideLaterItems.map(\.id) == ["later-other", "later"])
        #expect(try storage.tasks().first == taskBefore)
        #expect(try storage.decisions().count { $0.kind == .deleteCandidate } == deleteCountBefore)
        #expect(model.errorMessage == nil)
    }

    // Production break: a failed unprotect optimistically removes the row or its persisted protection decision.
    @Test("Unprotect failure preserves state and can retry")
    func unprotectFailurePreservesStateAndRetries() async throws {
        let storage = try SwiftDataTaskRepository(inMemory: true)
        let task = queueTask()
        try storage.save(task: task)
        let original = PhotoDecision(
            assetID: "protected",
            kind: .protect,
            estimatedBytes: 7_000,
            taskID: task.id,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let other = decision("other-protected", .protect, at: 200)
        try storage.save(decisions: [original, other, decision("delete", .deleteCandidate, at: 50)])
        let repository = FailingDecisionQueueRepository(storage: storage)
        let model = DecisionQueueModel(
            repository: repository,
            library: DecisionQueueReader(descriptors: [
                descriptor("protected"), descriptor("other-protected"), descriptor("delete")
            ])
        )
        await model.load()
        let taskBefore = try #require(storage.tasks().first)
        let deleteCountBefore = try storage.decisions().count { $0.kind == .deleteCandidate }
        repository.failRemove = true

        model.unprotect(assetID: "protected")

        #expect(model.protectedItems.map(\.decision) == [original, other])
        #expect(try storage.decision(for: "protected") == original)
        #expect(model.errorMessage == "无法取消保护，请重试。")
        #expect(model.canRetry)

        repository.failRemove = false
        model.retryLastAction()
        #expect(try storage.decision(for: "protected") == nil)
        #expect(try storage.decision(for: "other-protected") == other)
        #expect(model.protectedItems.map(\.decision) == [other])
        #expect(try storage.tasks().first == taskBefore)
        #expect(try storage.decisions().count { $0.kind == .deleteCandidate } == deleteCountBefore)
        #expect(model.errorMessage == nil)
    }

    // Production break: AppModel reconstruction loses queue metadata/counts or manufactures a delete candidate during restoration.
    @Test("AppModel reconstruction restores queue membership without delete candidates")
    func appModelReconstructionRestoresQueues() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let decisions = [
            PhotoDecision(
                assetID: "later",
                kind: .decideLater,
                estimatedBytes: 11_000,
                taskID: "task-later",
                createdAt: Date(timeIntervalSince1970: 100)
            ),
            PhotoDecision(
                assetID: "protected",
                kind: .protect,
                estimatedBytes: 12_000,
                taskID: "task-protected",
                createdAt: Date(timeIntervalSince1970: 200)
            )
        ]
        try repository.save(decisions: decisions)
        let reader = DecisionQueueReader(descriptors: [
            descriptor("later", isEdited: true),
            descriptor("protected", isFavorite: true)
        ])
        let first = AppModel(library: reader, repository: repository)
        await first.decisionQueues?.load()

        let reconstructed = AppModel(library: reader, repository: repository)
        await reconstructed.decisionQueues?.load()

        let firstQueues = try #require(first.decisionQueues)
        let restoredQueues = try #require(reconstructed.decisionQueues)
        #expect(restoredQueues.decideLaterItems == firstQueues.decideLaterItems)
        #expect(restoredQueues.protectedItems == firstQueues.protectedItems)
        #expect(restoredQueues.decideLaterCount == 1)
        #expect(restoredQueues.protectedCount == 1)
        #expect(restoredQueues.decideLaterItems.first?.decision.taskID == "task-later")
        #expect(restoredQueues.decideLaterItems.first?.decision.estimatedBytes == 11_000)
        #expect(restoredQueues.decideLaterItems.first?.descriptor.id == "later")
        #expect(try repository.decisions().count { $0.kind == .deleteCandidate } == 0)
    }

    private func decision(_ assetID: String, _ kind: PhotoDecisionKind, at timestamp: TimeInterval) -> PhotoDecision {
        PhotoDecision(
            assetID: assetID,
            kind: kind,
            estimatedBytes: 1_000,
            taskID: "task-\(assetID)",
            createdAt: Date(timeIntervalSince1970: timestamp)
        )
    }

    private func descriptor(
        _ id: String,
        availability: AssetAvailability = .local,
        isFavorite: Bool = false,
        isEdited: Bool = false
    ) -> PhotoAssetDescriptor {
        PhotoAssetDescriptor(
            id: id,
            mediaType: .photo,
            creationDate: Date(timeIntervalSince1970: 1_000),
            pixelWidth: 1_200,
            pixelHeight: 900,
            duration: 0,
            estimatedBytes: 1_000,
            isFavorite: isFavorite,
            isEdited: isEdited,
            isScreenshot: false,
            burstIdentifier: nil,
            availability: availability
        )
    }

    private func queueTask() -> CleanupTask {
        CleanupTask(
            id: "queue-task",
            type: .screenshots,
            title: "队列任务",
            reason: "测试队列状态",
            assetIDs: ["protected", "later-first", "later-second"],
            estimatedBytes: 16_000,
            estimatedMinutes: 1,
            risk: .low,
            confidence: 1,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )
    }
}

private actor DecisionQueueReader: PhotoLibraryReading {
    let descriptors: [PhotoAssetDescriptor]

    init(descriptors: [PhotoAssetDescriptor]) {
        self.descriptors = descriptors
    }

    func authorizationStatus() -> PhotoAuthorization { .authorized }
    func requestAuthorization() -> PhotoAuthorization { .authorized }
    func accessibleAssetDescriptors() -> [PhotoAssetDescriptor] { descriptors }
    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> {
        AsyncStream { $0.finish() }
    }
}

private actor SequencedDecisionQueueReader: PhotoLibraryReading {
    private var responses: [Result<[PhotoAssetDescriptor], DecisionQueueTestFailure>]

    init(responses: [Result<[PhotoAssetDescriptor], DecisionQueueTestFailure>]) {
        self.responses = responses
    }

    func authorizationStatus() -> PhotoAuthorization { .authorized }
    func requestAuthorization() -> PhotoAuthorization { .authorized }
    func accessibleAssetDescriptors() throws -> [PhotoAssetDescriptor] {
        guard !responses.isEmpty else { return [] }
        return try responses.removeFirst().get()
    }
    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> {
        AsyncStream { $0.finish() }
    }
}

private actor ControlledDecisionQueueReader: PhotoLibraryReading {
    private var requestCount = 0
    private var continuations: [Int: CheckedContinuation<[PhotoAssetDescriptor], Never>] = [:]

    func authorizationStatus() -> PhotoAuthorization { .authorized }
    func requestAuthorization() -> PhotoAuthorization { .authorized }
    func accessibleAssetDescriptors() async -> [PhotoAssetDescriptor] {
        requestCount += 1
        let request = requestCount
        return await withCheckedContinuation { continuation in
            continuations[request] = continuation
        }
    }
    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> {
        AsyncStream { $0.finish() }
    }

    func waitForRequestCount(_ expected: Int) async {
        while requestCount < expected { await Task.yield() }
    }

    func resolve(request: Int, descriptors: [PhotoAssetDescriptor]) {
        continuations.removeValue(forKey: request)?.resume(returning: descriptors)
    }
}

@MainActor
private final class FailingDecisionQueueRepository: DecisionQueuePersisting {
    let storage: SwiftDataTaskRepository
    var failSave = false
    var failRemove = false
    var failReconciliation = false

    init(storage: SwiftDataTaskRepository) {
        self.storage = storage
    }

    func save(decision: PhotoDecision) throws {
        if failSave { throw DecisionQueueTestFailure.forced }
        try storage.save(decision: decision)
    }

    func removeDecision(for assetID: String) throws {
        if failRemove { throw DecisionQueueTestFailure.forced }
        try storage.removeDecision(for: assetID)
    }

    func removeDecisions(for assetIDs: Set<String>) throws {
        if failReconciliation { throw DecisionQueueTestFailure.forced }
        for assetID in assetIDs.sorted() {
            try storage.removeDecision(for: assetID)
        }
    }

    func decision(for assetID: String) throws -> PhotoDecision? {
        try storage.decision(for: assetID)
    }

    func decisions() throws -> [PhotoDecision] {
        try storage.decisions()
    }
}

private enum DecisionQueueTestFailure: Error {
    case forced
}
