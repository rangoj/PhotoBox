import Photos
import Testing
@testable import PhotoBox

@Suite("PhotoBox core state")
struct PhotoBoxTests {
    @Test("PhotoKit metadata maps to an immutable asset descriptor")
    func assetDescriptorMapping() {
        let creationDate = Date(timeIntervalSince1970: 500)
        let descriptor = PhotoLibraryClassifier.descriptor(
            id: "asset-1",
            mediaType: .image,
            mediaSubtypes: [.photoLive, .photoScreenshot],
            creationDate: creationDate,
            pixelWidth: 4_032,
            pixelHeight: 3_024,
            duration: 0,
            estimatedBytes: 1_024,
            isFavorite: true,
            isEdited: false,
            burstIdentifier: "burst-1",
            availability: .local
        )

        #expect(descriptor == PhotoAssetDescriptor(
            id: "asset-1",
            mediaType: .livePhoto,
            creationDate: creationDate,
            pixelWidth: 4_032,
            pixelHeight: 3_024,
            duration: 0,
            estimatedBytes: 1_024,
            isFavorite: true,
            isEdited: false,
            isScreenshot: true,
            burstIdentifier: "burst-1",
            availability: .local
        ))
    }

    @Test("Photo authorization maps every system state")
    func authorizationMapping() {
        #expect(PhotoAuthorization(.notDetermined) == .notDetermined)
        #expect(PhotoAuthorization(.authorized) == .authorized)
        #expect(PhotoAuthorization(.limited) == .limited)
        #expect(PhotoAuthorization(.denied) == .denied)
        #expect(PhotoAuthorization(.restricted) == .restricted)
    }

    @Test("Only full and limited access permit scanning")
    func scanningAuthorization() {
        #expect(PhotoLibraryClassifier.authorizationAllowsScanning(.authorized))
        #expect(PhotoLibraryClassifier.authorizationAllowsScanning(.limited))
        #expect(!PhotoLibraryClassifier.authorizationAllowsScanning(.denied))
        #expect(!PhotoLibraryClassifier.authorizationAllowsScanning(.restricted))
        #expect(!PhotoLibraryClassifier.authorizationAllowsScanning(.notDetermined))
    }

    @Test("Scan progress remains bounded")
    func scanProgress() {
        var snapshot = LibraryScanSnapshot.starting
        snapshot.discoveredCount = 40
        snapshot.processedCount = 10
        #expect(snapshot.progress == 0.25)

        snapshot.processedCount = 50
        #expect(snapshot.progress == 1)
    }

    @Test("Asset availability never treats a cloud placeholder as local")
    func assetAvailability() {
        #expect(PhotoLibraryClassifier.availability(dataExists: true, isInCloud: true) == .iCloudOnly)
        #expect(PhotoLibraryClassifier.availability(dataExists: false, isInCloud: true) == .iCloudOnly)
        #expect(PhotoLibraryClassifier.availability(dataExists: false, isInCloud: false) == .unavailable)
    }

    @Test("Only screenshots older than the cutoff enter the screenshot task")
    func expiredScreenshotClassification() {
        let cutoff = Date(timeIntervalSince1970: 1_000)
        #expect(PhotoLibraryClassifier.isExpiredScreenshot(
            mediaType: .image,
            mediaSubtypes: .photoScreenshot,
            creationDate: Date(timeIntervalSince1970: 999),
            cutoff: cutoff
        ))
        #expect(!PhotoLibraryClassifier.isExpiredScreenshot(
            mediaType: .image,
            mediaSubtypes: .photoScreenshot,
            creationDate: cutoff,
            cutoff: cutoff
        ))
        #expect(!PhotoLibraryClassifier.isExpiredScreenshot(
            mediaType: .image,
            mediaSubtypes: [],
            creationDate: Date(timeIntervalSince1970: 999),
            cutoff: cutoff
        ))
    }

    @Test("Video diagnosis starts at sixty seconds")
    func longVideoClassification() {
        #expect(!PhotoLibraryClassifier.isLargeVideoCandidate(mediaType: .video, duration: 59.9))
        #expect(PhotoLibraryClassifier.isLargeVideoCandidate(mediaType: .video, duration: 60))
        #expect(!PhotoLibraryClassifier.isLargeVideoCandidate(mediaType: .image, duration: 120))
    }

    @Test("Photo requests never enable iCloud network access")
    func photoRequestPolicy() {
        #expect(!PhotoLibraryRequestPolicy.imageOptions().isNetworkAccessAllowed)
        #expect(!PhotoLibraryRequestPolicy.videoOptions().isNetworkAccessAllowed)
    }

    @Test("Authorized model publishes the latest scan snapshot")
    @MainActor
    func appModelPublishesScan() async {
        var completed = LibraryScanSnapshot.idle
        completed.phase = .completed
        completed.screenshotCount = 4
        let service = MockPhotoLibraryService(authorization: .authorized, snapshots: [completed])
        let model = AppModel(library: service)

        await model.refreshAuthorization()
        await waitUntil("the initial scan to complete") { model.scan.phase == .completed }

        #expect(model.authorization == .authorized)
        #expect(model.scan.screenshotCount == 4)
    }

    @Test("App activation reuses a completed scan")
    @MainActor
    func appActivationDoesNotRestartCompletedScan() async {
        var completed = LibraryScanSnapshot.idle
        completed.phase = .completed
        let service = MockPhotoLibraryService(authorization: .authorized, snapshots: [completed])
        let model = AppModel(library: service)

        await model.refreshAuthorization()
        await waitUntil("the initial scan to complete") { model.scan.phase == .completed }
        let firstCount = await service.scanRequestCount()

        await model.refreshForAppActivation()

        #expect(await service.scanRequestCount() == firstCount)
    }

    @Test("A completed production scan materializes candidate tasks once")
    @MainActor
    func completedProductionScanMaterializesTasksWithoutDuplicates() async {
        let repository = try! SwiftDataTaskRepository(inMemory: true)
        let model = AppModel(
            library: ProductionTaskPhotoLibraryService(),
            repository: repository
        )

        await model.refreshAuthorization()
        await waitUntil("production tasks to materialize") {
            model.scan.phase == .completed && !model.cleanupTasks.isEmpty
        }
        let firstTasks = model.cleanupTasks
        model.rescan()
        await waitUntil("the replacement scan to complete") {
            model.scan.phase == .completed
        }

        #expect(firstTasks.map(\.id) == model.cleanupTasks.map(\.id))
        #expect(model.cleanupTasks.contains { $0.type == .screenshots })
        #expect(model.cleanupTasks.contains { $0.type == .bursts })
    }

    @Test("AppModel shows a task while the descriptor scan is still running")
    @MainActor
    func partialScanMaterializesTaskBeforeCompletion() async {
        let repository = try! SwiftDataTaskRepository(inMemory: true)
        let reader = PartialTaskPhotoLibraryService()
        let model = AppModel(library: reader, repository: repository)

        await model.refreshAuthorization()
        await reader.waitForStream()
        await reader.yield(PartialTaskPhotoLibraryService.screenshot(id: "partial-task"))

        await waitUntil("the first partial cleanup task") {
            model.scan.isScanning && model.cleanupTasks.contains { $0.type == .screenshots }
        }

        #expect(model.scan.isScanning)
        #expect(model.cleanupTasks.contains { $0.assetIDs == ["partial-task"] })

        await reader.finish()
        await waitUntil("the partial scan to complete") { model.scan.phase == .completed }
    }

    @Test("Denied access clears an existing scan")
    @MainActor
    func deniedAccessClearsScan() async {
        var completed = LibraryScanSnapshot.idle
        completed.phase = .completed
        let service = MockPhotoLibraryService(authorization: .authorized, snapshots: [completed])
        let model = AppModel(library: service)

        await model.refreshAuthorization()
        await waitUntil("the initial scan to complete") { model.scan.phase == .completed }
        await service.setAuthorization(.denied)
        await model.refreshAuthorization()

        #expect(model.authorization == .denied)
        #expect(model.scan == .idle)
    }

    @Test("A restarted scan ignores results from the cancelled scan")
    @MainActor
    func restartedScanIgnoresStaleResults() async {
        let service = ControlledPhotoLibraryService()
        let model = AppModel(library: service)

        await model.refreshAuthorization()
        guard await service.waitForScanCount(1) else {
            Issue.record("Timed out waiting for the initial scan to begin descriptor enumeration")
            return
        }

        model.rescan()
        guard await service.waitForScanCount(2) else {
            Issue.record("Timed out waiting for the replacement scan to begin descriptor enumeration")
            return
        }

        await service.resolve(
            descriptors: [
                ControlledPhotoLibraryService.screenshot(id: "latest-1"),
                ControlledPhotoLibraryService.screenshot(id: "latest-2")
            ],
            forScan: 2
        )
        await waitUntil("the replacement scan to process both screenshots") {
            model.scan.screenshotCount == 2
        }

        await service.resolve(
            descriptors: [ControlledPhotoLibraryService.screenshot(id: "stale")],
            forScan: 1
        )
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(model.scan.screenshotCount == 2)
    }

    @Test("Resuming a cancelled scan keeps its checkpoint while restarting clears it")
    @MainActor
    func appModelResumeAndRestart() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        var paused = LibraryScanSnapshot.starting
        paused.phase = .cancelled
        paused.discoveredCount = 2
        paused.processedCount = 1
        paused.localCount = 1
        let checkpoint = ScanCheckpoint(
            id: "saved-scan",
            stage: .cancelled,
            processedAssetIDs: ["first"],
            discoveredCount: 2,
            snapshot: paused,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        try repository.save(checkpoint: checkpoint)
        let model = AppModel(
            library: ResumeFixturePhotoLibraryService(),
            repository: repository
        )

        await model.refreshAuthorization()
        model.resumeScan()
        await waitUntil("the resumed scan to complete") { model.scan.phase == .completed }

        #expect(model.scan.processedCount == 2)
        #expect(model.scan.localCount == 2)
        #expect(try repository.latestCheckpoint()?.id == "saved-scan")

        model.restartScan()
        #expect(model.scan == .starting)
        await waitUntil("the restarted scan to complete") { model.scan.phase == .completed }

        #expect(model.scan.processedCount == 2)
        #expect(try repository.latestCheckpoint()?.processedAssetIDs == ["first", "second"])
    }

    @Test("Restart replaces a paused checkpoint before descriptor enumeration finishes")
    @MainActor
    func restartPersistsReplacementCheckpointBeforeEnumeration() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        var paused = LibraryScanSnapshot.starting
        paused.phase = .cancelled
        paused.discoveredCount = 4
        paused.processedCount = 2
        let oldCheckpoint = ScanCheckpoint(
            id: "paused-scan",
            stage: .cancelled,
            processedAssetIDs: ["one", "two"],
            discoveredCount: 4,
            snapshot: paused,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        try repository.save(checkpoint: oldCheckpoint)
        let reader = RestartBlockingReader()
        let model = AppModel(library: reader, repository: repository)

        await model.refreshAuthorization()
        model.restartScan()
        await reader.waitForRequestCount(1)

        let reconstructed = AppModel(library: reader, repository: repository)
        let replacement = try #require(try repository.latestCheckpoint())
        #expect(reconstructed.scan.phase == .discovering)
        #expect(replacement.id != oldCheckpoint.id)
        #expect(replacement.stage == .enumerating)
        #expect(replacement.processedAssetIDs.isEmpty)

        await reader.resolve(descriptors: [])
    }

    @MainActor
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 2,
        condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                Issue.record("Timed out waiting for \(description) after \(timeout) seconds")
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor ControlledPhotoLibraryService: PhotoLibraryReading {
    private var continuations: [Int: CheckedContinuation<[PhotoAssetDescriptor], Never>] = [:]
    private var pendingDescriptors: [Int: [PhotoAssetDescriptor]] = [:]
    private var scanCount = 0

    func authorizationStatus() -> PhotoAuthorization {
        .authorized
    }

    func requestAuthorization() -> PhotoAuthorization {
        .authorized
    }

    func accessibleAssetDescriptors() async -> [PhotoAssetDescriptor] {
        scanCount += 1
        let currentScan = scanCount
        if let descriptors = pendingDescriptors.removeValue(forKey: currentScan) {
            return descriptors
        }
        return await withCheckedContinuation { continuation in
            continuations[currentScan] = continuation
        }
    }

    func waitForScanCount(
        _ expectedCount: Int,
        timeout: TimeInterval = 2
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while scanCount < expectedCount {
            guard Date() < deadline else {
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    func resolve(descriptors: [PhotoAssetDescriptor], forScan scan: Int) {
        if let continuation = continuations.removeValue(forKey: scan) {
            continuation.resume(returning: descriptors)
        } else {
            pendingDescriptors[scan] = descriptors
        }
    }

    nonisolated static func screenshot(id: String) -> PhotoAssetDescriptor {
        PhotoAssetDescriptor(
            id: id,
            mediaType: .photo,
            creationDate: Date(timeIntervalSince1970: 1),
            pixelWidth: 1_000,
            pixelHeight: 1_000,
            duration: 0,
            estimatedBytes: 1_000,
            isFavorite: false,
            isEdited: false,
            isScreenshot: true,
            burstIdentifier: nil,
            availability: .local
        )
    }

    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> {
        AsyncStream { $0.finish() }
    }
}

private actor MockPhotoLibraryService: PhotoLibraryReading {
    private var authorization: PhotoAuthorization
    private let snapshots: [LibraryScanSnapshot]
    private var descriptorRequests = 0

    init(authorization: PhotoAuthorization, snapshots: [LibraryScanSnapshot]) {
        self.authorization = authorization
        self.snapshots = snapshots
    }

    func authorizationStatus() -> PhotoAuthorization {
        authorization
    }

    func requestAuthorization() -> PhotoAuthorization {
        authorization
    }

    func accessibleAssetDescriptors() -> [PhotoAssetDescriptor] {
        descriptorRequests += 1
        let count = snapshots.last?.screenshotCount ?? 0
        return (0..<count).map { index in
            PhotoAssetDescriptor(
                id: "screenshot-\(index)",
                mediaType: .photo,
                creationDate: Date(timeIntervalSince1970: 1),
                pixelWidth: 1_000,
                pixelHeight: 1_000,
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

    func scanRequestCount() -> Int { descriptorRequests }

    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> {
        let snapshots = snapshots
        return AsyncStream { continuation in
            for snapshot in snapshots {
                continuation.yield(snapshot)
            }
            continuation.finish()
        }
    }

    func setAuthorization(_ authorization: PhotoAuthorization) {
        self.authorization = authorization
    }
}

private actor PartialTaskPhotoLibraryService: PhotoLibraryReading {
    private var continuation: AsyncThrowingStream<PhotoAssetDescriptor, Error>.Continuation?

    func authorizationStatus() -> PhotoAuthorization { .authorized }
    func requestAuthorization() -> PhotoAuthorization { .authorized }

    func assetDescriptorStream(screenshotAgeDays: Int) async throws -> PhotoLibraryDescriptorStream {
        let pair = AsyncThrowingStream<PhotoAssetDescriptor, Error>.makeStream()
        continuation = pair.continuation
        return PhotoLibraryDescriptorStream(discoveredCount: 2, stream: pair.stream)
    }

    func yield(_ descriptor: PhotoAssetDescriptor) {
        continuation?.yield(descriptor)
    }

    func finish() {
        continuation?.finish()
        continuation = nil
    }

    func waitForStream() async {
        while continuation == nil { await Task.yield() }
    }

    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> {
        AsyncStream { $0.finish() }
    }

    nonisolated static func screenshot(id: String) -> PhotoAssetDescriptor {
        PhotoAssetDescriptor(
            id: id,
            mediaType: .photo,
            creationDate: Date(timeIntervalSince1970: 1),
            pixelWidth: 1_000,
            pixelHeight: 1_000,
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

private actor ProductionTaskPhotoLibraryService: PhotoLibraryReading {
    private let descriptors: [PhotoAssetDescriptor] = [
        PhotoAssetDescriptor(
            id: "production-screenshot",
            mediaType: .photo,
            creationDate: Date(timeIntervalSince1970: 1),
            pixelWidth: 1_000,
            pixelHeight: 1_000,
            duration: 0,
            estimatedBytes: 2_000,
            isFavorite: false,
            isEdited: false,
            isScreenshot: true,
            burstIdentifier: nil,
            availability: .local
        ),
        PhotoAssetDescriptor(
            id: "production-burst-a",
            mediaType: .photo,
            creationDate: Date(timeIntervalSince1970: 1_000),
            pixelWidth: 1_000,
            pixelHeight: 1_000,
            duration: 0,
            estimatedBytes: 1_000,
            isFavorite: false,
            isEdited: false,
            isScreenshot: false,
            burstIdentifier: "production-burst",
            availability: .local
        ),
        PhotoAssetDescriptor(
            id: "production-burst-b",
            mediaType: .photo,
            creationDate: Date(timeIntervalSince1970: 1_001),
            pixelWidth: 1_000,
            pixelHeight: 1_000,
            duration: 0,
            estimatedBytes: 1_000,
            isFavorite: false,
            isEdited: false,
            isScreenshot: false,
            burstIdentifier: "production-burst",
            availability: .local
        )
    ]

    func authorizationStatus() -> PhotoAuthorization { .authorized }
    func requestAuthorization() -> PhotoAuthorization { .authorized }
    func accessibleAssetDescriptors() -> [PhotoAssetDescriptor] { descriptors }

    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> {
        AsyncStream { $0.finish() }
    }
}

private actor ResumeFixturePhotoLibraryService: PhotoLibraryReading {
    func authorizationStatus() -> PhotoAuthorization { .authorized }
    func requestAuthorization() -> PhotoAuthorization { .authorized }

    func accessibleAssetDescriptors() -> [PhotoAssetDescriptor] {
        [
            PhotoAssetDescriptor(
                id: "first",
                mediaType: .photo,
                creationDate: Date(timeIntervalSince1970: 1),
                pixelWidth: 1_000,
                pixelHeight: 1_000,
                duration: 0,
                estimatedBytes: 1_000,
                isFavorite: false,
                isEdited: false,
                isScreenshot: false,
                burstIdentifier: nil,
                availability: .local
            ),
            PhotoAssetDescriptor(
                id: "second",
                mediaType: .photo,
                creationDate: Date(timeIntervalSince1970: 2),
                pixelWidth: 1_000,
                pixelHeight: 1_000,
                duration: 0,
                estimatedBytes: 1_000,
                isFavorite: false,
                isEdited: false,
                isScreenshot: false,
                burstIdentifier: nil,
                availability: .local
            )
        ]
    }

    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> {
        AsyncStream { $0.finish() }
    }
}

private actor RestartBlockingReader: PhotoLibraryReading {
    private var requestCount = 0
    private var continuation: CheckedContinuation<[PhotoAssetDescriptor], Never>?

    func authorizationStatus() -> PhotoAuthorization { .authorized }
    func requestAuthorization() -> PhotoAuthorization { .authorized }

    func accessibleAssetDescriptors() async -> [PhotoAssetDescriptor] {
        requestCount += 1
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitForRequestCount(_ expected: Int) async {
        while requestCount < expected { await Task.yield() }
    }

    func resolve(descriptors: [PhotoAssetDescriptor]) {
        continuation?.resume(returning: descriptors)
        continuation = nil
    }

    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> {
        AsyncStream { $0.finish() }
    }
}
