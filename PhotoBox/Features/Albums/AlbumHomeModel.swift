import Foundation
import Observation

@MainActor
@Observable
final class AlbumHomeModel {
    private let library: any PhotoLibraryReading
    private var mutator: any PhotoLibraryMutating
    private let recentAlbumIDs: @MainActor () throws -> [String]
    private var directory: [PhotoCollectionDescriptor] = []
    private var createdAlbums: [String: PhotoCollectionDescriptor] = [:]
    private var simulatedIDs: Set<String> = []
    private var lastAuthorization: PhotoAuthorization?
    private var loadGeneration = 0
    private var creationGeneration = 0
    private(set) var albums: [PhotoCollectionDescriptor] = []
    private(set) var quickAccess: [PhotoCollectionDescriptor] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    private(set) var isLimited = false
    var creationName = ""
    var isPresentingCreation = false
    private(set) var isCreating = false
    private(set) var creationError: String?
    private(set) var creationNeedsRefresh = false
    private(set) var notice: String?
    private(set) var revision = 0

    init(
        library: any PhotoLibraryReading,
        mutator: any PhotoLibraryMutating,
        recentAlbumIDs: @escaping @MainActor () throws -> [String] = { [] }
    ) {
        self.library = library
        self.mutator = mutator
        self.recentAlbumIDs = recentAlbumIDs
    }

    func load() async {
        _ = await refreshDirectory()
    }

    func invalidate() {
        loadGeneration += 1
        creationGeneration += 1
        clearSnapshots()
        isLoading = false
        errorMessage = nil
        isLimited = false
        lastAuthorization = nil
        notice = nil
        if isCreating { creationNeedsRefresh = true }
        revision += 1
    }

    func replaceMutator(_ mutator: any PhotoLibraryMutating) {
        self.mutator = mutator
        invalidate()
        creationError = nil
        creationNeedsRefresh = false
    }

    func beginCreation() {
        guard !isCreating else { return }
        if !creationNeedsRefresh {
            creationName = ""
            creationError = nil
        }
        isPresentingCreation = true
    }

    func cancelCreation() {
        guard !isCreating else { return }
        isPresentingCreation = false
        if !creationNeedsRefresh {
            creationName = ""
            creationError = nil
        }
    }

    func createAlbum() async {
        guard !isCreating, !creationNeedsRefresh else { return }
        let title = creationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            creationError = "请输入相册名称。"
            return
        }

        isCreating = true
        creationError = nil
        notice = nil
        let generation = creationGeneration
        let selectedMutator = mutator
        defer { isCreating = false }

        let authorization = await library.authorizationStatus()
        guard generation == creationGeneration, !Task.isCancelled else { return }
        guard authorization.canReadLibrary else {
            invalidate()
            creationNeedsRefresh = false
            creationError = "请允许访问照片后再创建相册。"
            errorMessage = "无法访问照片，请检查照片权限。"
            return
        }
        if let lastAuthorization, lastAuthorization != authorization {
            loadGeneration += 1
            clearSnapshots()
            isLoading = false
            creationNeedsRefresh = false
            creationError = nil
            revision += 1
        }
        lastAuthorization = authorization
        isLimited = authorization == .limited
        let mode = await selectedMutator.backendMode
        let currentAuthorization = await library.authorizationStatus()
        guard generation == creationGeneration, !Task.isCancelled else { return }
        guard currentAuthorization == authorization else {
            invalidate()
            creationNeedsRefresh = false
            creationError = "照片访问权限已变化，请刷新后重试。"
            return
        }

        let result = await selectedMutator.createAlbum(named: title)
        guard generation == creationGeneration else { return }
        guard !Task.isCancelled else {
            requireCreationRefresh()
            return
        }
        let resultAuthorization = await library.authorizationStatus()
        guard generation == creationGeneration else { return }
        guard !Task.isCancelled else {
            requireCreationRefresh()
            return
        }
        guard resultAuthorization == authorization else {
            invalidate()
            requireCreationRefresh()
            return
        }
        guard let result else {
            requireCreationRefresh()
            return
        }

        let collection = PhotoCollectionDescriptor(
            id: result.id, kind: .album, title: result.title, assetCount: 0, coverAssetID: nil
        )
        createdAlbums[collection.id] = collection
        if mode == .simulated { simulatedIDs.insert(collection.id) }
        publishProjection()
        revision += 1
        isPresentingCreation = false
        creationName = ""
        creationNeedsRefresh = false
        notice = mode == .simulated ? "已模拟创建相册，未修改系统照片。" : "相册已创建。"
        _ = await refreshDirectory()
    }

    func recoverCreation() async {
        guard !isCreating, creationNeedsRefresh else { return }
        if await refreshDirectory() {
            creationNeedsRefresh = false
            creationError = nil
            notice = "相册列表已刷新，请确认创建结果。"
        }
    }

    func collection(id: String) -> PhotoCollectionDescriptor? {
        albums.first { $0.id == id } ?? quickAccess.first { $0.id == id }
    }

    func isSimulatedCollection(id: String) -> Bool {
        simulatedIDs.contains(id)
    }

    private func refreshDirectory() async -> Bool {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        errorMessage = nil
        defer {
            if generation == loadGeneration { isLoading = false }
        }

        let authorization = await library.authorizationStatus()
        guard generation == loadGeneration, !Task.isCancelled else { return false }
        if let lastAuthorization, lastAuthorization != authorization {
            clearSnapshots()
            creationGeneration += 1
            revision += 1
        }
        lastAuthorization = authorization
        isLimited = authorization == .limited
        guard authorization.canReadLibrary else {
            clearSnapshots()
            revision += 1
            errorMessage = "无法访问照片，请检查照片权限。"
            return false
        }

        do {
            let collections = try await library.albumCollections()
            let currentAuthorization = await library.authorizationStatus()
            guard generation == loadGeneration, !Task.isCancelled else { return false }
            guard currentAuthorization == authorization else {
                clearSnapshots()
                creationGeneration += 1
                lastAuthorization = currentAuthorization
                isLimited = currentAuthorization == .limited
                revision += 1
                errorMessage = "照片访问权限已变化，请刷新相册。"
                return false
            }

            directory = collections
            // A complete system read is authoritative; simulated albums belong only to this session.
            createdAlbums = createdAlbums.filter { simulatedIDs.contains($0.key) }
            publishProjection()
            hasLoaded = true
            errorMessage = nil
            revision += 1
            return true
        } catch {
            let currentAuthorization = await library.authorizationStatus()
            guard generation == loadGeneration, !Task.isCancelled else { return false }
            if currentAuthorization != authorization || error as? PhotoLibraryReadError == .scopeUnavailable {
                clearSnapshots()
                creationGeneration += 1
                lastAuthorization = currentAuthorization
                isLimited = currentAuthorization == .limited
                revision += 1
            }
            errorMessage = (error as? PhotoLibraryReadError)?.message ?? "无法读取相册，请重试。"
            return false
        }
    }

    private func clearSnapshots() {
        directory = []
        createdAlbums = [:]
        simulatedIDs = []
        albums = []
        quickAccess = []
        hasLoaded = false
        notice = nil
        if isCreating { requireCreationRefresh() }
    }

    private func requireCreationRefresh() {
        creationNeedsRefresh = true
        creationError = "暂时无法确认创建结果，请先刷新相册列表。"
    }

    private func publishProjection() {
        var byID: [String: PhotoCollectionDescriptor] = [:]
        for collection in directory { byID[collection.id] = collection }
        for (id, collection) in createdAlbums where byID[id] == nil { byID[id] = collection }
        albums = byID.values.filter { $0.kind == .album }.sorted(by: Self.albumOrder)
        let favorites = byID.values.filter { $0.kind == .favorites }.sorted(by: Self.albumOrder)
        var recent: [PhotoCollectionDescriptor] = []
        var selectedIDs: Set<String> = []
        let regularByID = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) })
        for id in (try? recentAlbumIDs()) ?? [] {
            guard recent.count < 3, let album = regularByID[id], selectedIDs.insert(id).inserted else { continue }
            recent.append(album)
        }
        for album in albums where recent.count < 3 && selectedIDs.insert(album.id).inserted {
            recent.append(album)
        }
        quickAccess = favorites + recent
    }

    private static func albumOrder(_ lhs: PhotoCollectionDescriptor, _ rhs: PhotoCollectionDescriptor) -> Bool {
        let comparison = lhs.title.localizedStandardCompare(rhs.title)
        return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
    }
}
