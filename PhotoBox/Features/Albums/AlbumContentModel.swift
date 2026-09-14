import Foundation
import Observation

@MainActor
@Observable
final class AlbumContentModel {
    let collection: PhotoCollectionDescriptor
    private let library: any PhotoLibraryReading
    private let isSimulated: Bool
    private var generation = 0
    private(set) var assets: [PhotoAssetDescriptor] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    init(collection: PhotoCollectionDescriptor, library: any PhotoLibraryReading, isSimulated: Bool = false) {
        self.collection = collection
        self.library = library
        self.isSimulated = isSimulated
    }

    func load() async {
        generation += 1
        let requestGeneration = generation
        isLoading = true
        assets = []
        errorMessage = nil
        defer {
            if requestGeneration == generation { isLoading = false }
        }
        let authorization = await library.authorizationStatus()
        guard requestGeneration == generation, !Task.isCancelled else { return }
        guard authorization.canReadLibrary else {
            errorMessage = "无法访问照片，请检查照片权限。"
            return
        }
        guard !isSimulated else { return }
        do {
            let members = try await library.assets(inCollection: collection.id)
            let currentAuthorization = await library.authorizationStatus()
            guard requestGeneration == generation, !Task.isCancelled else { return }
            guard currentAuthorization == authorization else {
                errorMessage = "照片访问权限已变化，请刷新相册。"
                return
            }
            assets = members
        } catch {
            guard requestGeneration == generation, !Task.isCancelled else { return }
            errorMessage = (error as? PhotoLibraryReadError)?.message ?? "无法读取相册内容，请重试。"
        }
    }

    func invalidate() {
        generation += 1
        assets = []
        isLoading = false
        errorMessage = nil
    }
}
