import Foundation

actor BoundedThumbnailLoader {
    private let reader: any PhotoLibraryReading
    private let maxConcurrentRequests: Int
    private let maximumCachedThumbnails: Int
    private var cache: [ThumbnailCacheKey: PhotoThumbnail] = [:]
    private var cacheOrder: [ThumbnailCacheKey] = []
    private var inFlight: [ThumbnailCacheKey: Task<PhotoThumbnail?, Never>] = [:]

    init(
        reader: any PhotoLibraryReading,
        maxConcurrentRequests: Int = 4,
        maximumCachedThumbnails: Int = 96
    ) {
        self.reader = reader
        self.maxConcurrentRequests = max(1, maxConcurrentRequests)
        self.maximumCachedThumbnails = max(0, maximumCachedThumbnails)
    }

    func load(assetIDs: [String], maxPixelSize: Int) async -> [PhotoThumbnail] {
        guard !assetIDs.isEmpty else { return [] }
        var loaded: [Int: PhotoThumbnail] = [:]
        var missing: [(Int, String)] = []
        for (index, assetID) in assetIDs.enumerated() {
            let key = ThumbnailCacheKey(assetID: assetID, maxPixelSize: maxPixelSize)
            if let cached = cache[key] {
                loaded[index] = cached
                touch(key)
            } else {
                missing.append((index, assetID))
            }
        }

        for batchStart in stride(from: 0, to: missing.count, by: maxConcurrentRequests) {
            guard !Task.isCancelled else { return [] }
            let batchEnd = min(batchStart + maxConcurrentRequests, missing.count)
            let batch = Array(missing[batchStart..<batchEnd])
            let results = await withTaskGroup(of: (Int, PhotoThumbnail?).self) { group in
                for (index, assetID) in batch {
                    let key = ThumbnailCacheKey(assetID: assetID, maxPixelSize: maxPixelSize)
                    let request = requestTask(for: key)
                    group.addTask {
                        let thumbnail = await request.value
                        return (index, Task.isCancelled ? nil : thumbnail)
                    }
                }
                var values: [(Int, PhotoThumbnail?)] = []
                for await value in group { values.append(value) }
                return values
            }
            for (index, thumbnail) in results {
                let key = ThumbnailCacheKey(assetID: assetIDs[index], maxPixelSize: maxPixelSize)
                inFlight.removeValue(forKey: key)
                guard let thumbnail else { continue }
                loaded[index] = thumbnail
                insert(thumbnail, maxPixelSize: maxPixelSize)
            }
        }
        guard !Task.isCancelled else { return [] }
        return assetIDs.indices.compactMap { loaded[$0] }
    }

    private func requestTask(for key: ThumbnailCacheKey) -> Task<PhotoThumbnail?, Never> {
        if let existing = inFlight[key] {
            return existing
        }
        let reader = self.reader
        let task = Task<PhotoThumbnail?, Never> {
            guard !Task.isCancelled else { return nil }
            return await reader.thumbnail(
                for: key.assetID,
                maxPixelSize: key.maxPixelSize
            )
        }
        inFlight[key] = task
        return task
    }

    private func insert(_ thumbnail: PhotoThumbnail, maxPixelSize: Int) {
        guard maximumCachedThumbnails > 0 else { return }
        let key = ThumbnailCacheKey(assetID: thumbnail.assetID, maxPixelSize: maxPixelSize)
        cache[key] = thumbnail
        touch(key)
        while cacheOrder.count > maximumCachedThumbnails {
            let evicted = cacheOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
    }

    private func touch(_ key: ThumbnailCacheKey) {
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
    }
}

private nonisolated struct ThumbnailCacheKey: Hashable, Sendable {
    let assetID: String
    let maxPixelSize: Int
}
