#if DEBUG
import Foundation
import UIKit

enum AlbumHomeUITestFixture {
    @MainActor
    static func makeModel(arguments: [String]) -> AppModel {
        let reader = AlbumFixtureReader(arguments: arguments)
        let repository = try! SwiftDataTaskRepository(inMemory: true)
        var settings = WorkflowSettings.defaults
        settings.recentAlbumIDs = ["travel"]
        try! repository.save(settings: settings)
        let model = AppModel(
            library: reader, repository: repository,
            mutator: SimulatedPhotoLibraryMutator(albumCreationFails: arguments.contains("--ui-testing-albums-create-failure")),
            initialScan: UITestPhotoLibraryService.snapshot(for: .completed),
            initialInventory: LibraryInventory()
        )
        model.authorization = arguments.contains("--ui-testing-albums-limited") ? .limited : .authorized
        model.hasLoadedAuthorization = true
        return model
    }
}

private actor AlbumFixtureReader: PhotoLibraryReading {
    private let arguments: [String]
    private var directoryRequests = 0
    private var memberRequests = 0
    private var scopeReduced = false
    private var scopeChangeScheduled = false
    private let changes = AsyncStream<PhotoLibraryChange>.makeStream()

    init(arguments: [String]) { self.arguments = arguments }
    func authorizationStatus() -> PhotoAuthorization {
        scopeReduced || arguments.contains("--ui-testing-albums-limited") ? .limited : .authorized
    }
    func requestAuthorization() -> PhotoAuthorization { authorizationStatus() }
    func libraryChanges() -> AsyncStream<PhotoLibraryChange> { changes.stream }

    func albumCollections() async throws -> [PhotoCollectionDescriptor] {
        directoryRequests += 1
        if arguments.contains("--ui-testing-albums-loading") {
            try await Task.sleep(for: .seconds(30))
        }
        if arguments.contains("--ui-testing-albums-failure"), directoryRequests == 1 {
            throw AlbumFixtureError.readFailed
        }
        if arguments.contains("--ui-testing-albums-empty") { return [] }
        if scopeReduced {
            return [.init(id: "travel", kind: .album, title: "加州旅行 2026", assetCount: 1, coverAssetID: "lake")]
        }
        return [
            .init(id: "favorites", kind: .favorites, title: "收藏", assetCount: 2, coverAssetID: "lake"),
            .init(id: "personal", kind: .album, title: "个人精选", assetCount: 4, coverAssetID: "sunset"),
            .init(id: "travel", kind: .album, title: "加州旅行 2026", assetCount: 4, coverAssetID: "lake"),
            .init(id: "portfolio", kind: .album, title: "摄影作品集", assetCount: 2, coverAssetID: "field"),
            .init(id: "inspiration", kind: .album, title: "日常灵感与值得收藏的生活片段", assetCount: 1, coverAssetID: "coffee"),
            .init(id: "empty", kind: .album, title: "空相册", assetCount: 0, coverAssetID: nil),
            .init(id: "cloud", kind: .album, title: "云端回忆", assetCount: 1, coverAssetID: "cloud")
        ]
    }

    func assets(inCollection id: String) async throws -> [PhotoAssetDescriptor] {
        memberRequests += 1
        if arguments.contains("--ui-testing-albums-content-failure"), memberRequests == 1 {
            throw PhotoLibraryReadError.collectionUnavailable
        }
        if arguments.contains("--ui-testing-albums-scope-change"), !scopeChangeScheduled {
            scopeChangeScheduled = true
            Task {
                try? await Task.sleep(for: .seconds(8))
                scopeReduced = true
                changes.continuation.yield(PhotoLibraryChange(addedAssetIDs: [], removedAssetIDs: [], scopeChanged: true))
            }
        }
        let fullScopeIDs: [String] = switch id {
        case "empty": []
        case "favorites": ["lake", "sunset"]
        case "portfolio": ["field", "sunset"]
        case "inspiration": ["coffee"]
        case "cloud": ["cloud"]
        default: ["lake", "field", "sunset", "cloud"]
        }
        let ids = scopeReduced ? ["lake"] : fullScopeIDs
        return ids.map { assetID in
            PhotoAssetDescriptor(
                id: assetID, mediaType: assetID == "cloud" ? .video : .photo,
                creationDate: Date(timeIntervalSince1970: 1_789_344_000),
                pixelWidth: 1200, pixelHeight: 900, duration: assetID == "cloud" ? 42 : 0,
                estimatedBytes: 1_000, isFavorite: assetID == "lake", isEdited: false,
                isScreenshot: false, burstIdentifier: nil,
                availability: assetID == "cloud" ? .iCloudOnly : .local
            )
        }
    }

    func thumbnail(for assetID: String, maxPixelSize: Int) async -> PhotoThumbnail? {
        let name: String
        switch assetID {
        case "lake": name = "HomeFixtureLake"
        case "field": name = "HomeFixtureField"
        case "sunset": name = "HomeFixtureSunset"
        case "coffee": name = "HomeFixtureCoffee"
        default: return nil
        }
        return await MainActor.run {
            guard let image = UIImage(named: name), let data = image.jpegData(compressionQuality: 0.9) else { return nil }
            return PhotoThumbnail(assetID: assetID, data: data, pixelWidth: Int(image.size.width), pixelHeight: Int(image.size.height))
        }
    }

    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> {
        AsyncStream { $0.finish() }
    }
}

private enum AlbumFixtureError: LocalizedError {
    case readFailed
    var errorDescription: String? { "暂时无法读取相册" }
}
#endif
