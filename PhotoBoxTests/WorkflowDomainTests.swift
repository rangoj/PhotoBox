import Foundation
import Testing
@testable import PhotoBox

@Suite("Cleanup workflow domain")
struct WorkflowDomainTests {
    @Test("Asset descriptors have stable value equality")
    func assetDescriptorEquality() {
        let date = Date(timeIntervalSince1970: 1_000)
        let first = PhotoAssetDescriptor(
            id: "asset-1",
            mediaType: .photo,
            creationDate: date,
            pixelWidth: 4_032,
            pixelHeight: 3_024,
            duration: 0,
            estimatedBytes: 4_000_000,
            isFavorite: true,
            isEdited: false,
            isScreenshot: false,
            burstIdentifier: nil,
            availability: .local
        )

        #expect(first == first)
        #expect(first.id == "asset-1")
    }

    @Test("Protected evidence is never selected for deletion by default")
    func protectionPrecedence() {
        let regular = PhotoCandidate(
            asset: .fixture(id: "regular", isFavorite: false, isEdited: false),
            quality: .init(sharpness: 0.95, exposure: 0.95, completeness: 0.95),
            manualProtection: false
        )
        let protected = PhotoCandidate(
            asset: .fixture(id: "protected", isFavorite: false, isEdited: false),
            quality: .init(sharpness: 0.4, exposure: 0.4, completeness: 0.4),
            manualProtection: true
        )
        let favorite = PhotoCandidate(
            asset: .fixture(id: "favorite", isFavorite: true, isEdited: false),
            quality: .init(sharpness: 0.2, exposure: 0.2, completeness: 0.2),
            manualProtection: false
        )

        let group = PhotoCandidateGroup(
            id: "group-1",
            kind: .similar,
            candidates: [regular, protected, favorite]
        )

        #expect(group.defaultDeleteIDs == ["regular"])
        #expect(group.protectedKeepIDs == ["protected", "favorite"])
    }

    @Test("Cleanup summary aggregates only delete candidate estimates")
    func estimatedSpaceAggregation() {
        let decisions = [
            PhotoDecision(assetID: "a", kind: .deleteCandidate, estimatedBytes: 3_000),
            PhotoDecision(assetID: "b", kind: .keep, estimatedBytes: 5_000),
            PhotoDecision(assetID: "c", kind: .deleteCandidate, estimatedBytes: 7_000)
        ]

        let summary = CleanupSummary(decisions: decisions, elapsedSeconds: 12)

        #expect(summary.deleteCandidateCount == 2)
        #expect(summary.estimatedReclaimableBytes == 10_000)
        #expect(summary.keptCount == 1)
    }
}

@Suite("Persistent workflow repository")
@MainActor
struct WorkflowRepositoryTests {
    @Test("Repository round trip persists identifiers and decisions")
    func decisionRoundTrip() throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let decision = PhotoDecision(
            assetID: "asset-1",
            kind: .archive,
            estimatedBytes: 900,
            targetAlbumID: "album-1"
        )

        try repository.save(decision: decision)

        #expect(try repository.decision(for: "asset-1") == decision)
        let serialized = try #require(String(data: repository.serializedStateForTesting(), encoding: .utf8))
        #expect(!serialized.localizedCaseInsensitiveContains("filename"))
        #expect(!serialized.localizedCaseInsensitiveContains("location"))
        #expect(!serialized.localizedCaseInsensitiveContains("featureVector"))
        #expect(!serialized.localizedCaseInsensitiveContains("ocr"))
    }

    @Test("Reconciliation removes only inaccessible identifiers")
    func reconcileAssets() throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        try repository.save(decision: PhotoDecision(assetID: "gone", kind: .keep))
        try repository.save(decision: PhotoDecision(assetID: "present", kind: .protect))

        try repository.reconcile(availableAssetIDs: ["present"])

        #expect(try repository.decision(for: "gone") == nil)
        #expect(try repository.decision(for: "present")?.kind == .protect)
    }

    @Test("Clearing history cannot mutate the photo library")
    func clearHistoryIsLocalOnly() throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        try repository.save(decision: PhotoDecision(assetID: "asset-1", kind: .deleteCandidate))
        try repository.save(summary: CleanupSummary(
            decisions: [PhotoDecision(assetID: "asset-1", kind: .deleteCandidate)],
            elapsedSeconds: 5
        ))

        try repository.clearHistory()

        #expect(try repository.decision(for: "asset-1") == nil)
        #expect(try repository.summaries().isEmpty)
    }

    @Test("Versioned repository round trips every workflow record type")
    func completeSchemaRoundTrip() throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let checkpoint = ScanCheckpoint(
            id: "scan-1",
            stage: .analyzing,
            processedAssetIDs: ["asset-1"],
            discoveredCount: 2,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let task = CleanupTask(
            id: "task-1",
            type: .similar,
            title: "相似照片",
            reason: "拍摄时间和画面接近",
            assetIDs: ["asset-1", "asset-2"],
            estimatedBytes: 8_000,
            estimatedMinutes: 2,
            risk: .medium,
            confidence: 0.8
        )
        let transaction = MutationTransaction(
            id: "mutation-1",
            operation: .delete,
            items: [MutationItem(assetID: "asset-1", state: .pending)]
        )
        var settings = WorkflowSettings.defaults
        settings.weeklyModeEnabled = true
        settings.recentAlbumIDs = ["album-1"]

        try repository.save(checkpoint: checkpoint)
        try repository.save(task: task)
        try repository.save(transaction: transaction)
        try repository.save(settings: settings)

        #expect(try repository.latestCheckpoint() == checkpoint)
        #expect(try repository.tasks() == [task])
        #expect(try repository.transactions() == [transaction])
        #expect(try repository.settings() == settings)
        #expect(SwiftDataTaskRepository.schemaVersion == "1.0.0")
    }

    @Test("Reconciliation updates tasks and mutation journals without substituting assets")
    func completeReconciliation() throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        try repository.save(task: CleanupTask(
            id: "task",
            type: .weekly,
            title: "本周新增",
            reason: "本周尚未整理",
            assetIDs: ["gone", "present"],
            estimatedBytes: 2_000,
            estimatedMinutes: 1,
            risk: .low,
            confidence: 1
        ))
        try repository.save(transaction: MutationTransaction(
            id: "mutation",
            operation: .delete,
            items: [
                MutationItem(assetID: "gone", state: .pending),
                MutationItem(assetID: "present", state: .pending)
            ]
        ))

        try repository.reconcile(availableAssetIDs: ["present"])

        #expect(try repository.tasks().first?.assetIDs == ["present"])
        #expect(try repository.transactions().first?.items == [
            MutationItem(assetID: "gone", state: .stale),
            MutationItem(assetID: "present", state: .pending)
        ])
    }

    @Test("Reconciliation invalidates a task when all of its assets disappear")
    func reconciliationInvalidatesEmptyTask() throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        try repository.save(task: CleanupTask(
            id: "scan:screenshots", type: .screenshots, title: "截图",
            reason: "测试", assetIDs: ["gone"], estimatedBytes: 1_000,
            estimatedMinutes: 1, risk: .low, confidence: 1
        ))

        try repository.reconcile(availableAssetIDs: [])

        let task = try #require(repository.tasks().first)
        #expect(task.status == .invalid)
        #expect(task.assetIDs.isEmpty)
        #expect(task.ownedAssetIDs.isEmpty)
    }
}

private extension PhotoAssetDescriptor {
    static func fixture(id: String, isFavorite: Bool, isEdited: Bool) -> PhotoAssetDescriptor {
        PhotoAssetDescriptor(
            id: id,
            mediaType: .photo,
            creationDate: Date(timeIntervalSince1970: 1_000),
            pixelWidth: 1_000,
            pixelHeight: 1_000,
            duration: 0,
            estimatedBytes: 1_000,
            isFavorite: isFavorite,
            isEdited: isEdited,
            isScreenshot: false,
            burstIdentifier: nil,
            availability: .local
        )
    }
}
