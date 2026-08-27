import Photos
import Testing
@testable import PhotoBox

@Suite("PhotoBox core state")
struct PhotoBoxTests {
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
        await waitUntil { model.scan.phase == .completed }

        #expect(model.authorization == .authorized)
        #expect(model.scan.screenshotCount == 4)
    }

    @Test("Denied access clears an existing scan")
    @MainActor
    func deniedAccessClearsScan() async {
        var completed = LibraryScanSnapshot.idle
        completed.phase = .completed
        let service = MockPhotoLibraryService(authorization: .authorized, snapshots: [completed])
        let model = AppModel(library: service)

        await model.refreshAuthorization()
        await waitUntil { model.scan.phase == .completed }
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
        await service.waitForScanCount(1)

        model.rescan()
        await service.waitForScanCount(2)

        var latest = LibraryScanSnapshot.idle
        latest.phase = .completed
        latest.screenshotCount = 2
        await service.publish(latest, toScan: 2)
        await waitUntil { model.scan.screenshotCount == 2 }

        var stale = LibraryScanSnapshot.idle
        stale.phase = .completed
        stale.screenshotCount = 99
        await service.publish(stale, toScan: 1)
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(model.scan.screenshotCount == 2)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<50 where !condition() {
            await Task.yield()
        }
    }
}

private actor ControlledPhotoLibraryService: PhotoLibraryServing {
    private var continuations: [Int: AsyncStream<LibraryScanSnapshot>.Continuation] = [:]
    private var scanCount = 0

    func authorizationStatus() -> PhotoAuthorization {
        .authorized
    }

    func requestAuthorization() -> PhotoAuthorization {
        .authorized
    }

    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> {
        scanCount += 1
        let currentScan = scanCount
        return AsyncStream { continuation in
            continuations[currentScan] = continuation
        }
    }

    func waitForScanCount(_ expectedCount: Int) async {
        for _ in 0..<100 where scanCount < expectedCount {
            await Task.yield()
        }
    }

    func publish(_ snapshot: LibraryScanSnapshot, toScan scan: Int) {
        continuations[scan]?.yield(snapshot)
    }
}

private actor MockPhotoLibraryService: PhotoLibraryServing {
    private var authorization: PhotoAuthorization
    private let snapshots: [LibraryScanSnapshot]

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
