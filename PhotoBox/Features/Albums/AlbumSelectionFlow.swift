import Foundation
import Observation

@MainActor
@Observable
final class AlbumSelectionFlow {
    let assetID: String

    private let taskID: String?
    private let estimatedBytes: Int64
    private let repository: any TaskRepository
    private var mutator: any PhotoLibraryMutating
    private var coordinator: MutationCoordinator
    private let onArchiveSucceeded: ((PhotoDecision) -> Void)?
    private let onSelectionSucceeded: (() -> Void)?

    private(set) var recentAlbums: [PhotoAlbumDescriptor] = []
    private(set) var systemAlbums: [PhotoAlbumDescriptor] = []
    private(set) var isLoading = false
    private(set) var isArchiving = false
    private(set) var isCreatingAlbum = false
    private(set) var requiresReselection = false
    private(set) var errorGuidance: String?
    private(set) var hasCompletedArchive = false
    private(set) var selectedAlbumIDs: Set<String> = []
    private(set) var existingAlbumIDs: Set<String> = []

    init(
        assetID: String,
        taskID: String?,
        estimatedBytes: Int64,
        repository: any TaskRepository,
        mutator: any PhotoLibraryMutating,
        onArchiveSucceeded: ((PhotoDecision) -> Void)? = nil,
        onSelectionSucceeded: (() -> Void)? = nil
    ) {
        self.assetID = assetID
        self.taskID = taskID
        self.estimatedBytes = estimatedBytes
        self.repository = repository
        self.mutator = mutator
        self.coordinator = MutationCoordinator(repository: repository, mutator: mutator)
        self.onArchiveSucceeded = onArchiveSucceeded
        self.onSelectionSucceeded = onSelectionSucceeded
    }

    func loadAlbums() async {
        await refreshAlbums(clearingRecovery: true)
    }

    func selectAlbum(id albumID: String) async {
        guard !isArchiving, !isCreatingAlbum, !hasCompletedArchive else { return }
        guard allAlbums.contains(where: { $0.id == albumID }) else {
            await showMissingTargetRecovery()
            return
        }
        isArchiving = true
        defer { isArchiving = false }
        await archive(to: albumID)
    }

    var canSubmitSelection: Bool {
        !selectedAlbumIDs.isEmpty && !isArchiving && !isCreatingAlbum && !hasCompletedArchive
    }

    var selectedAlbumCount: Int { selectedAlbumIDs.count }

    func toggleAlbumSelection(id albumID: String) {
        guard !isArchiving, !isCreatingAlbum, !hasCompletedArchive,
              !existingAlbumIDs.contains(albumID),
              allAlbums.contains(where: { $0.id == albumID }) else { return }
        if !selectedAlbumIDs.insert(albumID).inserted {
            selectedAlbumIDs.remove(albumID)
        }
    }

    /// Selects an album for the inline add flow. Repeated calls are idempotent;
    /// use `toggleAlbumSelection` for the legacy toggle interaction.
    func selectAlbumForAddition(id albumID: String) {
        guard !isArchiving, !isCreatingAlbum, !hasCompletedArchive,
              !existingAlbumIDs.contains(albumID),
              allAlbums.contains(where: { $0.id == albumID }) else { return }
        selectedAlbumIDs.insert(albumID)
    }

    func submitSelectedAlbums() async {
        guard canSubmitSelection else { return }
        let selected = allAlbums.filter { selectedAlbumIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        isArchiving = true
        var completed = false
        defer {
            isArchiving = false
            if completed { onSelectionSucceeded?() }
        }

        for album in selected where !existingAlbumIDs.contains(album.id) {
            guard await archive(to: album.id, notifyCompletion: false, recordDecision: false) else {
                return
            }
        }
        guard selectedAlbumIDs.isEmpty else { return }
        completed = true
    }

    func createAndArchive(named name: String) async {
        guard !isArchiving, !isCreatingAlbum, !hasCompletedArchive else { return }
        isArchiving = true
        defer { isArchiving = false }
        guard let albumID = await createAlbum(named: name, allowWhileArchiving: true) else { return }
        await archive(to: albumID)
    }

    func createAlbum(named name: String) async -> String? {
        await createAlbum(named: name, allowWhileArchiving: false)
    }

    private func createAlbum(named name: String, allowWhileArchiving: Bool) async -> String? {
        guard (allowWhileArchiving || !isArchiving), !isCreatingAlbum, !hasCompletedArchive else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorGuidance = "请输入相册名称。"
            return nil
        }
        isCreatingAlbum = true
        defer { isCreatingAlbum = false }
        do {
            guard let album = try await coordinator.createAlbum(named: trimmed, forAssetID: assetID) else {
                errorGuidance = "无法创建相册，请稍后重试。"
                return nil
            }
            if !allAlbums.contains(where: { $0.id == album.id }) {
                systemAlbums.append(album)
                systemAlbums.sort(by: Self.albumOrder)
            }
            return album.id
        } catch {
            errorGuidance = "无法保存相册创建进度，请稍后重试。"
            return nil
        }
    }

    func reselectAlbum() async {
        await refreshAlbums(clearingRecovery: true)
    }

    func replaceMutator(_ mutator: any PhotoLibraryMutating) {
        self.mutator = mutator
        coordinator = MutationCoordinator(repository: repository, mutator: mutator)
    }

    private var allAlbums: [PhotoAlbumDescriptor] {
        recentAlbums + systemAlbums
    }

    @discardableResult
    private func archive(
        to albumID: String,
        notifyCompletion: Bool = true,
        recordDecision: Bool = true
    ) async -> Bool {
        do {
            let recentAlbumIDs = try promotedRecentAlbumIDs(for: albumID)
            let decision = PhotoDecision(
                assetID: assetID,
                kind: .archive,
                estimatedBytes: estimatedBytes,
                targetAlbumID: albumID,
                taskID: taskID,
                isSubmitted: true
            )
            let transaction = if recordDecision {
                try await coordinator.submitArchive(
                    decision: decision,
                    recentAlbumIDs: recentAlbumIDs
                )
            } else {
                try await coordinator.submitArchiveTarget(
                    assetID: assetID,
                    targetAlbumID: albumID,
                    recentAlbumIDs: recentAlbumIDs
                )
            }
            if transaction.items.contains(where: { $0.assetID == assetID && $0.state == .succeeded }) {
                if notifyCompletion { hasCompletedArchive = true }
                existingAlbumIDs.insert(albumID)
                if !recordDecision { selectedAlbumIDs.remove(albumID) }
                requiresReselection = false
                errorGuidance = nil
                if notifyCompletion { onArchiveSucceeded?(decision) }
                return true
            }

            let state = transaction.items.first(where: { $0.assetID == assetID })?.state
            await refreshAlbums(clearingRecovery: false)
            if !allAlbums.contains(where: { $0.id == albumID }) {
                selectedAlbumIDs.remove(albumID)
                setMissingTargetRecovery()
            } else {
                requiresReselection = true
                errorGuidance = switch state {
                case .cancelled:
                    "归档已取消，照片仍保留，请重新选择相册。"
                case .stale:
                    "归档未完成，照片仍保留，请重新选择相册后重试。"
                default:
                    "无法归档到所选相册，照片仍保留，请重新选择。"
                }
            }
            return false
        } catch {
            errorGuidance = "无法保存归档结果，请稍后重试。"
            return false
        }
    }

    private func promotedRecentAlbumIDs(for albumID: String) throws -> [String] {
        let recentAlbumIDs = try repository.settings().recentAlbumIDs
        let accessibleIDs = Set(allAlbums.map(\.id))
        var seen: Set<String> = [albumID]
        let prior = recentAlbumIDs.filter {
            accessibleIDs.contains($0) && seen.insert($0).inserted
        }
        return Array(([albumID] + prior).prefix(5))
    }

    private func showMissingTargetRecovery() async {
        await refreshAlbums(clearingRecovery: false)
        setMissingTargetRecovery()
    }

    private func setMissingTargetRecovery() {
        requiresReselection = true
        errorGuidance = "所选相册已不可用，请重新选择其他相册。"
    }

    private func refreshAlbums(clearingRecovery: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let albums = await mutator.listAlbums()
        do {
            let recentIDs = try repository.settings().recentAlbumIDs
            applyPresentation(albums: albums, recentIDs: recentIDs)
            var existing: Set<String> = []
            for album in allAlbums {
                if (await mutator.archivedAssetIDs(for: [assetID], inAlbumID: album.id)).contains(assetID) {
                    existing.insert(album.id)
                }
            }
            existingAlbumIDs = existing
            if clearingRecovery {
                requiresReselection = false
                errorGuidance = nil
            }
        } catch {
            errorGuidance = "无法读取最近使用的相册，请稍后重试。"
        }
    }

    private func applyPresentation(albums: [PhotoAlbumDescriptor], recentIDs: [String]) {
        let albumsByID = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) })
        var seen: Set<String> = []
        recentAlbums = recentIDs.compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return albumsByID[id]
        }
        let recentSet = Set(recentAlbums.map(\.id))
        systemAlbums = albums
            .filter { !recentSet.contains($0.id) }
            .sorted(by: Self.albumOrder)
    }

    private static func albumOrder(_ first: PhotoAlbumDescriptor, _ second: PhotoAlbumDescriptor) -> Bool {
        let comparison = first.title.localizedStandardCompare(second.title)
        return comparison == .orderedSame ? first.id < second.id : comparison == .orderedAscending
    }
}
