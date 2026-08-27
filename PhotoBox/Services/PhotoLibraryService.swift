import Foundation
import Photos

nonisolated protocol PhotoLibraryServing: Sendable {
    func authorizationStatus() async -> PhotoAuthorization
    func requestAuthorization() async -> PhotoAuthorization
    func scanLibrary(screenshotAgeDays: Int) async -> AsyncStream<LibraryScanSnapshot>
}

actor LivePhotoLibraryService: PhotoLibraryServing {
    private let imageManager = PHImageManager.default()

    func authorizationStatus() -> PhotoAuthorization {
        PhotoAuthorization(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAuthorization() async -> PhotoAuthorization {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: PhotoAuthorization(status))
            }
        }
    }

    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> {
        AsyncStream { continuation in
            let task = Task {
                await performScan(screenshotAgeDays: screenshotAgeDays, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func performScan(
        screenshotAgeDays: Int,
        continuation: AsyncStream<LibraryScanSnapshot>.Continuation
    ) async {
        guard PhotoLibraryClassifier.authorizationAllowsScanning(
            PHPhotoLibrary.authorizationStatus(for: .readWrite)
        ) else {
            var failed = LibraryScanSnapshot.idle
            failed.phase = .failed
            failed.errorMessage = "照片访问权限已发生变化"
            continuation.yield(failed)
            continuation.finish()
            return
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let fetchResult = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(fetchResult.count)
        fetchResult.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -screenshotAgeDays,
            to: Date()
        ) ?? .distantPast
        assets.sort {
            PhotoLibraryClassifier.priority(of: $0, cutoff: cutoff)
                < PhotoLibraryClassifier.priority(of: $1, cutoff: cutoff)
        }

        var snapshot = LibraryScanSnapshot.starting
        snapshot.discoveredCount = assets.count
        snapshot.userAlbumCount = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .albumRegular,
            options: nil
        ).count
        snapshot.phase = .checkingLocalAvailability
        continuation.yield(snapshot)

        for (index, asset) in assets.enumerated() {
            guard !Task.isCancelled else {
                continuation.finish()
                return
            }

            switch await availability(of: asset) {
            case .local:
                snapshot.localCount += 1
                if PhotoLibraryClassifier.isExpiredScreenshot(asset, cutoff: cutoff) {
                    snapshot.screenshotCount += 1
                }
                if PhotoLibraryClassifier.isLargeVideoCandidate(asset) {
                    snapshot.largeVideoCount += 1
                }
            case .iCloudOnly:
                snapshot.iCloudOnlyCount += 1
            case .unavailable:
                snapshot.unavailableCount += 1
            }

            snapshot.processedCount = index + 1
            if snapshot.screenshotCount == 1
                || snapshot.processedCount.isMultiple(of: 20)
                || snapshot.processedCount == assets.count {
                continuation.yield(snapshot)
            }
        }

        snapshot.phase = .completed
        continuation.yield(snapshot)
        continuation.finish()
    }

    private func availability(of asset: PHAsset) async -> PhotoAssetAvailability {
        switch asset.mediaType {
        case .image:
            await imageAvailability(of: asset)
        case .video:
            await videoAvailability(of: asset)
        default:
            .unavailable
        }
    }

    private func imageAvailability(of asset: PHAsset) async -> PhotoAssetAvailability {
        await withCheckedContinuation { continuation in
            let options = PhotoLibraryRequestPolicy.imageOptions()

            imageManager.requestImage(
                for: asset,
                targetSize: CGSize(width: 64, height: 64),
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                continuation.resume(returning: Self.availability(dataExists: image != nil, info: info))
            }
        }
    }

    private func videoAvailability(of asset: PHAsset) async -> PhotoAssetAvailability {
        await withCheckedContinuation { continuation in
            let options = PhotoLibraryRequestPolicy.videoOptions()

            imageManager.requestAVAsset(forVideo: asset, options: options) { asset, _, info in
                continuation.resume(returning: Self.availability(dataExists: asset != nil, info: info))
            }
        }
    }

    private nonisolated static func availability(
        dataExists: Bool,
        info: [AnyHashable: Any]?
    ) -> PhotoAssetAvailability {
        PhotoLibraryClassifier.availability(
            dataExists: dataExists,
            isInCloud: info?[PHImageResultIsInCloudKey] as? Bool == true
        )
    }
}

nonisolated enum PhotoLibraryRequestPolicy {
    nonisolated static func imageOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false
        return options
    }

    nonisolated static func videoOptions() -> PHVideoRequestOptions {
        let options = PHVideoRequestOptions()
        options.deliveryMode = .fastFormat
        options.isNetworkAccessAllowed = false
        return options
    }
}

nonisolated enum PhotoAssetAvailability: Equatable, Sendable {
    case local
    case iCloudOnly
    case unavailable
}

nonisolated enum PhotoLibraryClassifier {
    nonisolated static func authorizationAllowsScanning(_ status: PHAuthorizationStatus) -> Bool {
        status == .authorized || status == .limited
    }

    nonisolated static func isExpiredScreenshot(_ asset: PHAsset, cutoff: Date) -> Bool {
        isExpiredScreenshot(
            mediaType: asset.mediaType,
            mediaSubtypes: asset.mediaSubtypes,
            creationDate: asset.creationDate,
            cutoff: cutoff
        )
    }

    nonisolated static func isExpiredScreenshot(
        mediaType: PHAssetMediaType,
        mediaSubtypes: PHAssetMediaSubtype,
        creationDate: Date?,
        cutoff: Date
    ) -> Bool {
        guard mediaType == .image,
              mediaSubtypes.contains(.photoScreenshot),
              let creationDate else {
            return false
        }
        return creationDate < cutoff
    }

    nonisolated static func isLargeVideoCandidate(_ asset: PHAsset) -> Bool {
        isLargeVideoCandidate(mediaType: asset.mediaType, duration: asset.duration)
    }

    nonisolated static func isLargeVideoCandidate(
        mediaType: PHAssetMediaType,
        duration: TimeInterval
    ) -> Bool {
        mediaType == .video && duration >= 60
    }

    nonisolated static func availability(
        dataExists: Bool,
        isInCloud: Bool
    ) -> PhotoAssetAvailability {
        if isInCloud { return .iCloudOnly }
        return dataExists ? .local : .unavailable
    }

    nonisolated static func priority(of asset: PHAsset, cutoff: Date) -> Int {
        if isExpiredScreenshot(asset, cutoff: cutoff) { return 0 }
        if isLargeVideoCandidate(asset) { return 1 }
        return 2
    }
}
