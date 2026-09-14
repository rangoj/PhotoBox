import Foundation

nonisolated struct CleanupTaskGenerator: Sendable {
    private let narrower: MetadataCandidateNarrower

    init(narrower: MetadataCandidateNarrower = MetadataCandidateNarrower()) {
        self.narrower = narrower
    }

    func generate(
        descriptors: [PhotoAssetDescriptor],
        screenshotAgeDays: Int,
        includeGroups: Bool = true,
        now: Date = .now
    ) -> [CleanupTask] {
        // Partial scans only materialize fast metadata categories. Avoid
        // rebuilding similarity/duplicate groups on every descriptor flush.
        let sourceDescriptors = includeGroups
            ? descriptors
            : descriptors.filter { $0.isScreenshot || $0.mediaType == .video }
        let byID = Dictionary(uniqueKeysWithValues: sourceDescriptors.map { ($0.id, $0) })
        let discovery = narrower.discover(
            descriptors: sourceDescriptors,
            now: now,
            screenshotAgeDays: screenshotAgeDays
        )
        var tasks: [CleanupTask] = []

        if !discovery.expiredScreenshotIDs.isEmpty {
            tasks.append(makeTask(
                type: .screenshots,
                assetIDs: discovery.expiredScreenshotIDs,
                descriptors: byID,
                title: "处理过期截图",
                reason: "超过保留期限且未标记为收藏",
                risk: .low,
                confidence: 1,
                estimatedMinutesPerAsset: 1,
                now: now
            ))
        }

        if includeGroups {
            for cluster in discovery.groups {
                let type: CleanupTaskType = switch cluster.kind {
                case .duplicate: .duplicates
                case .similar: .similar
                case .burst: .bursts
                }
                let title: String = switch cluster.kind {
                case .duplicate: "检查重复照片"
                case .similar: "比较相似照片"
                case .burst: "整理连拍照片"
                }
                tasks.append(makeTask(
                    type: type,
                    assetIDs: cluster.assetIDs,
                    descriptors: byID,
                    title: title,
                    reason: "来自同一候选组，需要逐组确认",
                    risk: .medium,
                    confidence: 0.5,
                    estimatedMinutesPerAsset: 1,
                    now: now
                ))
            }
        }

        if !discovery.largeVideoIDs.isEmpty {
            tasks.append(makeTask(
                type: .largeVideos,
                assetIDs: discovery.largeVideoIDs,
                descriptors: byID,
                title: "检查较长视频",
                reason: "视频时长超过 60 秒，空间估算仅供参考",
                risk: .high,
                confidence: 0.8,
                estimatedMinutesPerAsset: 2,
                now: now
            ))
        }

        return tasks
    }

    private func makeTask(
        type: CleanupTaskType,
        assetIDs: [String],
        descriptors: [String: PhotoAssetDescriptor],
        title: String,
        reason: String,
        risk: CleanupTaskRisk,
        confidence: Double,
        estimatedMinutesPerAsset: Int,
        now: Date
    ) -> CleanupTask {
        let orderedIDs = assetIDs.sorted()
        let estimatedBytes = orderedIDs.reduce(Int64.zero) { total, id in
            total + max(0, descriptors[id]?.estimatedBytes ?? 0)
        }
        let identifier: String
        switch type {
        case .screenshots, .largeVideos:
            // These categories are incrementally discovered during a scan.
            identifier = "scan:\(type.rawValue)"
        default:
            identifier = "scan:\(type.rawValue):\(orderedIDs.joined(separator: ","))"
        }
        return CleanupTask(
            id: identifier,
            type: type,
            title: title,
            reason: reason,
            assetIDs: orderedIDs,
            estimatedBytes: estimatedBytes,
            estimatedMinutes: max(1, orderedIDs.count * estimatedMinutesPerAsset),
            risk: risk,
            confidence: confidence,
            createdAt: now,
            updatedAt: now
        )
    }
}
