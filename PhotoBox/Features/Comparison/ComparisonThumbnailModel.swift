import Observation

@MainActor
@Observable
final class ComparisonThumbnailModel {
    private let loader: BoundedThumbnailLoader

    private(set) var thumbnailStates: [String: MediaThumbnailState] = [:]

    @ObservationIgnored
    private var loadTask: Task<Void, Never>?

    @ObservationIgnored
    private var requestGeneration = 0

    init(loader: BoundedThumbnailLoader) {
        self.loader = loader
    }

    func state(for assetID: String) -> MediaThumbnailState {
        thumbnailStates[assetID] ?? .loading
    }

    func load(pages: [MediaPage]) {
        cancelLoading()
        let generation = requestGeneration
        thumbnailStates = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, .loading) })
        let assetIDs = pages.map(\.id)
        loadTask = Task { [weak self, loader] in
            let thumbnails = await loader.load(assetIDs: assetIDs, maxPixelSize: 512)
            guard !Task.isCancelled,
                  let self,
                  self.requestGeneration == generation else { return }
            let thumbnailsByID = Dictionary(uniqueKeysWithValues: thumbnails.map { ($0.assetID, $0) })
            self.thumbnailStates = Dictionary(uniqueKeysWithValues: assetIDs.map { assetID in
                (assetID, thumbnailsByID[assetID].map(MediaThumbnailState.loaded) ?? .unavailable)
            })
        }
    }

    func cancelLoading() {
        loadTask?.cancel()
        loadTask = nil
        requestGeneration += 1
    }
}
