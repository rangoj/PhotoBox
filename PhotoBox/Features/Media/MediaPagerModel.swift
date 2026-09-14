import Foundation
import Observation

nonisolated struct MediaPage: Identifiable, Equatable, Sendable {
    let descriptor: PhotoAssetDescriptor
    let isManuallyProtected: Bool

    init(descriptor: PhotoAssetDescriptor, isManuallyProtected: Bool = false) {
        self.descriptor = descriptor
        self.isManuallyProtected = isManuallyProtected
    }

    var id: String { descriptor.id }
}

nonisolated enum MediaThumbnailState: Equatable, Sendable {
    case loading
    case loaded(PhotoThumbnail)
    case unavailable
}

@MainActor
@Observable
final class MediaPagerModel {
    let pages: [MediaPage]
    private let loader: BoundedThumbnailLoader

    private(set) var currentIndex = 0
    private(set) var thumbnailState: MediaThumbnailState = .loading

    @ObservationIgnored
    private var requestTask: Task<Void, Never>?

    @ObservationIgnored
    private var requestGeneration = 0

    init(pages: [MediaPage], loader: BoundedThumbnailLoader) {
        self.pages = pages
        self.loader = loader
    }

    deinit {
        requestTask?.cancel()
    }

    var currentPage: MediaPage? {
        pages.indices.contains(currentIndex) ? pages[currentIndex] : nil
    }

    func loadCurrentPage() {
        requestTask?.cancel()
        requestGeneration += 1
        let generation = requestGeneration
        guard let page = currentPage else {
            thumbnailState = .unavailable
            return
        }

        thumbnailState = .loading
        let assetID = page.id
        requestTask = Task { [weak self, loader] in
            let thumbnail = await loader.load(assetIDs: [assetID], maxPixelSize: 1_024).first
            guard !Task.isCancelled,
                  let self,
                  self.requestGeneration == generation,
                  self.currentPage?.id == assetID else { return }
            self.thumbnailState = thumbnail.map(MediaThumbnailState.loaded) ?? .unavailable
        }
    }

    func selectPage(at index: Int) {
        guard pages.indices.contains(index), index != currentIndex else { return }
        currentIndex = index
        loadCurrentPage()
    }

    func showPreviousPage() {
        selectPage(at: currentIndex - 1)
    }

    func showNextPage() {
        selectPage(at: currentIndex + 1)
    }

    func cancelLoading() {
        requestTask?.cancel()
        requestTask = nil
        requestGeneration += 1
    }
}
