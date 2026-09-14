import Foundation

nonisolated struct PhotoThumbnail: Equatable, Sendable {
    let assetID: String
    let data: Data
    let pixelWidth: Int
    let pixelHeight: Int
}

nonisolated struct PhotoCandidateCluster: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let kind: CandidateGroupKind
    let assetIDs: [String]
}

nonisolated struct CandidateDiscovery: Equatable, Sendable {
    let expiredScreenshotIDs: [String]
    let largeVideoIDs: [String]
    let groups: [PhotoCandidateCluster]

    var allCandidateIDs: Set<String> {
        Set(expiredScreenshotIDs + largeVideoIDs + groups.flatMap(\.assetIDs))
    }
}

nonisolated struct MetadataCandidateNarrower: Sendable {
    func discover(
        descriptors: [PhotoAssetDescriptor],
        now: Date,
        screenshotAgeDays: Int
    ) -> CandidateDiscovery {
        let local = descriptors.filter { $0.availability == .local }
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -screenshotAgeDays,
            to: now
        ) ?? .distantPast
        let screenshots: [String] = local.compactMap { descriptor -> String? in
            guard descriptor.isScreenshot,
                  let creationDate = descriptor.creationDate,
                  creationDate < cutoff,
                  !descriptor.isFavorite,
                  !descriptor.isEdited else { return nil }
            return descriptor.id
        }
        let largeVideos: [String] = local.compactMap { descriptor -> String? in
            descriptor.mediaType == .video && descriptor.duration >= 60 ? descriptor.id : nil
        }

        // Screenshots have their own task and must not be offered again in a
        // duplicate/similar group.
        let photos = local.filter { $0.mediaType != .video && !$0.isScreenshot }
        var assignedIDs: Set<String> = []
        var groups: [PhotoCandidateCluster] = []

        let bursts = Dictionary(grouping: photos.compactMap { descriptor in
            descriptor.burstIdentifier.map { ($0, descriptor) }
        }, by: { $0.0 })
        for burstID in bursts.keys.sorted() {
            let members = bursts[burstID, default: []].map(\.1)
            guard members.count > 1 else { continue }
            let ids = members.map(\.id)
            assignedIDs.formUnion(ids)
            groups.append(PhotoCandidateCluster(
                id: "burst:\(burstID)",
                kind: .burst,
                assetIDs: ids
            ))
        }

        let unassigned = photos.filter { !assignedIDs.contains($0.id) }
        let duplicateBuckets = Dictionary(grouping: unassigned) { descriptor in
            DuplicateKey(
                width: descriptor.pixelWidth,
                height: descriptor.pixelHeight,
                bytes: descriptor.estimatedBytes,
                creationSecond: descriptor.creationDate.map { Int($0.timeIntervalSince1970) }
            )
        }
        for (key, members) in duplicateBuckets
        where members.count > 1 && members.first?.estimatedBytes ?? 0 > 0 {
            let ids = members.map(\.id).sorted()
            assignedIDs.formUnion(ids)
            groups.append(PhotoCandidateCluster(
                id: "duplicate:\(key.identifier)",
                kind: .duplicate,
                assetIDs: ids
            ))
        }

        let remaining = photos
            .filter { !assignedIDs.contains($0.id) && $0.creationDate != nil }
            .sorted { $0.creationDate! < $1.creationDate! }
        var index = 0
        while index < remaining.count {
            var members = [remaining[index]]
            var next = index + 1
            while next < remaining.count,
                  remaining[next].creationDate!.timeIntervalSince(members.last!.creationDate!) <= 3,
                  hasCompatibleDimensions(remaining[index], remaining[next]) {
                members.append(remaining[next])
                next += 1
            }
            if members.count > 1 {
                let ids = members.map(\.id)
                groups.append(PhotoCandidateCluster(
                    id: "similar:\(ids.first ?? "")",
                    kind: .similar,
                    assetIDs: ids
                ))
            }
            index = next
        }

        return CandidateDiscovery(
            expiredScreenshotIDs: screenshots,
            largeVideoIDs: largeVideos,
            groups: groups.sorted { $0.id < $1.id }
        )
    }

    private func hasCompatibleDimensions(
        _ first: PhotoAssetDescriptor,
        _ second: PhotoAssetDescriptor
    ) -> Bool {
        guard first.pixelHeight > 0, second.pixelHeight > 0 else { return false }
        let firstRatio = Double(first.pixelWidth) / Double(first.pixelHeight)
        let secondRatio = Double(second.pixelWidth) / Double(second.pixelHeight)
        return abs(firstRatio - secondRatio) <= 0.02
    }
}

private nonisolated struct DuplicateKey: Hashable {
    let width: Int
    let height: Int
    let bytes: Int64
    let creationSecond: Int?

    var identifier: String {
        "\(width)x\(height):\(bytes):\(creationSecond.map(String.init) ?? "none")"
    }
}
