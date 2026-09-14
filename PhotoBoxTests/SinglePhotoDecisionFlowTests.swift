import Foundation
import Testing
@testable import PhotoBox

@Suite("Single-photo decisions")
@MainActor
struct SinglePhotoDecisionFlowTests {
    @Test("A direct delete persists the displayed asset and advances exactly once")
    func directDecisionPersistsCurrentAssetAndAdvances() throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let task = makeTask(assetIDs: ["first", "second"])
        try repository.save(task: task)
        let activeTask = try TaskLifecycleController(repository: repository).start(taskID: task.id)
        let flow = SinglePhotoDecisionFlow(
            task: activeTask,
            descriptors: [descriptor(id: "first", bytes: 4_000), descriptor(id: "second", bytes: 2_000)],
            decisionWorkflow: DecisionWorkflow(repository: repository)
        )

        try flow.decide(.deleteCandidate)

        let decision = try repository.decision(for: "first")
        #expect(decision?.kind == .deleteCandidate)
        #expect(decision?.taskID == task.id)
        #expect(decision?.estimatedBytes == 4_000)
        #expect(flow.currentDescriptor?.id == "second")
        #expect(flow.pendingDecisionCount == 1)
        #expect(flow.estimatedReclaimableBytes == 4_000)
    }

    @Test("A screenshot batch marks safe remaining items and completes the task")
    func screenshotBatchDecisionCompletesSafeItems() throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let task = makeTask(assetIDs: ["first", "second"])
        try repository.save(task: task)
        let activeTask = try TaskLifecycleController(repository: repository).start(taskID: task.id)
        let flow = SinglePhotoDecisionFlow(
            task: activeTask,
            descriptors: [
                descriptor(id: "first", bytes: 4_000),
                descriptor(id: "second", bytes: 2_000)
            ],
            decisionWorkflow: DecisionWorkflow(repository: repository)
        )

        #expect(flow.canBatchDeleteRemaining)
        try flow.decideRemainingAsDeleteCandidate()

        #expect(flow.isCompleted)
        #expect(flow.pendingDecisionCount == 2)
        #expect(flow.deleteCandidateCount == 2)
        #expect(try repository.decision(for: "first")?.kind == .deleteCandidate)
        #expect(try repository.decision(for: "second")?.kind == .deleteCandidate)
    }

    @Test("A screenshot batch keeps successful progress when a later item fails")
    func screenshotBatchFailureKeepsRecoverableProgress() throws {
        let task = makeTask(assetIDs: ["first", "second", "third"])
        let workflow = FailingAfterApplyingWorkflow(failAt: 2)
        let flow = SinglePhotoDecisionFlow(
            task: task,
            descriptors: [
                descriptor(id: "first", bytes: 4_000),
                descriptor(id: "second", bytes: 2_000),
                descriptor(id: "third", bytes: 1_000)
            ],
            decisionWorkflow: workflow
        )

        #expect(throws: DecisionFlowError.persistenceFailed) {
            try flow.decideRemainingAsDeleteCandidate()
        }
        #expect(flow.currentDescriptor?.id == "second")
        #expect(flow.pendingDecisionCount == 1)
        #expect(flow.deleteCandidateCount == 1)
        #expect(flow.canUndo)
        #expect(!flow.isCompleted)
        #expect(workflow.appliedAssetIDs == ["first", "second"])
    }

    @Test("A screenshot batch is unavailable when a favorite remains")
    func screenshotBatchExcludesFavorite() throws {
        let flow = SinglePhotoDecisionFlow(
            task: makeTask(assetIDs: ["favorite"]),
            descriptors: [descriptor(id: "favorite", bytes: 1_000, isFavorite: true)],
            decisionWorkflow: FailingSingleDecisionWorkflow()
        )

        #expect(!flow.canBatchDeleteRemaining)
        #expect(throws: DecisionFlowError.batchUnavailable) {
            try flow.decideRemainingAsDeleteCandidate()
        }
    }

    @Test("The final direct decision completes the task and undo restores its asset")
    func finalDecisionCompletesAndUndoRestoresInProgressTask() throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let task = makeTask(assetIDs: ["last"])
        try repository.save(task: task)
        let activeTask = try TaskLifecycleController(repository: repository).start(taskID: task.id)
        let flow = SinglePhotoDecisionFlow(
            task: activeTask,
            descriptors: [descriptor(id: "last", bytes: 7_000)],
            decisionWorkflow: DecisionWorkflow(repository: repository)
        )

        try flow.decide(.keep)
        #expect(try repository.tasks().first?.status == .completed)
        #expect(flow.isCompleted)

        try flow.undo()
        let restored = try #require(repository.tasks().first)
        #expect(restored.status == .inProgress)
        #expect(restored.currentAssetIndex == 0)
        #expect(restored.ownedAssetIDs == ["last"])
        #expect(try repository.decision(for: "last") == nil)
        #expect(flow.currentDescriptor?.id == "last")
        #expect(!flow.isCompleted)
    }

    @Test("A persistence failure leaves the displayed asset and totals unchanged")
    func persistenceFailureDoesNotAdvanceOrComplete() throws {
        let task = makeTask(assetIDs: ["first", "second"])
        let failingWorkflow = FailingSingleDecisionWorkflow()
        let flow = SinglePhotoDecisionFlow(
            task: task,
            descriptors: [descriptor(id: "first", bytes: 4_000), descriptor(id: "second", bytes: 2_000)],
            decisionWorkflow: failingWorkflow
        )

        #expect(throws: DecisionFlowError.persistenceFailed) {
            try flow.decide(.deleteCandidate)
        }
        #expect(flow.currentDescriptor?.id == "first")
        #expect(flow.pendingDecisionCount == 0)
        #expect(flow.estimatedReclaimableBytes == 0)
        #expect(!flow.isCompleted)
    }

    @Test("Archive requests album selection without persisting or advancing")
    func archiveRequestsAlbumSelectionWithoutDecision() throws {
        var archiveAssetID: String?
        let flow = SinglePhotoDecisionFlow(
            task: makeTask(assetIDs: ["first", "second"]),
            descriptors: [descriptor(id: "first", bytes: 4_000), descriptor(id: "second", bytes: 2_000)],
            decisionWorkflow: FailingSingleDecisionWorkflow(),
            onArchiveRequested: { archiveAssetID = $0 }
        )

        flow.requestArchive()

        #expect(archiveAssetID == "first")
        #expect(flow.currentDescriptor?.id == "first")
        #expect(flow.pendingDecisionCount == 0)
    }

    @Test("Delete totals return to their prior values after undo")
    func deleteTotalsReturnAfterUndo() throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let task = makeTask(assetIDs: ["first", "second"])
        try repository.save(task: task)
        let activeTask = try TaskLifecycleController(repository: repository).start(taskID: task.id)
        let flow = SinglePhotoDecisionFlow(
            task: activeTask,
            descriptors: [descriptor(id: "first", bytes: 4_000), descriptor(id: "second", bytes: 2_000)],
            decisionWorkflow: DecisionWorkflow(repository: repository)
        )

        try flow.decide(.deleteCandidate)
        try flow.undo()

        #expect(flow.pendingDecisionCount == 0)
        #expect(flow.deleteCandidateCount == 0)
        #expect(flow.estimatedReclaimableBytes == 0)
    }

    @Test("A reconstructed completed flow keeps undo available and restores the final asset")
    func reconstructedCompletedFlowRestoresUndo() throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let task = makeTask(assetIDs: ["last"])
        try repository.save(task: task)
        let active = try TaskLifecycleController(repository: repository).start(taskID: task.id)
        let workflow = DecisionWorkflow(repository: repository)
        try workflow.apply(PhotoDecision(assetID: "last", kind: .keep, taskID: task.id))
        let completed = try #require(repository.tasks().first)
        let restored = SinglePhotoDecisionFlow(
            task: completed,
            descriptors: [descriptor(id: "last", bytes: 7_000)],
            decisionWorkflow: workflow,
            existingDecisions: try repository.decisions(),
            hasReversibleUndo: true
        )

        #expect(active.status == .inProgress)
        #expect(restored.isCompleted)
        #expect(restored.canUndo)
        try restored.undo()
        #expect(restored.currentDescriptor?.id == "last")
    }

    @Test("AppModel reconstruction exposes the persisted undo for its task")
    func appModelReconstructionRestoresUndo() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let task = makeTask(assetIDs: ["last"])
        try repository.save(task: task)
        let active = try TaskLifecycleController(repository: repository).start(taskID: task.id)
        try DecisionWorkflow(repository: repository).apply(
            PhotoDecision(assetID: "last", kind: .keep, taskID: task.id)
        )
        let model = AppModel(library: DecisionReader(), repository: repository)

        await model.prepareSingleDecision(taskID: task.id)

        #expect(active.status == .inProgress)
        let flow = try #require(model.singleDecisionFlow(for: task.id))
        #expect(flow.isCompleted)
        #expect(flow.canUndo)
        try flow.undo()
        #expect(flow.currentDescriptor?.id == "last")
    }

    @Test("Relaunch retains a reversible final decision without replacing home")
    func relaunchRoutesToReversibleCompletedTask() throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let task = makeTask(assetIDs: ["last"])
        try repository.save(task: task)
        _ = try TaskLifecycleController(repository: repository).start(taskID: task.id)
        try DecisionWorkflow(repository: repository).apply(PhotoDecision(assetID: "last", kind: .keep, taskID: task.id))

        let model = AppModel(library: DecisionReader(), repository: repository)

        #expect(model.activeRoute == nil)
        #expect(model.taskNavigationPath.isEmpty)
        #expect(try repository.latestUndo()?.taskID == task.id)
    }

    @Test("Submitted final decisions do not restore a route or undo")
    func submittedDecisionDoesNotRestoreUndo() throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let task = makeTask(assetIDs: ["last"])
        try repository.save(task: task)
        _ = try TaskLifecycleController(repository: repository).start(taskID: task.id)
        let workflow = DecisionWorkflow(repository: repository)
        try workflow.apply(PhotoDecision(assetID: "last", kind: .keep, taskID: task.id))
        try workflow.markSubmitted(assetID: "last")

        let model = AppModel(library: DecisionReader(), repository: repository)

        #expect(model.activeRoute == nil)
    }

    @Test("Recently Deleted undo clears the affordance and preserves its domain outcome")
    func recentlyDeletedUndoOutcomePropagates() throws {
        let flow = SinglePhotoDecisionFlow(
            task: makeTask(assetIDs: ["asset"]),
            descriptors: [descriptor(id: "asset", bytes: 1)],
            decisionWorkflow: RecentlyDeletedWorkflow(),
            hasReversibleUndo: true
        )

        #expect(throws: DecisionFlowError.requiresRecentlyDeleted) { try flow.undo() }
        #expect(!flow.canUndo)
    }

    @Test("Undo restores the exact ownership snapshot without duplicating another task")
    func undoRestoresSnapshotWithoutDuplicateOwnership() throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        var first = makeTask(assetIDs: ["shared", "unowned"])
        first.ownedAssetIDs = ["shared"]
        first.status = .inProgress
        try repository.save(task: first)
        try DecisionWorkflow(repository: repository).apply(
            PhotoDecision(assetID: "shared", kind: .keep, taskID: first.id)
        )
        var second = CleanupTask(
            id: "second", type: .screenshots, title: "第二任务", reason: "测试",
            assetIDs: ["shared"], estimatedBytes: 0, estimatedMinutes: 1,
            risk: .low, confidence: 1
        )
        second.status = .inProgress
        second.ownedAssetIDs = ["shared"]
        try repository.save(task: second)

        _ = try DecisionWorkflow(repository: repository).undoLatest()

        let restored = try #require(repository.tasks().first(where: { $0.id == first.id }))
        #expect(restored.status == .inProgress)
        #expect(restored.ownedAssetIDs == [])
        #expect(Set(restored.ownedAssetIDs).isDisjoint(with: Set(second.ownedAssetIDs)))
    }

    private func makeTask(assetIDs: [String]) -> CleanupTask {
        CleanupTask(
            id: "task",
            type: .screenshots,
            title: "测试任务",
            reason: "测试",
            assetIDs: assetIDs,
            estimatedBytes: 6_000,
            estimatedMinutes: 1,
            risk: .low,
            confidence: 1,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func descriptor(
        id: String,
        bytes: Int64,
        isFavorite: Bool = false
    ) -> PhotoAssetDescriptor {
        PhotoAssetDescriptor(
            id: id,
            mediaType: .photo,
            creationDate: Date(timeIntervalSince1970: 1_000),
            pixelWidth: 1_200,
            pixelHeight: 900,
            duration: 0,
            estimatedBytes: bytes,
            isFavorite: isFavorite,
            isEdited: false,
            isScreenshot: true,
            burstIdentifier: nil,
            availability: .local
        )
    }
}

private actor DecisionReader: PhotoLibraryReading {
    func authorizationStatus() -> PhotoAuthorization { .authorized }
    func requestAuthorization() -> PhotoAuthorization { .authorized }
    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> { AsyncStream { $0.finish() } }
    func accessibleAssetDescriptors() -> [PhotoAssetDescriptor] { [
        PhotoAssetDescriptor(id: "last", mediaType: .photo, creationDate: nil, pixelWidth: 1, pixelHeight: 1, duration: 0, estimatedBytes: 7_000, isFavorite: false, isEdited: false, isScreenshot: true, burstIdentifier: nil, availability: .local)
    ] }
}

@MainActor
private final class FailingSingleDecisionWorkflow: SingleDecisionApplying {
    func apply(_ decision: PhotoDecision) throws {
        throw DecisionFlowError.persistenceFailed
    }

    func undoLatest() throws -> DecisionUndoOutcome {
        .nothingToUndo
    }
}

@MainActor
private final class FailingAfterApplyingWorkflow: SingleDecisionApplying {
    let failAt: Int
    private(set) var appliedAssetIDs: [String] = []

    init(failAt: Int) {
        self.failAt = failAt
    }

    func apply(_ decision: PhotoDecision) throws {
        let nextIndex = appliedAssetIDs.count + 1
        appliedAssetIDs.append(decision.assetID)
        if nextIndex == failAt {
            throw DecisionFlowError.persistenceFailed
        }
    }

    func undoLatest() throws -> DecisionUndoOutcome {
        .restored
    }
}

@MainActor
private final class RecentlyDeletedWorkflow: SingleDecisionApplying {
    func apply(_ decision: PhotoDecision) throws {}
    func undoLatest() throws -> DecisionUndoOutcome { .requiresRecentlyDeleted }
}
