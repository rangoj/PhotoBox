#if DEBUG
import Foundation
import UIKit

actor UITestPhotoLibraryService: PhotoLibraryReading {
    enum Fixture: Sendable, Equatable {
        case completed
        case cancelled
        case failed
        case partial
        case media
        case comparison
        case decision
        case archive
        case deleteReview
        case deleteReviewLoadFailure
        case cleanupResultsProduction
        case queues
        case queuesLoading
        case queuesLoadFailure
        case statistics
        case statisticsHistory
        case statisticsLoading
        case weeklyWork
        case weeklyEmpty
        case weeklyOverLimit
        case fullFlow
    }

    private var authorization: PhotoAuthorization
    private let requestedAuthorization: PhotoAuthorization
    private let authorizationStatusDelay: Duration?
    private let fixture: Fixture
    private var descriptorRequestCount = 0

    init(
        authorization: PhotoAuthorization,
        requestedAuthorization: PhotoAuthorization? = nil,
        authorizationStatusDelay: Duration? = nil,
        fixture: Fixture = .completed
    ) {
        self.authorization = authorization
        self.requestedAuthorization = requestedAuthorization ?? authorization
        self.authorizationStatusDelay = authorizationStatusDelay
        self.fixture = fixture
    }

    func authorizationStatus() async -> PhotoAuthorization {
        if let authorizationStatusDelay {
            try? await Task.sleep(for: authorizationStatusDelay)
        }
        return authorization
    }

    func requestAuthorization() -> PhotoAuthorization {
        authorization = requestedAuthorization
        return authorization
    }

    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> {
        return AsyncStream { continuation in
            continuation.yield(Self.snapshot(for: fixture))
            continuation.finish()
        }
    }

    func thumbnail(for assetID: String, maxPixelSize: Int) async -> PhotoThumbnail? {
        guard fixture == .media || fixture == .comparison || fixture == .decision || fixture == .archive || fixture == .deleteReview || fixture == .deleteReviewLoadFailure || fixture == .cleanupResultsProduction || fixture == .queues || fixture == .weeklyWork || fixture == .fullFlow else {
            return nil
        }
        if assetID == "media-loading-video" {
            try? await Task.sleep(for: .seconds(5))
        }
        guard assetID != "media-unavailable" else { return nil }
        if fixture == .decision || fixture == .archive {
            let names = ["HomeFixtureLake", "HomeFixtureField", "HomeFixtureSunset", "HomeFixtureCoffee"]
            let index = assetID.unicodeScalars.reduce(0) { $0 + Int($1.value) } % names.count
            return await MainActor.run {
                guard let image = UIImage(named: names[index]),
                      let data = image.jpegData(compressionQuality: 0.9) else { return nil }
                return PhotoThumbnail(assetID: assetID, data: data,
                                      pixelWidth: Int(image.size.width), pixelHeight: Int(image.size.height))
            }
        }
        return PhotoThumbnail(
            assetID: assetID,
            data: Data(assetID.utf8),
            pixelWidth: maxPixelSize,
            pixelHeight: maxPixelSize
        )
    }

    func accessibleAssetDescriptors() async throws -> [PhotoAssetDescriptor] {
        descriptorRequestCount += 1
        if fixture == .fullFlow {
            // Keep the real scan in its observable reading state long enough
            // for the one-launch UI flow to assert the permission handoff.
            try? await Task.sleep(for: .seconds(2))
            return Self.fullFlowDescriptors
        }
        switch fixture {
        case .decision: return Self.decisionDescriptors
        case .archive: return Self.archiveDescriptors
        case .deleteReview: return Self.deleteReviewDescriptors
        case .deleteReviewLoadFailure:
            if descriptorRequestCount == 1 {
                throw PhotoLibraryReadError.scopeUnavailable
            }
            return Self.deleteReviewDescriptors
        case .cleanupResultsProduction: return Self.cleanupResultsProductionDescriptors
        case .queues: return Self.queueDescriptors
        case .queuesLoading:
            try await Task.sleep(for: .seconds(60))
            return []
        case .queuesLoadFailure:
            if descriptorRequestCount == 1 {
                throw PhotoLibraryReadError.scopeUnavailable
            }
            return []
        case .statisticsHistory, .statisticsLoading:
            return Self.statisticsDescriptors
        case .statistics:
            return [Self.mediaDescriptor(
                id: "statistics-keep",
                availability: .iCloudOnly
            )]
        case .weeklyWork: return Self.weeklyWorkDescriptors
        case .weeklyEmpty: return []
        case .weeklyOverLimit: return [Self.mediaDescriptor(id: "weekly-over-limit")]
        case .fullFlow: return Self.fullFlowDescriptors
        default: return []
        }
    }

    nonisolated static func snapshot(for fixture: Fixture) -> LibraryScanSnapshot {
        var snapshot = LibraryScanSnapshot.idle
        switch fixture {
        case .completed:
            snapshot.phase = .completed
        case .cancelled:
            snapshot.phase = .cancelled
            snapshot.discoveredCount = 8
            snapshot.processedCount = 3
            snapshot.localCount = 2
            snapshot.iCloudOnlyCount = 1
        case .failed:
            snapshot.phase = .failed
            snapshot.errorMessage = "当前可访问范围暂时无法读取，请稍后重试。"
        case .partial:
            snapshot.phase = .checkingLocalAvailability
            snapshot.discoveredCount = 8
            snapshot.processedCount = 3
            snapshot.localCount = 2
            snapshot.iCloudOnlyCount = 1
        case .statistics, .statisticsHistory:
            snapshot.phase = .completed
            snapshot.discoveredCount = 1
            snapshot.processedCount = 1
            snapshot.iCloudOnlyCount = 1
        case .statisticsLoading:
            snapshot.phase = .cancelled
        case .media:
            snapshot.phase = .completed
        case .comparison:
            snapshot.phase = .completed
        case .decision:
            snapshot.phase = .completed
        case .archive:
            snapshot.phase = .completed
        case .deleteReview:
            snapshot.phase = .completed
        case .deleteReviewLoadFailure:
            snapshot.phase = .cancelled
        case .cleanupResultsProduction:
            snapshot.phase = .completed
        case .queues:
            snapshot.phase = .completed
        case .queuesLoading, .queuesLoadFailure:
            snapshot.phase = .cancelled
        case .weeklyWork, .weeklyEmpty, .weeklyOverLimit, .fullFlow:
            snapshot.phase = .completed
        }
        return snapshot
    }

    nonisolated static let mediaPages = [
        MediaPage(descriptor: mediaDescriptor(id: "media-loading-video", type: .video)),
        MediaPage(descriptor: mediaDescriptor(id: "media-unavailable", availability: .unavailable)),
        MediaPage(descriptor: mediaDescriptor(id: "media-live", type: .livePhoto)),
        MediaPage(descriptor: mediaDescriptor(id: "media-panorama", type: .panorama)),
        MediaPage(descriptor: mediaDescriptor(id: "media-favorite", isFavorite: true)),
        MediaPage(descriptor: mediaDescriptor(id: "media-edited", isEdited: true)),
        MediaPage(descriptor: mediaDescriptor(id: "media-protected"), isManuallyProtected: true)
    ]

    nonisolated static let comparisonGroups = [
        PhotoCandidateGroup(
            id: "comparison-confident",
            kind: .similar,
            candidates: [
                comparisonCandidate(id: "comparison-recommended", bytes: 8_000_000, sharpness: 0.95),
                comparisonCandidate(id: "comparison-chosen", bytes: 5_000_000, sharpness: 0.30),
                comparisonCandidate(
                    id: "comparison-protected",
                    bytes: 3_000_000,
                    sharpness: 0.20,
                    manualProtection: true,
                    isFavorite: true
                )
            ]
        ),
        PhotoCandidateGroup(
            id: "comparison-low-confidence",
            kind: .burst,
            candidates: [
                comparisonCandidate(id: "comparison-low-first", bytes: 2_000_000, sharpness: 0.70),
                comparisonCandidate(id: "comparison-low-second", bytes: 1_000_000, sharpness: 0.69)
            ]
        )
    ]

    nonisolated static let comparisonRecommendations = [
        PhotoGroupRecommendation(
            groupID: "comparison-confident",
            recommendedKeepID: "comparison-recommended",
            reasons: [.sharper],
            confidence: 0.9
        ),
        PhotoGroupRecommendation(
            groupID: "comparison-low-confidence",
            recommendedKeepID: nil,
            reasons: [],
            confidence: 0
        )
    ]

    nonisolated static let decisionDescriptors = [
        mediaDescriptor(id: "decision-first"),
        mediaDescriptor(id: "decision-second"),
        mediaDescriptor(id: "decision-third", isFavorite: true),
        mediaDescriptor(id: "decision-fourth", isEdited: true),
        mediaDescriptor(id: "decision-fifth", availability: .unavailable)
    ]

    nonisolated static let archiveDescriptors = [
        mediaDescriptor(id: "archive-first"),
        mediaDescriptor(id: "archive-next")
    ]

    nonisolated static let queueDescriptors = [
        mediaDescriptor(id: "queue-later", isEdited: true),
        mediaDescriptor(id: "queue-protected", isFavorite: true)
    ]

    nonisolated static let statisticsDescriptors = [
        mediaDescriptor(id: "statistics-keep", availability: .iCloudOnly),
        mediaDescriptor(id: "statistics-archive"),
        mediaDescriptor(id: "statistics-protect"),
        mediaDescriptor(id: "statistics-later"),
        mediaDescriptor(id: "statistics-delete")
    ]

    nonisolated static let deleteReviewDescriptors = [
        mediaDescriptor(id: "delete-review-removed", isFavorite: true),
        mediaDescriptor(id: "delete-review-remaining", isEdited: true),
        mediaDescriptor(id: "delete-review-protected")
    ]

    nonisolated static let cleanupResultsProductionDescriptors = [
        mediaDescriptor(id: "production-removed"),
        mediaDescriptor(id: "production-succeeded"),
        mediaDescriptor(id: "production-retry"),
        mediaDescriptor(id: "production-stale")
    ]

    nonisolated static var weeklyWorkDescriptors: [PhotoAssetDescriptor] {
        let now = Date()
        return [
            PhotoAssetDescriptor(
                id: "weekly-expired",
                mediaType: .photo,
                creationDate: now.addingTimeInterval(-40 * 86_400),
                pixelWidth: 1_200,
                pixelHeight: 900,
                duration: 0,
                estimatedBytes: 2_000,
                isFavorite: false,
                isEdited: false,
                isScreenshot: true,
                burstIdentifier: nil,
                availability: .local
            ),
            mediaDescriptor(id: "weekly-new", creationDate: now),
            mediaDescriptor(id: "weekly-deferred", creationDate: now.addingTimeInterval(-20 * 86_400))
        ]
    }

    nonisolated static let fullFlowDescriptors: [PhotoAssetDescriptor] = [
        mediaDescriptor(id: "full-flow-comparison-keep"),
        mediaDescriptor(id: "full-flow-comparison-delete"),
        mediaDescriptor(id: "full-flow-keep"),
        mediaDescriptor(id: "full-flow-delete"),
        mediaDescriptor(id: "full-flow-archive"),
        mediaDescriptor(id: "full-flow-protect", isFavorite: true),
        mediaDescriptor(id: "full-flow-later")
    ]

    private nonisolated static func mediaDescriptor(
        id: String,
        type: PhotoMediaType = .photo,
        isFavorite: Bool = false,
        isEdited: Bool = false,
        availability: AssetAvailability = .local,
        creationDate: Date = Date(timeIntervalSince1970: 1_000)
    ) -> PhotoAssetDescriptor {
        PhotoAssetDescriptor(
            id: id,
            mediaType: type,
            creationDate: creationDate,
            pixelWidth: 1_200,
            pixelHeight: 900,
            duration: type == .video ? 12 : 0,
            estimatedBytes: 1_000,
            isFavorite: isFavorite,
            isEdited: isEdited,
            isScreenshot: false,
            burstIdentifier: nil,
            availability: availability
        )
    }

    private nonisolated static func comparisonCandidate(
        id: String,
        bytes: Int64,
        sharpness: Double,
        manualProtection: Bool = false,
        isFavorite: Bool = false
    ) -> PhotoCandidate {
        PhotoCandidate(
            asset: PhotoAssetDescriptor(
                id: id,
                mediaType: .photo,
                creationDate: Date(timeIntervalSince1970: 1_000),
                pixelWidth: 1_200,
                pixelHeight: 900,
                duration: 0,
                estimatedBytes: bytes,
                isFavorite: isFavorite,
                isEdited: false,
                isScreenshot: false,
                burstIdentifier: nil,
                availability: .local
            ),
            quality: PhotoQualitySignals(
                sharpness: sharpness,
                exposure: 0.8,
                completeness: 0.8
            ),
            manualProtection: manualProtection
        )
    }
}

actor UITestRecordingDeleteMutator: PhotoLibraryMutating {
    let backendMode = MutationBackendMode.simulated
    private let simulated: SimulatedPhotoLibraryMutator
    private var deleteCallCount = 0
    private var deleteCallReadCount = 0
    private var submittedDeleteAssetIDs: [String] = []
    private var lastSubmittedDeleteAssetIDs: [String] = []
    private let subsequentOutcomes: [String: MutationItemState]

    init(
        assetIDs: Set<String>,
        albums: [PhotoAlbumDescriptor] = [],
        configuredOutcomes: [String: MutationItemState] = [:],
        subsequentOutcomes: [String: MutationItemState] = [:]
    ) {
        simulated = SimulatedPhotoLibraryMutator(
            assetIDs: assetIDs,
            albums: albums,
            configuredOutcomes: configuredOutcomes
        )
        self.subsequentOutcomes = subsequentOutcomes
    }

    func availableAssetIDs(for requestedIDs: [String]) async -> Set<String> {
        await simulated.availableAssetIDs(for: requestedIDs)
    }

    func listAlbums() async -> [PhotoAlbumDescriptor] { await simulated.listAlbums() }
    func createAlbum(named title: String) async -> PhotoAlbumDescriptor? {
        await simulated.createAlbum(named: title)
    }
    func archivedAssetIDs(for requestedIDs: [String], inAlbumID albumID: String) async -> Set<String> {
        await simulated.archivedAssetIDs(for: requestedIDs, inAlbumID: albumID)
    }
    func addAssets(withIDs assetIDs: [String], toAlbumID albumID: String) async -> PhotoMutationBatch {
        await simulated.addAssets(withIDs: assetIDs, toAlbumID: albumID)
    }
    func deleteAssets(withIDs assetIDs: [String]) async -> PhotoMutationBatch {
        deleteCallCount += 1
        submittedDeleteAssetIDs.append(contentsOf: assetIDs)
        lastSubmittedDeleteAssetIDs = assetIDs
        let result = await simulated.deleteAssets(withIDs: assetIDs)
        if deleteCallCount == 1 {
            for (assetID, outcome) in subsequentOutcomes {
                await simulated.setOutcome(outcome, for: assetID)
            }
        }
        return result
    }
    func recordedDeleteCallCount() -> Int {
        deleteCallReadCount += 1
        return deleteCallCount
    }
    func recordedDeleteCallReadCount() -> Int { deleteCallReadCount }
    func recordedDeleteAssetIDs() -> [String] { submittedDeleteAssetIDs }
    func recordedLastDeleteAssetIDs() -> [String] { lastSubmittedDeleteAssetIDs }
}

actor UITestStatisticsInventoryMutator: PhotoLibraryMutating {
    let backendMode = MutationBackendMode.simulated
    private let simulated: SimulatedPhotoLibraryMutator
    private var inventoryReadCount = 0

    init(assetIDs: Set<String>, albums: [PhotoAlbumDescriptor]) {
        simulated = SimulatedPhotoLibraryMutator(assetIDs: assetIDs, albums: albums)
    }

    func availableAssetIDs(for requestedIDs: [String]) async -> Set<String> {
        await simulated.availableAssetIDs(for: requestedIDs)
    }

    func listAlbums() async -> [PhotoAlbumDescriptor] { await simulated.listAlbums() }
    func createAlbum(named title: String) async -> PhotoAlbumDescriptor? {
        await simulated.createAlbum(named: title)
    }
    func archivedAssetIDs(for requestedIDs: [String], inAlbumID albumID: String) async -> Set<String> {
        await simulated.archivedAssetIDs(for: requestedIDs, inAlbumID: albumID)
    }
    func addAssets(withIDs assetIDs: [String], toAlbumID albumID: String) async -> PhotoMutationBatch {
        await simulated.addAssets(withIDs: assetIDs, toAlbumID: albumID)
    }
    func deleteAssets(withIDs assetIDs: [String]) async -> PhotoMutationBatch {
        await simulated.deleteAssets(withIDs: assetIDs)
    }

    func inventoryFingerprint() async -> String {
        inventoryReadCount += 1
        return await simulated.inventoryFingerprint() + "|inventoryReads=\(inventoryReadCount)"
    }
}
#endif
