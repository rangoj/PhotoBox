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

    private(set) var recentAlbums: [PhotoAlbumDescriptor] = []
    private(set) var systemAlbums: [PhotoAlbumDescriptor] = []
    private(set) var isLoading = false
    private(set) var isArchiving = false
    private(set) var requiresReselection = false
    private(set) var errorGuidance: String?
    private(set) var hasCompletedArchive = false

    init(
        assetID: String,
        taskID: String?,
        estimatedBytes: Int64,
        repository: any TaskRepository,
        mutator: any PhotoLibraryMutating,
        onArchiveSucceeded: ((PhotoDecision) -> Void)? = nil
    ) {
        self.assetID = assetID
        self.taskID = taskID
        self.estimatedBytes = estimatedBytes
        self.repository = repository
        self.mutator = mutator
        self.coordinator = MutationCoordinator(repository: repository, mutator: mutator)
        self.onArchiveSucceeded = onArchiveSucceeded
    }

    func loadAlbums() async {
        await refreshAlbums(clearingRecovery: true)
    }

    func selectAlbum(id albumID: String) async {
        guard !isArchiving, !hasCompletedArchive else { return }
        guard allAlbums.contains(where: { $0.id == albumID }) else {
            await showMissingTargetRecovery()
            return
        }
        isArchiving = true
        defer { isArchiving = false }
        await archive(to: albumID)
    }

    func createAndArchive(named name: String) async {
        guard !isArchiving, !hasCompletedArchive else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorGuidance = "请输入相册名称。"
            return
        }

        isArchiving = true
        defer { isArchiving = false }
        do {
            guard let album = try await coordinator.createAlbum(
                named: trimmed,
                forAssetID: assetID
            ) else {
                errorGuidance = "无法创建相册，请稍后重试。"
                return
            }
            if !allAlbums.contains(where: { $0.id == album.id }) {
                systemAlbums.append(album)
                systemAlbums.sort(by: Self.albumOrder)
            }
            await archive(to: album.id)
        } catch {
            errorGuidance = "无法保存相册创建进度，请稍后重试。"
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

    private func archive(to albumID: String) async {
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
            let transaction = try await coordinator.submitArchive(
                decision: decision,
                recentAlbumIDs: recentAlbumIDs
            )
            if transaction.items.contains(where: { $0.assetID == assetID && $0.state == .succeeded }) {
                hasCompletedArchive = true
                requiresReselection = false
                errorGuidance = nil
                onArchiveSucceeded?(decision)
                return
            }

            let state = transaction.items.first(where: { $0.assetID == assetID })?.state
            await refreshAlbums(clearingRecovery: false)
            if !allAlbums.contains(where: { $0.id == albumID }) {
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
        } catch {
            errorGuidance = "无法保存归档结果，请稍后重试。"
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
