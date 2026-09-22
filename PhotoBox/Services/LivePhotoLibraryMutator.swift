import Foundation
import Photos

actor LivePhotoLibraryMutator: PhotoLibraryMutating, PhotoFavoriteMutating {
    let backendMode = MutationBackendMode.live

    func availableAssetIDs(for requestedIDs: [String]) -> Set<String> {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: requestedIDs, options: nil)
        var available: Set<String> = []
        available.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in available.insert(asset.localIdentifier) }
        return available
    }

    func listAlbums() -> [PhotoAlbumDescriptor] {
        let result = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .albumRegular,
            options: nil
        )
        var albums: [PhotoAlbumDescriptor] = []
        albums.reserveCapacity(result.count)
        result.enumerateObjects { collection, _, _ in
            albums.append(Self.descriptor(for: collection))
        }
        return albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func createAlbum(named title: String) async -> PhotoAlbumDescriptor? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let placeholder = AlbumPlaceholderBox()
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(
                    withTitle: trimmed
                )
                placeholder.identifier = request.placeholderForCreatedAssetCollection.localIdentifier
            }
            guard let identifier = placeholder.identifier,
                  let collection = PHAssetCollection.fetchAssetCollections(
                    withLocalIdentifiers: [identifier],
                    options: nil
                  ).firstObject else { return nil }
            return Self.descriptor(for: collection)
        } catch {
            return nil
        }
    }

    func archivedAssetIDs(for requestedIDs: [String], inAlbumID albumID: String) -> Set<String> {
        guard let collection = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [albumID],
            options: nil
        ).firstObject else { return [] }
        let requested = Set(requestedIDs)
        let assets = PHAsset.fetchAssets(in: collection, options: nil)
        var archived: Set<String> = []
        assets.enumerateObjects { asset, _, stop in
            if requested.contains(asset.localIdentifier) {
                archived.insert(asset.localIdentifier)
                stop.pointee = ObjCBool(archived.count == requested.count)
            }
        }
        return archived
    }

    func addAssets(
        withIDs requestedIDs: [String],
        toAlbumID albumID: String
    ) async -> PhotoMutationBatch {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: requestedIDs, options: nil)
        let availableIDs = Self.identifiers(in: assets)
        var items = requestedIDs.map {
            MutationItem(assetID: $0, state: availableIDs.contains($0) ? .pending : .stale)
        }
        guard let collection = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [albumID],
            options: nil
        ).firstObject else {
            items = items.map {
                $0.state == .pending ? MutationItem(assetID: $0.assetID, state: .failed) : $0
            }
            return PhotoMutationBatch(operation: .archive, items: items, targetAlbumID: albumID)
        }
        guard !availableIDs.isEmpty else {
            return PhotoMutationBatch(operation: .archive, items: items, targetAlbumID: albumID)
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCollectionChangeRequest(for: collection)?.addAssets(assets)
            }
            items = resolved(items, state: .succeeded)
        } catch {
            items = resolved(items, state: .failed, errorCode: String((error as NSError).code))
        }
        return PhotoMutationBatch(operation: .archive, items: items, targetAlbumID: albumID)
    }

    func deleteAssets(withIDs requestedIDs: [String]) async -> PhotoMutationBatch {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: requestedIDs, options: nil)
        let availableIDs = Self.identifiers(in: assets)
        var items = requestedIDs.map {
            MutationItem(assetID: $0, state: availableIDs.contains($0) ? .pending : .stale)
        }
        guard !availableIDs.isEmpty else {
            return PhotoMutationBatch(operation: .delete, items: items, targetAlbumID: nil)
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            }
            items = resolved(items, state: .succeeded)
        } catch {
            items = resolved(items, state: .failed, errorCode: String((error as NSError).code))
        }
        return PhotoMutationBatch(operation: .delete, items: items, targetAlbumID: nil)
    }

    func setFavorite(_ isFavorite: Bool, forAssetID assetID: String) async -> Bool {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else {
            return false
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest(for: asset).isFavorite = isFavorite
            }
            return true
        } catch {
            return false
        }
    }

    private func resolved(
        _ items: [MutationItem],
        state: MutationItemState,
        errorCode: String? = nil
    ) -> [MutationItem] {
        items.map {
            $0.state == .pending
                ? MutationItem(assetID: $0.assetID, state: state, errorCode: errorCode)
                : $0
        }
    }

    private static func descriptor(for collection: PHAssetCollection) -> PhotoAlbumDescriptor {
        let assets = PHAsset.fetchAssets(in: collection, options: nil)
        return PhotoAlbumDescriptor(
            id: collection.localIdentifier,
            title: collection.localizedTitle ?? "未命名相册",
            assetCount: assets.count,
            coverAssetID: assets.firstObject?.localIdentifier
        )
    }

    private static func identifiers(in result: PHFetchResult<PHAsset>) -> Set<String> {
        var identifiers: Set<String> = []
        identifiers.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in identifiers.insert(asset.localIdentifier) }
        return identifiers
    }
}

nonisolated final class AlbumPlaceholderBox: @unchecked Sendable {
    var identifier: String?
}
