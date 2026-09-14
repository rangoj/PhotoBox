import Foundation
import Testing
@testable import PhotoBox

@Suite("Resumable scan coordination")
struct ScanCoordinatorTests {
    @Test("Completed scans expose descriptors for task materialization")
    func completedScanDescriptorsAreReusable() async throws {
        let reader = DescriptorFixtureReader(descriptors: [.fixture(id: "asset-1")])
        let coordinator = ScanCoordinator(reader: reader) { _ in }

        let stream = await coordinator.start(
            screenshotAgeDays: 30,
            mode: .restart,
            checkpoint: nil
        )
        _ = await collect(stream)

        let descriptors = await coordinator.takeCompletedDescriptors()
        #expect(descriptors?.map(\.id) == ["asset-1"])
        #expect(await coordinator.takeCompletedDescriptors() == nil)
    }

    @Test("A scan exposes a usable descriptor snapshot before completion")
    func partialScanDescriptorsAreAvailableBeforeCompletion() async throws {
        let reader = ControlledDescriptorReader()
        let coordinator = ScanCoordinator(reader: reader) { _ in }

        let stream = await coordinator.start(
            screenshotAgeDays: 30,
            mode: .restart,
            checkpoint: nil
        )
        let collector = Task { await collect(stream) }
        await reader.waitForRequestCount(1)
        await reader.resolve(request: 1, descriptors: [
            .fixture(
                id: "partial-screenshot",
                creationDate: Date(timeIntervalSince1970: 1),
                isScreenshot: true
            )
        ])

        var partial: [PhotoAssetDescriptor]?
        for _ in 0..<100 {
            partial = await coordinator.takePartialDescriptors()
            if partial != nil { break }
            await Task.yield()
        }

        #expect(partial?.map(\.id) == ["partial-screenshot"])
        #expect((await collector.value).last?.phase == .completed)
    }

    @Test("Large scans persist progress in bounded batches")
    func largeScansBatchProgressPersistence() async throws {
        let descriptors = (0..<120).map { PhotoAssetDescriptor.fixture(id: "asset-\($0)") }
        let recorder = CountingCheckpointRecorder()
        let coordinator = ScanCoordinator(reader: DescriptorFixtureReader(descriptors: descriptors)) { checkpoint in
            await recorder.record(checkpoint)
        }

        let stream = await coordinator.start(
            screenshotAgeDays: 30,
            mode: .restart,
            checkpoint: nil
        )
        _ = await collect(stream)

        let checkpointCount = await recorder.count
        #expect(checkpointCount <= 6)
        #expect(await recorder.latest?.stage == .completed)
    }

    @Test("Incremental changes preserve unrelated decisions and exact identity")
    @MainActor
    func incrementalLibraryChanges() throws {
        var inventory = LibraryInventory(descriptors: [
            .fixture(id: "gone"),
            .fixture(id: "present")
        ])
        let repository = try SwiftDataTaskRepository(inMemory: true)
        try repository.save(decision: PhotoDecision(assetID: "gone", kind: .keep))
        try repository.save(decision: PhotoDecision(assetID: "present", kind: .protect))

        inventory.merge(
            PhotoLibraryChange(
                addedAssetIDs: ["new"],
                removedAssetIDs: ["gone"],
                scopeChanged: false
            ),
            addedDescriptors: [.fixture(id: "new")]
        )
        try repository.reconcile(availableAssetIDs: Set(inventory.descriptors.map(\.id)))

        #expect(inventory.descriptors.map(\.id) == ["present", "new"])
        #expect(try repository.decision(for: "gone") == nil)
        #expect(try repository.decision(for: "present")?.kind == .protect)
    }

    @Test("Resume preserves safe progress and processes only remaining assets")
    func resumesFromCheckpoint() async throws {
        var stored = LibraryScanSnapshot.starting
        stored.discoveredCount = 2
        stored.processedCount = 1
        stored.localCount = 1
        let checkpoint = ScanCheckpoint(
            id: "scan-1",
            stage: .checkingAvailability,
            processedAssetIDs: ["asset-1"],
            discoveredCount: 2,
            snapshot: stored,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let recorder = CheckpointRecorder()
        let reader = DescriptorFixtureReader(descriptors: [
            .fixture(id: "asset-1"),
            .fixture(id: "asset-2", isScreenshot: true)
        ])
        let coordinator = ScanCoordinator(reader: reader) { checkpoint in
            await recorder.record(checkpoint)
        }

        let stream = await coordinator.start(
            screenshotAgeDays: 30,
            mode: .resume,
            checkpoint: checkpoint
        )
        var updates: [LibraryScanSnapshot] = []
        for await update in stream { updates.append(update) }

        let completed = try #require(updates.last)
        #expect(completed.phase == .completed)
        #expect(completed.processedCount == 2)
        #expect(completed.localCount == 2)
        #expect(completed.screenshotCount == 1)
        let latest = await recorder.latest
        #expect(latest?.stage == .completed)
        #expect(latest?.processedAssetIDs == ["asset-1", "asset-2"])
    }

    @Test("Resume drops checkpoint identifiers that are no longer visible")
    func resumeRebuildsCountsForCurrentScope() async throws {
        var stored = LibraryScanSnapshot.starting
        stored.discoveredCount = 2
        stored.processedCount = 1
        stored.localCount = 1
        let checkpoint = ScanCheckpoint(
            id: "scope-change",
            stage: .cancelled,
            processedAssetIDs: ["removed"],
            discoveredCount: 2,
            snapshot: stored,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let reader = DescriptorFixtureReader(descriptors: [
            .fixture(
                id: "visible-screenshot",
                creationDate: Date(timeIntervalSince1970: 1),
                isScreenshot: true
            )
        ])
        let coordinator = ScanCoordinator(reader: reader) { _ in }

        let stream = await coordinator.start(
            screenshotAgeDays: 30,
            mode: .resume,
            checkpoint: checkpoint
        )
        let updates = await collect(stream)
        let completed = try #require(updates.last)

        #expect(completed.discoveredCount == 1)
        #expect(completed.processedCount == 1)
        #expect(completed.localCount == 1)
        #expect(completed.screenshotCount == 1)
    }

    @Test("A replacement scan prevents stale completion from being published")
    func replacementInvalidatesOldScan() async throws {
        let reader = ControlledDescriptorReader()
        let coordinator = ScanCoordinator(reader: reader) { _ in }

        let firstStream = await coordinator.start(
            screenshotAgeDays: 30,
            mode: .restart,
            checkpoint: nil
        )
        let firstCollector = Task { await collect(firstStream) }
        await reader.waitForRequestCount(1)

        let secondStream = await coordinator.start(
            screenshotAgeDays: 30,
            mode: .restart,
            checkpoint: nil
        )
        let secondCollector = Task { await collect(secondStream) }
        await reader.waitForRequestCount(2)

        await reader.resolve(request: 2, descriptors: [.fixture(id: "latest")])
        let secondUpdates = await secondCollector.value
        await reader.resolve(request: 1, descriptors: [.fixture(id: "stale")])
        let firstUpdates = await firstCollector.value

        #expect(secondUpdates.last?.phase == .completed)
        #expect(secondUpdates.last?.localCount == 1)
        #expect(!firstUpdates.contains { $0.phase == .completed })
    }

    @Test("Explicit cancellation preserves the latest safe checkpoint")
    func cancellationPersistsCheckpoint() async throws {
        let recorder = BlockingCheckpointRecorder()
        let reader = DescriptorFixtureReader(descriptors: [
            .fixture(id: "asset-1"),
            .fixture(id: "asset-2")
        ])
        let coordinator = ScanCoordinator(reader: reader) { checkpoint in
            await recorder.record(checkpoint)
        }
        let stream = await coordinator.start(
            screenshotAgeDays: 30,
            mode: .restart,
            checkpoint: nil
        )
        let collector = Task { await collect(stream) }

        await recorder.waitUntilFirstProgressIsSaving()
        await coordinator.cancelCurrent()
        await recorder.release()
        let updates = await collector.value

        #expect(updates.last?.phase == .cancelled)
        #expect(await recorder.latest?.stage == .cancelled)
        #expect(await recorder.latest?.processedAssetIDs == ["asset-1"])
    }

    @Test("A descriptor read failure saves a scoped failed checkpoint and retry can complete")
    func descriptorReadFailureCanRetry() async throws {
        let recorder = CheckpointRecorder()
        let reader = FailingThenWorkingDescriptorReader()
        let coordinator = ScanCoordinator(reader: reader) { checkpoint in
            await recorder.record(checkpoint)
        }

        let failedStream = await coordinator.start(
            screenshotAgeDays: 30,
            mode: .restart,
            checkpoint: nil
        )
        let failedUpdates = await collect(failedStream)

        #expect(failedUpdates.last?.phase == .failed)
        #expect(failedUpdates.last?.errorMessage?.contains("当前可访问范围") == true)
        #expect(await recorder.latest?.stage == .failed)

        let retryStream = await coordinator.start(
            screenshotAgeDays: 30,
            mode: .restart,
            checkpoint: nil
        )
        let retryUpdates = await collect(retryStream)

        #expect(retryUpdates.last?.phase == .completed)
        #expect(retryUpdates.last?.localCount == 1)
    }

    @Test("Overlapping restarts keep the newest delayed checkpoint")
    func overlappingRestartsSerializeDelayedCheckpoints() async throws {
        let recorder = DelayedCheckpointRecorder()
        let coordinator = ScanCoordinator(
            reader: DescriptorFixtureReader(descriptors: []),
            checkpointSink: { checkpoint in
                await recorder.record(checkpoint)
            }
        )

        let firstStart = Task {
            await coordinator.start(
                screenshotAgeDays: 30,
                mode: .restart,
                checkpoint: nil
            )
        }
        await recorder.waitForFirstCheckpoint()

        let secondStart = Task {
            await coordinator.start(
                screenshotAgeDays: 30,
                mode: .restart,
                checkpoint: nil
            )
        }
        for _ in 0..<100 { await Task.yield() }
        await recorder.releaseFirstCheckpoint()

        _ = await firstStart.value
        _ = await secondStart.value
        let secondID = try #require(await recorder.secondID)
        #expect(await recorder.latestID == secondID)
    }
}

private func collect(_ stream: AsyncStream<LibraryScanSnapshot>) async -> [LibraryScanSnapshot] {
    var updates: [LibraryScanSnapshot] = []
    for await update in stream { updates.append(update) }
    return updates
}

private actor CheckpointRecorder {
    private(set) var latest: ScanCheckpoint?

    func record(_ checkpoint: ScanCheckpoint) {
        latest = checkpoint
    }
}

private actor CountingCheckpointRecorder {
    private(set) var count = 0
    private(set) var latest: ScanCheckpoint?

    func record(_ checkpoint: ScanCheckpoint) {
        count += 1
        latest = checkpoint
    }
}

private actor BlockingCheckpointRecorder {
    private(set) var latest: ScanCheckpoint?
    private var didBlock = false
    private var isBlocked = false
    private var continuation: CheckedContinuation<Void, Never>?

    func record(_ checkpoint: ScanCheckpoint) async {
        latest = checkpoint
        guard !didBlock, checkpoint.stage == .checkingAvailability else { return }
        didBlock = true
        isBlocked = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilFirstProgressIsSaving() async {
        while !isBlocked { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor DelayedCheckpointRecorder {
    private var firstID: String?
    private(set) var secondID: String?
    private(set) var latestID: String?
    private var firstContinuation: CheckedContinuation<Void, Never>?

    func record(_ checkpoint: ScanCheckpoint) async {
        if firstID == nil {
            firstID = checkpoint.id
            await withCheckedContinuation { firstContinuation = $0 }
        } else if checkpoint.id != firstID, secondID == nil {
            secondID = checkpoint.id
        }
        latestID = checkpoint.id
    }

    func waitForFirstCheckpoint() async {
        while firstContinuation == nil { await Task.yield() }
    }

    func releaseFirstCheckpoint() {
        firstContinuation?.resume()
        firstContinuation = nil
    }
}

private actor DescriptorFixtureReader: PhotoLibraryReading {
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

private actor ControlledDescriptorReader: PhotoLibraryReading {
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

private actor FailingThenWorkingDescriptorReader: PhotoLibraryReading {
    private var requestCount = 0

    func authorizationStatus() -> PhotoAuthorization { .authorized }
    func requestAuthorization() -> PhotoAuthorization { .authorized }

    func accessibleAssetDescriptors() async throws -> [PhotoAssetDescriptor] {
        requestCount += 1
        if requestCount == 1 {
            throw PhotoLibraryReadError.scopeUnavailable
        }
        return [.fixture(id: "retry")]
    }

    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> {
        AsyncStream { $0.finish() }
    }
}

private extension PhotoAssetDescriptor {
    nonisolated static func fixture(
        id: String,
        creationDate: Date = Date(timeIntervalSince1970: 100),
        isScreenshot: Bool = false
    ) -> PhotoAssetDescriptor {
        PhotoAssetDescriptor(
            id: id,
            mediaType: .photo,
            creationDate: creationDate,
            pixelWidth: 1_000,
            pixelHeight: 1_000,
            duration: 0,
            estimatedBytes: 1_000,
            isFavorite: false,
            isEdited: false,
            isScreenshot: isScreenshot,
            burstIdentifier: nil,
            availability: .local
        )
    }
}
