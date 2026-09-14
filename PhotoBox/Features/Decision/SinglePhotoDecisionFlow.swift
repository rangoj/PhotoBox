import Foundation
import Observation

nonisolated enum DecisionFlowError: Error, Equatable {
    case persistenceFailed
    case noCurrentAsset
    case requiresRecentlyDeleted
    case batchUnavailable
}

@MainActor
protocol SingleDecisionApplying: AnyObject {
    func apply(_ decision: PhotoDecision) throws
    func undoLatest() throws -> DecisionUndoOutcome
}

@MainActor
@Observable
final class SinglePhotoDecisionFlow {
    private let task: CleanupTask
    private let descriptors: [PhotoAssetDescriptor]
    private let decisionWorkflow: any SingleDecisionApplying
    private let onDecisionsChanged: (() -> Void)?
    private let onArchiveRequested: ((String) -> Void)?
    private var eligibleAssetIDs: Set<String>?
    private var undoAssetID: String?

    private(set) var currentIndex: Int
    private(set) var decisions: [String: PhotoDecision] = [:]
    private(set) var isCompleted: Bool
    private(set) var canUndo = false

    init(
        task: CleanupTask,
        descriptors: [PhotoAssetDescriptor],
        decisionWorkflow: any SingleDecisionApplying,
        existingDecisions: [PhotoDecision] = [],
        hasReversibleUndo: Bool = false,
        eligibleAssetIDs: Set<String>? = nil,
        undoAssetID: String? = nil,
        onDecisionsChanged: (() -> Void)? = nil,
        onArchiveRequested: ((String) -> Void)? = nil
    ) {
        self.task = task
        self.descriptors = descriptors
        self.decisionWorkflow = decisionWorkflow
        self.onDecisionsChanged = onDecisionsChanged
        self.onArchiveRequested = onArchiveRequested
        self.eligibleAssetIDs = eligibleAssetIDs
        self.undoAssetID = undoAssetID
        let initialIndex = min(task.currentAssetIndex, descriptors.count)
        currentIndex = initialIndex
        decisions = Dictionary(uniqueKeysWithValues: existingDecisions.map { ($0.assetID, $0) })
        isCompleted = task.status == .completed || initialIndex >= descriptors.count
        canUndo = hasReversibleUndo
        if task.type == .dateBatch { advancePastUnavailable() }
    }

    var currentDescriptor: PhotoAssetDescriptor? {
        descriptors.indices.contains(currentIndex) ? descriptors[currentIndex] : nil
    }

    var positionText: String {
        isCompleted ? "已完成，共 \(descriptors.count) 项" : "第 \(currentIndex + 1) 项，共 \(descriptors.count) 项"
    }

    var pendingDecisionCount: Int { decisions.count }
    var deleteCandidateCount: Int { decisions.values.count { $0.kind == .deleteCandidate } }
    var estimatedReclaimableBytes: Int64 {
        decisions.values
            .filter { $0.kind == .deleteCandidate }
            .reduce(0) { $0 + $1.estimatedBytes }
    }

    var canBatchDeleteRemaining: Bool {
        guard task.type == .screenshots,
              !isCompleted,
              currentIndex < descriptors.count else { return false }
        return descriptors[currentIndex...].allSatisfy {
            $0.availability == .local && !$0.isFavorite && !$0.isEdited
        }
    }

    func decide(_ kind: PhotoDecisionKind) throws {
        guard kind != .archive, let descriptor = currentDescriptor else {
            throw DecisionFlowError.noCurrentAsset
        }
        let decision = PhotoDecision(
            assetID: descriptor.id,
            kind: kind,
            estimatedBytes: kind == .deleteCandidate ? descriptor.estimatedBytes : descriptor.estimatedBytes,
            taskID: task.id
        )
        do {
            try decisionWorkflow.apply(decision)
        } catch {
            throw DecisionFlowError.persistenceFailed
        }

        decisions[descriptor.id] = decision
        undoAssetID = descriptor.id
        currentIndex += 1
        advancePastUnavailable()
        isCompleted = currentIndex >= descriptors.count
        canUndo = true
        onDecisionsChanged?()
    }

    func decideRemainingAsDeleteCandidate() throws {
        guard canBatchDeleteRemaining else { throw DecisionFlowError.batchUnavailable }
        let remaining = Array(descriptors[currentIndex...])
        for (offset, descriptor) in remaining.enumerated() {
            let decision = PhotoDecision(
                assetID: descriptor.id,
                kind: .deleteCandidate,
                estimatedBytes: descriptor.estimatedBytes,
                taskID: task.id
            )
            do {
                try decisionWorkflow.apply(decision)
            } catch {
                // Keep the in-memory cursor aligned with decisions already persisted.
                isCompleted = false
                canUndo = offset > 0
                if offset > 0 {
                    onDecisionsChanged?()
                }
                throw DecisionFlowError.persistenceFailed
            }
            decisions[descriptor.id] = decision
            currentIndex += 1
        }
        isCompleted = true
        canUndo = true
        onDecisionsChanged?()
    }

    func requestArchive() {
        guard let assetID = currentDescriptor?.id else { return }
        onArchiveRequested?(assetID)
    }

    func recordArchiveSuccess(_ decision: PhotoDecision) {
        guard decision.kind == .archive,
              decision.isSubmitted,
              decision.taskID == task.id,
              currentDescriptor?.id == decision.assetID else { return }
        decisions[decision.assetID] = decision
        currentIndex += 1
        advancePastUnavailable()
        isCompleted = currentIndex >= descriptors.count
        canUndo = false
        onDecisionsChanged?()
    }

    func undo() throws {
        let outcome: DecisionUndoOutcome
        do {
            outcome = try decisionWorkflow.undoLatest()
        } catch {
            throw DecisionFlowError.persistenceFailed
        }
        if outcome == .requiresRecentlyDeleted {
            canUndo = false
            throw DecisionFlowError.requiresRecentlyDeleted
        }
        guard outcome == .restored else { return }
        guard currentIndex > 0 else { return }
        if let undoAssetID, let index = descriptors.firstIndex(where: { $0.id == undoAssetID }) {
            currentIndex = index
            eligibleAssetIDs?.insert(undoAssetID)
        } else {
            currentIndex -= 1
        }
        if let assetID = currentDescriptor?.id {
            decisions.removeValue(forKey: assetID)
        }
        isCompleted = false
        canUndo = false
        onDecisionsChanged?()
    }

    func updateEligibility(_ assetIDs: Set<String>) {
        guard task.type == .dateBatch else { return }
        eligibleAssetIDs = assetIDs
        advancePastUnavailable()
    }

    private func advancePastUnavailable() {
        guard let eligibleAssetIDs else { return }
        while descriptors.indices.contains(currentIndex) {
            let descriptor = descriptors[currentIndex]
            if eligibleAssetIDs.contains(descriptor.id), decisions[descriptor.id] == nil { break }
            currentIndex += 1
        }
        isCompleted = currentIndex >= descriptors.count
    }
}
