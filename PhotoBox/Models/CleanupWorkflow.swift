import CryptoKit
import Foundation

nonisolated enum PhotoMediaType: String, Codable, CaseIterable, Sendable {
    case photo
    case video
    case livePhoto
    case panorama
}

nonisolated enum AssetAvailability: String, Codable, Sendable {
    case local
    case iCloudOnly
    case unavailable
}

nonisolated struct PhotoAssetDescriptor: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let mediaType: PhotoMediaType
    let creationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let duration: TimeInterval
    let estimatedBytes: Int64
    let isFavorite: Bool
    let isEdited: Bool
    let isScreenshot: Bool
    let burstIdentifier: String?
    let availability: AssetAvailability
}

nonisolated struct PhotoQualitySignals: Codable, Equatable, Sendable {
    let sharpness: Double
    let exposure: Double
    let completeness: Double

    var score: Double {
        (sharpness + exposure + completeness) / 3
    }
}

nonisolated struct PhotoCandidate: Codable, Equatable, Identifiable, Sendable {
    var id: String { asset.id }

    let asset: PhotoAssetDescriptor
    let quality: PhotoQualitySignals
    let manualProtection: Bool

    var isProtectedByDefault: Bool {
        manualProtection || asset.isFavorite || asset.isEdited
    }
}

nonisolated enum CandidateGroupKind: String, Codable, Sendable {
    case duplicate
    case similar
    case burst
}

nonisolated struct PhotoCandidateGroup: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let kind: CandidateGroupKind
    let candidates: [PhotoCandidate]

    var protectedKeepIDs: [String] {
        candidates.filter(\.isProtectedByDefault).map(\.id)
    }

    var defaultDeleteIDs: [String] {
        let protectedIDs = Set(protectedKeepIDs)
        let unprotected = candidates.filter { !protectedIDs.contains($0.id) }
        if !protectedIDs.isEmpty {
            return unprotected.map(\.id)
        }
        guard unprotected.count > 1 else { return [] }

        let keepID = unprotected.max { $0.quality.score < $1.quality.score }?.id
        return unprotected.compactMap { $0.id == keepID ? nil : $0.id }
    }
}

nonisolated enum RecommendationReason: String, Codable, CaseIterable, Sendable {
    case protected
    case favorite
    case edited
    case sharper
    case balancedExposure
    case completeSubject
    case higherResolution

    var title: String {
        switch self {
        case .protected: "已保护"
        case .favorite: "已收藏"
        case .edited: "已编辑"
        case .sharper: "更清晰"
        case .balancedExposure: "曝光更自然"
        case .completeSubject: "主体更完整"
        case .higherResolution: "分辨率更高"
        }
    }
}

nonisolated enum PhotoDecisionKind: String, Codable, CaseIterable, Sendable {
    case keep
    case deleteCandidate
    case archive
    case protect
    case decideLater
}

nonisolated struct PhotoDecision: Codable, Equatable, Identifiable, Sendable {
    var id: String { assetID }

    let assetID: String
    let kind: PhotoDecisionKind
    let estimatedBytes: Int64
    let targetAlbumID: String?
    let taskID: String?
    let createdAt: Date
    let isSubmitted: Bool

    init(
        assetID: String,
        kind: PhotoDecisionKind,
        estimatedBytes: Int64 = 0,
        targetAlbumID: String? = nil,
        taskID: String? = nil,
        createdAt: Date = .now,
        isSubmitted: Bool = false
    ) {
        self.assetID = assetID
        self.kind = kind
        self.estimatedBytes = estimatedBytes
        self.targetAlbumID = targetAlbumID
        self.taskID = taskID
        self.createdAt = createdAt
        self.isSubmitted = isSubmitted
    }
}

nonisolated struct CleanupSummary: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let keptCount: Int
    let deleteCandidateCount: Int
    let archivedCount: Int
    let protectedCount: Int
    let deferredCount: Int
    let estimatedReclaimableBytes: Int64
    let elapsedSeconds: TimeInterval?
    let createdAt: Date

    init(
        decisions: [PhotoDecision],
        elapsedSeconds: TimeInterval?,
        id: UUID = UUID(),
        createdAt: Date = .now
    ) {
        self.id = id
        keptCount = decisions.count { $0.kind == .keep }
        deleteCandidateCount = decisions.count { $0.kind == .deleteCandidate }
        archivedCount = decisions.count { $0.kind == .archive }
        protectedCount = decisions.count { $0.kind == .protect }
        deferredCount = decisions.count { $0.kind == .decideLater }
        estimatedReclaimableBytes = decisions
            .filter { $0.kind == .deleteCandidate }
            .reduce(0) { $0 + $1.estimatedBytes }
        self.elapsedSeconds = elapsedSeconds
        self.createdAt = createdAt
    }

    init(
        id: UUID,
        keptCount: Int,
        deleteCandidateCount: Int,
        archivedCount: Int,
        protectedCount: Int,
        deferredCount: Int,
        estimatedReclaimableBytes: Int64,
        elapsedSeconds: TimeInterval?,
        createdAt: Date
    ) {
        self.id = id
        self.keptCount = keptCount
        self.deleteCandidateCount = deleteCandidateCount
        self.archivedCount = archivedCount
        self.protectedCount = protectedCount
        self.deferredCount = deferredCount
        self.estimatedReclaimableBytes = estimatedReclaimableBytes
        self.elapsedSeconds = elapsedSeconds
        self.createdAt = createdAt
    }

    static func identifier(forTaskID taskID: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(taskID.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

nonisolated enum ScanStage: String, Codable, CaseIterable, Sendable {
    case authorization
    case enumerating
    case checkingAvailability
    case classifying
    case analyzing
    case materializingTasks
    case completed
    case cancelled
    case failed
}

nonisolated struct ScanCheckpoint: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let stage: ScanStage
    let processedAssetIDs: [String]
    let discoveredCount: Int
    let snapshot: LibraryScanSnapshot
    let updatedAt: Date

    init(
        id: String,
        stage: ScanStage,
        processedAssetIDs: [String],
        discoveredCount: Int,
        snapshot: LibraryScanSnapshot = .idle,
        updatedAt: Date
    ) {
        self.id = id
        self.stage = stage
        self.processedAssetIDs = processedAssetIDs
        self.discoveredCount = discoveredCount
        self.snapshot = snapshot
        self.updatedAt = updatedAt
    }
}

nonisolated enum CleanupTaskType: String, Codable, CaseIterable, Sendable {
    case screenshots
    case duplicates
    case similar
    case bursts
    case largeVideos
    case weekly
    case dateBatch
}

nonisolated enum CleanupTaskRisk: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high
}

nonisolated enum CleanupTaskStatus: String, Codable, CaseIterable, Sendable {
    case queued
    case inProgress
    case paused
    case completed
    case skipped
    case invalid
}

nonisolated struct CleanupTask: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let type: CleanupTaskType
    let title: String
    let reason: String
    var assetIDs: [String]
    let estimatedBytes: Int64
    let estimatedMinutes: Int
    let risk: CleanupTaskRisk
    let confidence: Double
    var status: CleanupTaskStatus
    var ownedAssetIDs: [String]
    var currentAssetIndex: Int
    var skipCount: Int
    var lastSkippedAt: Date?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: String,
        type: CleanupTaskType,
        title: String,
        reason: String,
        assetIDs: [String],
        estimatedBytes: Int64,
        estimatedMinutes: Int,
        risk: CleanupTaskRisk,
        confidence: Double,
        status: CleanupTaskStatus = .queued,
        ownedAssetIDs: [String] = [],
        currentAssetIndex: Int = 0,
        skipCount: Int = 0,
        lastSkippedAt: Date? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.reason = reason
        self.assetIDs = assetIDs
        self.estimatedBytes = estimatedBytes
        self.estimatedMinutes = estimatedMinutes
        self.risk = risk
        self.confidence = confidence
        self.status = status
        self.ownedAssetIDs = ownedAssetIDs
        self.currentAssetIndex = currentAssetIndex
        self.skipCount = skipCount
        self.lastSkippedAt = lastSkippedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

nonisolated enum MutationOperation: String, Codable, CaseIterable, Sendable {
    case createAlbum
    case archive
    case delete
}

nonisolated enum MutationItemState: String, Codable, CaseIterable, Sendable {
    case pending
    case submitted
    case succeeded
    case failed
    case stale
    case cancelled
}

nonisolated struct MutationItem: Codable, Equatable, Identifiable, Sendable {
    var id: String { assetID }

    let assetID: String
    var state: MutationItemState
    var errorCode: String?

    init(assetID: String, state: MutationItemState, errorCode: String? = nil) {
        self.assetID = assetID
        self.state = state
        self.errorCode = errorCode
    }
}

nonisolated struct MutationTransaction: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let operation: MutationOperation
    var items: [MutationItem]
    var targetAlbumID: String?
    let createdAt: Date
    var submittedAt: Date?
    var completedAt: Date?
    let albumTitle: String?
    var albumIDsBeforeCreation: [String]?
    let archiveDecision: PhotoDecision?
    let recentAlbumIDs: [String]?
    let backendMode: MutationBackendMode?

    init(
        id: String,
        operation: MutationOperation,
        items: [MutationItem],
        targetAlbumID: String? = nil,
        createdAt: Date = .now,
        submittedAt: Date? = nil,
        completedAt: Date? = nil,
        albumTitle: String? = nil,
        albumIDsBeforeCreation: [String]? = nil,
        archiveDecision: PhotoDecision? = nil,
        recentAlbumIDs: [String]? = nil,
        backendMode: MutationBackendMode? = nil
    ) {
        self.id = id
        self.operation = operation
        self.items = items
        self.targetAlbumID = targetAlbumID
        self.createdAt = createdAt
        self.submittedAt = submittedAt
        self.completedAt = completedAt
        self.albumTitle = albumTitle
        self.albumIDsBeforeCreation = albumIDsBeforeCreation
        self.archiveDecision = archiveDecision
        self.recentAlbumIDs = recentAlbumIDs
        self.backendMode = backendMode
    }
}

nonisolated struct WorkflowSettings: Codable, Equatable, Sendable {
    var screenshotRetentionDays: Int
    var weeklyModeEnabled: Bool
    var reminderEnabled: Bool
    var reminderWeekday: Int
    var recentAlbumIDs: [String]
    var debugRealMutationEnabled: Bool
    var pendingResultSource: CleanupResultSource?

    static let defaults = WorkflowSettings(
        screenshotRetentionDays: 30,
        weeklyModeEnabled: false,
        reminderEnabled: false,
        reminderWeekday: 7,
        recentAlbumIDs: [],
        debugRealMutationEnabled: false,
        pendingResultSource: nil
    )
}

nonisolated struct DecisionUndoEntry: Codable, Equatable, Identifiable, Sendable {
    private enum CodingKeys: String, CodingKey { case id, assetID, previousDecision, replacementDecision, taskID, previousTaskIndex, previousTaskStatus, previousOwnedAssetIDs, createdAt }
    let id: UUID
    let assetID: String
    let previousDecision: PhotoDecision?
    let replacementDecision: PhotoDecision
    let taskID: String?
    let previousTaskIndex: Int?
    let previousTaskStatus: CleanupTaskStatus?
    let previousOwnedAssetIDs: [String]?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        assetID: String,
        previousDecision: PhotoDecision?,
        replacementDecision: PhotoDecision,
        taskID: String?,
        previousTaskIndex: Int?,
        previousTaskStatus: CleanupTaskStatus? = nil,
        previousOwnedAssetIDs: [String]? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.assetID = assetID
        self.previousDecision = previousDecision
        self.replacementDecision = replacementDecision
        self.taskID = taskID
        self.previousTaskIndex = previousTaskIndex
        self.previousTaskStatus = previousTaskStatus
        self.previousOwnedAssetIDs = previousOwnedAssetIDs
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        assetID = try values.decode(String.self, forKey: .assetID)
        previousDecision = try values.decodeIfPresent(PhotoDecision.self, forKey: .previousDecision)
        replacementDecision = try values.decode(PhotoDecision.self, forKey: .replacementDecision)
        taskID = try values.decodeIfPresent(String.self, forKey: .taskID)
        previousTaskIndex = try values.decodeIfPresent(Int.self, forKey: .previousTaskIndex)
        previousTaskStatus = try values.decodeIfPresent(CleanupTaskStatus.self, forKey: .previousTaskStatus)
        previousOwnedAssetIDs = try values.decodeIfPresent([String].self, forKey: .previousOwnedAssetIDs)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
    }
}

nonisolated enum DecisionUndoOutcome: Equatable, Sendable {
    case restored
    case requiresRecentlyDeleted
    case nothingToUndo
}
