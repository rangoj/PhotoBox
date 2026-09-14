import Foundation
import Testing
@testable import PhotoBox

@Suite("Bounded candidate discovery")
struct CandidateDiscoveryTests {
    @Test("Discovery excludes cloud-only and unsupported single-item evidence")
    func conservativeDiscovery() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let old = now.addingTimeInterval(-40 * 86_400)
        let near = now.addingTimeInterval(-10)
        let descriptors = [
            PhotoAssetDescriptor.fixture(id: "screenshot", creationDate: old, isScreenshot: true),
            .fixture(id: "cloud-shot", creationDate: old, isScreenshot: true, availability: .iCloudOnly),
            .fixture(id: "burst-1", creationDate: near, burstIdentifier: "burst"),
            .fixture(id: "burst-2", creationDate: near.addingTimeInterval(1), burstIdentifier: "burst"),
            .fixture(id: "single", creationDate: now.addingTimeInterval(-100)),
            .fixture(id: "video", mediaType: .video, creationDate: near, duration: 90),
            .fixture(id: "cloud-video", mediaType: .video, creationDate: near, duration: 120, availability: .iCloudOnly)
        ]

        let result = MetadataCandidateNarrower().discover(
            descriptors: descriptors,
            now: now,
            screenshotAgeDays: 30
        )

        #expect(result.expiredScreenshotIDs == ["screenshot"])
        #expect(result.largeVideoIDs == ["video"])
        #expect(result.groups == [
            PhotoCandidateCluster(id: "burst:burst", kind: .burst, assetIDs: ["burst-1", "burst-2"])
        ])
        #expect(!result.allCandidateIDs.contains("cloud-shot"))
        #expect(!result.allCandidateIDs.contains("cloud-video"))
        #expect(!result.allCandidateIDs.contains("single"))
    }

    @Test("Thumbnail loading never exceeds its concurrency bound")
    func boundedThumbnailLoading() async {
        let reader = ThumbnailFixtureReader()
        let loader = BoundedThumbnailLoader(reader: reader, maxConcurrentRequests: 2)

        let thumbnails = await loader.load(
            assetIDs: ["1", "2", "3", "4"],
            maxPixelSize: 512
        )

        #expect(thumbnails.map(\.assetID) == ["1", "2", "3", "4"])
        #expect(await reader.maximumConcurrentRequests <= 2)
        #expect(await reader.requestedPixelSizes == [512, 512, 512, 512])
    }

    @Test("Thumbnail loads reuse cached pixels for the same size")
    func thumbnailLoadsUseCache() async {
        let reader = ThumbnailFixtureReader()
        let loader = BoundedThumbnailLoader(reader: reader, maxConcurrentRequests: 2)

        _ = await loader.load(assetIDs: ["1", "2"], maxPixelSize: 512)
        _ = await loader.load(assetIDs: ["1", "2"], maxPixelSize: 512)
        #expect(await reader.requestedPixelSizes == [512, 512])

        _ = await loader.load(assetIDs: ["1"], maxPixelSize: 256)
        #expect(await reader.requestedPixelSizes == [512, 512, 256])
    }

    @Test("Thumbnail cache evicts the least recently used asset")
    func thumbnailCacheEvictsLeastRecentlyUsed() async {
        let reader = ThumbnailFixtureReader()
        let loader = BoundedThumbnailLoader(
            reader: reader,
            maxConcurrentRequests: 1,
            maximumCachedThumbnails: 2
        )

        _ = await loader.load(assetIDs: ["1", "2"], maxPixelSize: 512)
        _ = await loader.load(assetIDs: ["1"], maxPixelSize: 512)
        _ = await loader.load(assetIDs: ["3"], maxPixelSize: 512)
        _ = await loader.load(assetIDs: ["2"], maxPixelSize: 512)

        #expect(await reader.requestedAssetIDs == ["1", "2", "3", "2"])
    }

    @Test("Concurrent thumbnail misses for one asset share a PhotoKit request")
    func concurrentThumbnailMissesAreCoalesced() async {
        let reader = ThumbnailFixtureReader(delay: .milliseconds(100))
        let loader = BoundedThumbnailLoader(reader: reader, maxConcurrentRequests: 2)
        let first = Task { await loader.load(assetIDs: ["same"], maxPixelSize: 512) }

        for _ in 0..<100 {
            if await reader.requestCount > 0 { break }
            await Task.yield()
        }
        let second = Task { await loader.load(assetIDs: ["same"], maxPixelSize: 512) }

        _ = await first.value
        _ = await second.value
        #expect(await reader.requestedAssetIDs == ["same"])
    }

    @Test("Cancelled thumbnail loads discard an obsolete completion")
    func cancelledThumbnailLoading() async {
        let reader = UncooperativeThumbnailReader()
        let loader = BoundedThumbnailLoader(reader: reader, maxConcurrentRequests: 1)
        let task = Task {
            await loader.load(assetIDs: ["obsolete"], maxPixelSize: 512)
        }

        await reader.waitUntilRequested()
        task.cancel()
        await reader.resolve()

        #expect((await task.value).isEmpty)
    }

    @Test("Thumbnail request cancellation reaches PhotoKit exactly once")
    func thumbnailRequestCancellation() {
        let recorder = ThumbnailRequestCancellationRecorder()
        let registeredRequest = ThumbnailRequestBridge<Int>(cancelRequest: recorder.record)
        registeredRequest.register(requestID: 1)
        registeredRequest.cancel()
        registeredRequest.cancel()

        let pendingRequest = ThumbnailRequestBridge<Int>(cancelRequest: recorder.record)
        pendingRequest.cancel()
        pendingRequest.register(requestID: 2)
        pendingRequest.cancel()

        let callbackBeforeRegistration = ThumbnailRequestBridge<Int>(cancelRequest: recorder.record)
        callbackBeforeRegistration.cancel()
        callbackBeforeRegistration.resume(returning: nil)
        callbackBeforeRegistration.register(requestID: 3)
        callbackBeforeRegistration.cancel()

        #expect(recorder.requestIDs == [1, 2, 3])
    }
}

@Suite("Conservative local recommendations")
struct PhotoRecommendationTests {
    @Test("A clear supported winner includes a verifiable reason")
    func supportedRecommendation() {
        let engine = LocalPhotoAnalysisEngine()
        let result = engine.recommendation(for: PhotoCandidateGroup(
            id: "group",
            kind: .similar,
            candidates: [
                .fixture(id: "sharp", quality: .init(sharpness: 0.95, exposure: 0.8, completeness: 0.8)),
                .fixture(id: "soft", quality: .init(sharpness: 0.35, exposure: 0.7, completeness: 0.7))
            ]
        ))

        #expect(result.recommendedKeepID == "sharp")
        #expect(result.reasons.contains(.sharper))
    }

    @Test("Protected evidence outranks visual quality")
    func protectedOverride() {
        let engine = LocalPhotoAnalysisEngine()
        let result = engine.recommendation(for: PhotoCandidateGroup(
            id: "group",
            kind: .similar,
            candidates: [
                .fixture(
                    id: "favorite",
                    quality: .init(sharpness: 0.2, exposure: 0.2, completeness: 0.2),
                    isFavorite: true
                ),
                .fixture(id: "regular", quality: .init(sharpness: 0.95, exposure: 0.95, completeness: 0.95))
            ]
        ))

        #expect(result.recommendedKeepID == "favorite")
        #expect(result.reasons == [.favorite])
    }

    @Test("Low-confidence groups do not claim a best photo")
    func lowConfidenceHasNoBest() {
        let engine = LocalPhotoAnalysisEngine(minimumWinningMargin: 0.12)
        let result = engine.recommendation(for: PhotoCandidateGroup(
            id: "group",
            kind: .similar,
            candidates: [
                .fixture(id: "a", quality: .init(sharpness: 0.8, exposure: 0.8, completeness: 0.8)),
                .fixture(id: "b", quality: .init(sharpness: 0.78, exposure: 0.78, completeness: 0.78))
            ]
        ))

        #expect(result.recommendedKeepID == nil)
        #expect(result.reasons.isEmpty)
    }
}

private actor ThumbnailFixtureReader: PhotoLibraryReading {
    private var activeRequests = 0
    private(set) var maximumConcurrentRequests = 0
    private(set) var requestedAssetIDs: [String] = []
    private(set) var requestedPixelSizes: [Int] = []
    private let delay: Duration

    init(delay: Duration = .milliseconds(10)) {
        self.delay = delay
    }

    var requestCount: Int { requestedAssetIDs.count }

    func authorizationStatus() -> PhotoAuthorization { .authorized }
    func requestAuthorization() -> PhotoAuthorization { .authorized }
    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> {
        AsyncStream { $0.finish() }
    }

    func thumbnail(for assetID: String, maxPixelSize: Int) async -> PhotoThumbnail? {
        activeRequests += 1
        maximumConcurrentRequests = max(maximumConcurrentRequests, activeRequests)
        requestedAssetIDs.append(assetID)
        requestedPixelSizes.append(maxPixelSize)
        try? await Task.sleep(for: delay)
        activeRequests -= 1
        return PhotoThumbnail(assetID: assetID, data: Data(assetID.utf8), pixelWidth: 10, pixelHeight: 10)
    }
}

private actor UncooperativeThumbnailReader: PhotoLibraryReading {
    private var thumbnailContinuation: CheckedContinuation<PhotoThumbnail?, Never>?
    private var requestContinuation: CheckedContinuation<Void, Never>?

    func authorizationStatus() -> PhotoAuthorization { .authorized }
    func requestAuthorization() -> PhotoAuthorization { .authorized }
    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> {
        AsyncStream { $0.finish() }
    }

    func thumbnail(for assetID: String, maxPixelSize: Int) async -> PhotoThumbnail? {
        requestContinuation?.resume()
        requestContinuation = nil
        return await withCheckedContinuation { continuation in
            thumbnailContinuation = continuation
        }
    }

    func waitUntilRequested() async {
        if thumbnailContinuation != nil { return }
        await withCheckedContinuation { continuation in
            requestContinuation = continuation
        }
    }

    func resolve() {
        thumbnailContinuation?.resume(returning: PhotoThumbnail(
            assetID: "obsolete",
            data: Data("obsolete".utf8),
            pixelWidth: 10,
            pixelHeight: 10
        ))
        thumbnailContinuation = nil
    }
}

private final class ThumbnailRequestCancellationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requestIDs: [Int] = []

    func record(_ requestID: Int) {
        lock.lock()
        requestIDs.append(requestID)
        lock.unlock()
    }
}

private extension PhotoAssetDescriptor {
    static func fixture(
        id: String,
        mediaType: PhotoMediaType = .photo,
        creationDate: Date,
        duration: TimeInterval = 0,
        isScreenshot: Bool = false,
        burstIdentifier: String? = nil,
        availability: AssetAvailability = .local
    ) -> PhotoAssetDescriptor {
        PhotoAssetDescriptor(
            id: id,
            mediaType: mediaType,
            creationDate: creationDate,
            pixelWidth: 1_000,
            pixelHeight: 1_000,
            duration: duration,
            estimatedBytes: 1_000,
            isFavorite: false,
            isEdited: false,
            isScreenshot: isScreenshot,
            burstIdentifier: burstIdentifier,
            availability: availability
        )
    }
}

private extension PhotoCandidate {
    static func fixture(
        id: String,
        quality: PhotoQualitySignals,
        isFavorite: Bool = false,
        isEdited: Bool = false,
        manualProtection: Bool = false
    ) -> PhotoCandidate {
        PhotoCandidate(
            asset: PhotoAssetDescriptor(
                id: id,
                mediaType: .photo,
                creationDate: Date(timeIntervalSince1970: 100),
                pixelWidth: 1_000,
                pixelHeight: 1_000,
                duration: 0,
                estimatedBytes: 1_000,
                isFavorite: isFavorite,
                isEdited: isEdited,
                isScreenshot: false,
                burstIdentifier: nil,
                availability: .local
            ),
            quality: quality,
            manualProtection: manualProtection
        )
    }
}
