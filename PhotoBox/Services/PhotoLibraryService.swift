import Foundation
import Photos
import UIKit

nonisolated enum PhotoLibraryReadError: Error, Equatable, Sendable {
    case scopeUnavailable
    case collectionUnavailable

    var message: String {
        switch self {
        case .scopeUnavailable:
            "照片访问权限已发生变化"
        case .collectionUnavailable:
            "此相册已删除或不在当前可访问范围内"
        }
    }
}

nonisolated struct PhotoLibraryDescriptorStream: Sendable {
    let discoveredCount: Int
    let stream: AsyncThrowingStream<PhotoAssetDescriptor, Error>
}

nonisolated protocol PhotoLibraryReading: Sendable {
    func authorizationStatus() async -> PhotoAuthorization
    func requestAuthorization() async -> PhotoAuthorization
    func accessibleAssetDescriptors() async throws -> [PhotoAssetDescriptor]
    func albumCollections() async throws -> [PhotoCollectionDescriptor]
    func assets(inCollection id: String) async throws -> [PhotoAssetDescriptor]
    func assetDescriptorStream(screenshotAgeDays: Int) async throws -> PhotoLibraryDescriptorStream
    func assetDescriptors(for assetIDs: [String]) async throws -> [PhotoAssetDescriptor]
    func libraryChanges() async -> AsyncStream<PhotoLibraryChange>
    func thumbnail(for assetID: String, maxPixelSize: Int) async -> PhotoThumbnail?
    func scanLibrary(screenshotAgeDays: Int) async -> AsyncStream<LibraryScanSnapshot>
}

extension PhotoLibraryReading {
    func albumCollections() async throws -> [PhotoCollectionDescriptor] { [] }
    func assets(inCollection id: String) async throws -> [PhotoAssetDescriptor] {
        throw PhotoLibraryReadError.collectionUnavailable
    }
    func accessibleAssetDescriptors() async throws -> [PhotoAssetDescriptor] { [] }
    func assetDescriptorStream(screenshotAgeDays: Int) async throws -> PhotoLibraryDescriptorStream {
        let descriptors = try await accessibleAssetDescriptors()
        let stream = AsyncThrowingStream<PhotoAssetDescriptor, Error> { continuation in
            for descriptor in descriptors {
                continuation.yield(descriptor)
            }
            continuation.finish()
        }
        return PhotoLibraryDescriptorStream(
            discoveredCount: descriptors.count,
            stream: stream
        )
    }
    func assetDescriptors(for assetIDs: [String]) async throws -> [PhotoAssetDescriptor] {
        guard !assetIDs.isEmpty else { return [] }
        let requested = Set(assetIDs)
        return try await accessibleAssetDescriptors().filter { requested.contains($0.id) }
    }
    func libraryChanges() async -> AsyncStream<PhotoLibraryChange> {
        AsyncStream { $0.finish() }
    }
    func thumbnail(for assetID: String, maxPixelSize: Int) async -> PhotoThumbnail? { nil }
}

actor LivePhotoLibraryService: PhotoLibraryReading {
    private let imageManager = PHImageManager.default()
    private let changeObserver = PhotoLibraryChangeObserverBridge()

    init() {
        PHPhotoLibrary.shared().register(changeObserver)
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(changeObserver)
    }

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

    func accessibleAssetDescriptors() async throws -> [PhotoAssetDescriptor] {
        guard PhotoLibraryClassifier.authorizationAllowsScanning(
            PHPhotoLibrary.authorizationStatus(for: .readWrite)
        ) else { throw PhotoLibraryReadError.scopeUnavailable }

        let fetchResult = PHAsset.fetchAssets(with: nil)
        var assets: [PHAsset] = []
        assets.reserveCapacity(fetchResult.count)
        fetchResult.enumerateObjects { asset, _, _ in assets.append(asset) }

        return await descriptors(for: assets)
    }

    func albumCollections() async throws -> [PhotoCollectionDescriptor] {
        guard authorizationStatus().canReadLibrary else { throw PhotoLibraryReadError.scopeUnavailable }
        let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        let favorites = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumFavorites, options: nil)
        var result: [PhotoCollectionDescriptor] = []
        for (fetch, kind) in [(favorites, PhotoCollectionKind.favorites), (albums, .album)] {
            for index in 0..<fetch.count {
                try Task.checkCancellation()
                let collection = fetch.object(at: index)
                let members = PHAsset.fetchAssets(in: collection, options: collectionMemberOptions())
                result.append(PhotoCollectionDescriptor(
                    id: collection.localIdentifier,
                    kind: kind,
                    title: kind == .favorites ? "收藏" : (collection.localizedTitle ?? "未命名相册"),
                    assetCount: members.count,
                    coverAssetID: members.firstObject?.localIdentifier
                ))
            }
        }
        return result
    }

    func assets(inCollection id: String) async throws -> [PhotoAssetDescriptor] {
        let scope = authorizationStatus()
        guard scope.canReadLibrary else { throw PhotoLibraryReadError.scopeUnavailable }
        guard let collection = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [id], options: nil
        ).firstObject else { throw PhotoLibraryReadError.collectionUnavailable }
        let members = PHAsset.fetchAssets(in: collection, options: collectionMemberOptions())
        var assets: [PHAsset] = []
        members.enumerateObjects { asset, _, _ in assets.append(asset) }
        let result = await descriptors(for: assets)
        try Task.checkCancellation()
        guard authorizationStatus() == scope else { throw PhotoLibraryReadError.scopeUnavailable }
        return result
    }

    private func collectionMemberOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return options
    }

    func assetDescriptorStream(screenshotAgeDays: Int) async throws -> PhotoLibraryDescriptorStream {
        guard PhotoLibraryClassifier.authorizationAllowsScanning(
            PHPhotoLibrary.authorizationStatus(for: .readWrite)
        ) else { throw PhotoLibraryReadError.scopeUnavailable }

        let fetchResult = PHAsset.fetchAssets(with: nil)
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -screenshotAgeDays,
            to: Date()
        ) ?? .distantPast
        let orderedIndices = (0..<fetchResult.count).sorted { first, second in
            let firstAsset = fetchResult.object(at: first)
            let secondAsset = fetchResult.object(at: second)
            return PhotoLibraryClassifier.priority(of: firstAsset, cutoff: cutoff)
                < PhotoLibraryClassifier.priority(of: secondAsset, cutoff: cutoff)
        }

        let pair = AsyncThrowingStream<PhotoAssetDescriptor, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(1)
        )
        let task = Task { [weak self] in
            guard let self else {
                pair.continuation.finish()
                return
            }
            await self.emitDescriptors(
                for: fetchResult,
                orderedIndices: orderedIndices,
                to: pair.continuation
            )
        }
        pair.continuation.onTermination = { _ in task.cancel() }
        return PhotoLibraryDescriptorStream(
            discoveredCount: fetchResult.count,
            stream: pair.stream
        )
    }

    func assetDescriptors(for assetIDs: [String]) async throws -> [PhotoAssetDescriptor] {
        guard PhotoLibraryClassifier.authorizationAllowsScanning(
            PHPhotoLibrary.authorizationStatus(for: .readWrite)
        ) else { throw PhotoLibraryReadError.scopeUnavailable }
        guard !assetIDs.isEmpty else { return [] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return await descriptors(for: assets)
    }

    func libraryChanges() -> AsyncStream<PhotoLibraryChange> {
        changeObserver.stream()
    }

    private func descriptors(for assets: [PHAsset]) async -> [PhotoAssetDescriptor] {
        guard !assets.isEmpty else { return [] }
        var results = Array<PhotoAssetDescriptor?>(repeating: nil, count: assets.count)
        await withTaskGroup(of: (Int, PhotoAssetDescriptor?).self) { group in
            var nextIndex = 0
            let workerCount = min(8, assets.count)
            for _ in 0..<workerCount {
                let index = nextIndex
                nextIndex += 1
                group.addTask { [self] in
                    guard !Task.isCancelled else { return (index, nil) }
                    return (index, await descriptor(for: assets[index]))
                }
            }

            while let (index, descriptor) = await group.next() {
                results[index] = descriptor
                guard nextIndex < assets.count else { continue }
                let replacementIndex = nextIndex
                nextIndex += 1
                group.addTask { [self] in
                    guard !Task.isCancelled else { return (replacementIndex, nil) }
                    return (replacementIndex, await self.descriptor(for: assets[replacementIndex]))
                }
            }
        }
        return results.compactMap { $0 }
    }

    private func emitDescriptors(
        for fetchResult: PHFetchResult<PHAsset>,
        orderedIndices: [Int],
        to continuation: AsyncThrowingStream<PhotoAssetDescriptor, Error>.Continuation
    ) async {
        // Keep only a small object window alive while descriptors are emitted.
        // The fetch result remains PhotoKit-owned instead of duplicating the
        // entire library into an in-memory array.
        let chunkSize = 128
        for start in stride(from: 0, to: orderedIndices.count, by: chunkSize) {
            guard !Task.isCancelled else {
                continuation.finish()
                return
            }
            let end = min(start + chunkSize, orderedIndices.count)
            let assets = orderedIndices[start..<end].map { fetchResult.object(at: $0) }
            await emitDescriptorChunk(for: assets, to: continuation)
        }
        continuation.finish()
    }

    private func emitDescriptorChunk(
        for assets: [PHAsset],
        to continuation: AsyncThrowingStream<PhotoAssetDescriptor, Error>.Continuation
    ) async {
        await withTaskGroup(of: PhotoAssetDescriptor?.self) { group in
            var nextIndex = 0
            let workerCount = min(8, assets.count)
            for _ in 0..<workerCount {
                let index = nextIndex
                nextIndex += 1
                group.addTask { [self] in
                    guard !Task.isCancelled else { return nil }
                    return await descriptor(for: assets[index])
                }
            }
            while let value = await group.next() {
                if let value {
                    guard await yieldDescriptor(value, to: continuation) else { return }
                }
                guard nextIndex < assets.count else { continue }
                let index = nextIndex
                nextIndex += 1
                group.addTask { [self] in
                    guard !Task.isCancelled else { return nil }
                    return await descriptor(for: assets[index])
                }
            }
        }
    }

    private func yieldDescriptor(
        _ descriptor: PhotoAssetDescriptor,
        to continuation: AsyncThrowingStream<PhotoAssetDescriptor, Error>.Continuation
    ) async -> Bool {
        while !Task.isCancelled {
            switch continuation.yield(descriptor) {
            case .enqueued:
                return true
            case .terminated:
                return false
            case .dropped:
                // The single buffered slot is still occupied. Yield until the
                // coordinator consumes it instead of dropping a descriptor.
                await Task.yield()
            @unknown default:
                return false
            }
        }
        return false
    }

    private func descriptor(for asset: PHAsset) async -> PhotoAssetDescriptor? {
        guard !Task.isCancelled else { return nil }
        let availability = await availability(of: asset)
        let resources = PHAssetResource.assetResources(for: asset)
        let estimatedBytes = resources
            .compactMap { ($0.value(forKey: "fileSize") as? NSNumber)?.int64Value }
            .reduce(0, +)
        let isEdited = resources.contains {
            $0.type == .adjustmentBasePhoto || $0.type == .adjustmentBaseVideo
        }
        return PhotoLibraryClassifier.descriptor(
            id: asset.localIdentifier,
            mediaType: asset.mediaType,
            mediaSubtypes: asset.mediaSubtypes,
            creationDate: asset.creationDate,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            duration: asset.duration,
            estimatedBytes: estimatedBytes,
            isFavorite: asset.isFavorite,
            isEdited: isEdited,
            burstIdentifier: asset.burstIdentifier,
            availability: AssetAvailability(availability)
        )
    }

    func thumbnail(for assetID: String, maxPixelSize: Int) async -> PhotoThumbnail? {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let asset = result.firstObject else { return nil }
        let size = CGSize(width: maxPixelSize, height: maxPixelSize)
        let bridge = ThumbnailRequestBridge<PHImageRequestID> { [imageManager] requestID in
            imageManager.cancelImageRequest(requestID)
        }
        return await withTaskCancellationHandler(
            operation: {
                await withCheckedContinuation { continuation in
                    bridge.install(continuation)
                    let requestID = imageManager.requestImage(
                        for: asset,
                        targetSize: size,
                        contentMode: .aspectFit,
                        options: PhotoLibraryRequestPolicy.imageOptions()
                    ) { image, info in
                        guard info?[PHImageCancelledKey] as? Bool != true,
                              info?[PHImageErrorKey] == nil,
                              let image,
                              let data = image.jpegData(compressionQuality: 0.82) else {
                            bridge.resume(returning: nil)
                            return
                        }
                        bridge.resume(returning: PhotoThumbnail(
                            assetID: assetID,
                            data: data,
                            pixelWidth: Int(image.size.width * image.scale),
                            pixelHeight: Int(image.size.height * image.scale)
                        ))
                    }
                    bridge.register(requestID: requestID)
                }
            },
            onCancel: {
                bridge.cancel()
            }
        )
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

nonisolated final class ThumbnailRequestBridge<RequestID: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PhotoThumbnail?, Never>?
    private var requestID: RequestID?
    private var cancellationRequested = false
    private var didCancelRequest = false
    private var completed = false
    private let cancelRequest: (RequestID) -> Void

    init(cancelRequest: @escaping (RequestID) -> Void) {
        self.cancelRequest = cancelRequest
    }

    func install(_ continuation: CheckedContinuation<PhotoThumbnail?, Never>) {
        lock.lock()
        let shouldResume = cancellationRequested || completed
        if !shouldResume {
            self.continuation = continuation
        }
        lock.unlock()

        if shouldResume {
            continuation.resume(returning: nil)
        }
    }

    func register(requestID: RequestID) {
        lock.lock()
        guard !completed || cancellationRequested else {
            lock.unlock()
            return
        }
        self.requestID = requestID
        let requestToCancel: RequestID?
        if cancellationRequested && !didCancelRequest {
            didCancelRequest = true
            requestToCancel = requestID
        } else {
            requestToCancel = nil
        }
        lock.unlock()

        if let requestToCancel {
            cancelRequest(requestToCancel)
        }
    }

    func cancel() {
        lock.lock()
        guard !cancellationRequested && !completed else {
            lock.unlock()
            return
        }
        cancellationRequested = true
        let pendingContinuation = continuation
        continuation = nil
        let requestToCancel: RequestID?
        if let requestID, !didCancelRequest {
            didCancelRequest = true
            requestToCancel = requestID
        } else {
            requestToCancel = nil
        }
        lock.unlock()

        if let requestToCancel {
            cancelRequest(requestToCancel)
        }
        pendingContinuation?.resume(returning: nil)
    }

    func resume(returning thumbnail: PhotoThumbnail?) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: thumbnail)
    }
}

nonisolated final class PhotoLibraryChangeObserverBridge: NSObject,
    PHPhotoLibraryChangeObserver,
    @unchecked Sendable {
    private let lock = NSLock()
    private var knownAssetIDs: Set<String>
    private var knownAuthorization: PHAuthorizationStatus
    private var continuations: [UUID: AsyncStream<PhotoLibraryChange>.Continuation] = [:]

    override init() {
        knownAssetIDs = Self.currentAssetIDs()
        knownAuthorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        super.init()
    }

    func stream() -> AsyncStream<PhotoLibraryChange> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id)
            }
        }
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        let currentIDs = Self.currentAssetIDs()
        let currentAuthorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        lock.lock()
        let addedIDs = currentIDs.subtracting(knownAssetIDs).sorted()
        let removedIDs = knownAssetIDs.subtracting(currentIDs).sorted()
        let scopeChanged = currentAuthorization != knownAuthorization
            || (currentAuthorization == .limited && currentIDs != knownAssetIDs)
        knownAssetIDs = currentIDs
        knownAuthorization = currentAuthorization
        let activeContinuations = Array(continuations.values)
        lock.unlock()

        // PhotoKit also reports collection membership, title, and favorite changes.
        // Forward those notifications even when the library's asset identities match.
        let change = PhotoLibraryChange(
            addedAssetIDs: addedIDs,
            removedAssetIDs: removedIDs,
            scopeChanged: scopeChanged
        )
        for continuation in activeContinuations { continuation.yield(change) }
    }

    private func removeContinuation(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }

    private static func currentAssetIDs() -> Set<String> {
        let result = PHAsset.fetchAssets(with: nil)
        var identifiers: Set<String> = []
        identifiers.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            identifiers.insert(asset.localIdentifier)
        }
        return identifiers
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

private extension AssetAvailability {
    nonisolated init(_ availability: PhotoAssetAvailability) {
        switch availability {
        case .local: self = .local
        case .iCloudOnly: self = .iCloudOnly
        case .unavailable: self = .unavailable
        }
    }
}

nonisolated enum PhotoLibraryClassifier {
    nonisolated static func descriptor(
        id: String,
        mediaType: PHAssetMediaType,
        mediaSubtypes: PHAssetMediaSubtype,
        creationDate: Date?,
        pixelWidth: Int,
        pixelHeight: Int,
        duration: TimeInterval,
        estimatedBytes: Int64,
        isFavorite: Bool,
        isEdited: Bool,
        burstIdentifier: String?,
        availability: AssetAvailability
    ) -> PhotoAssetDescriptor {
        let type: PhotoMediaType
        if mediaSubtypes.contains(.photoLive) {
            type = .livePhoto
        } else if mediaSubtypes.contains(.photoPanorama) {
            type = .panorama
        } else if mediaType == .video {
            type = .video
        } else {
            type = .photo
        }

        return PhotoAssetDescriptor(
            id: id,
            mediaType: type,
            creationDate: creationDate,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            duration: duration,
            estimatedBytes: estimatedBytes,
            isFavorite: isFavorite,
            isEdited: isEdited,
            isScreenshot: mediaSubtypes.contains(.photoScreenshot),
            burstIdentifier: burstIdentifier,
            availability: availability
        )
    }

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
