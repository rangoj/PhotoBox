import Foundation
import Observation

nonisolated enum DecisionFlowError: Error, Equatable {
    case persistenceFailed
    case noCurrentAsset
    case requiresRecentlyDeleted
    case batchUnavailable
    case operationInFlight
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
    private let onArchivePreviewRequested: ((String) -> Void)?
    private let onFavoriteRequested: ((String, Bool) -> Void)?
    private let onSelectionChanged: ((Int) throws -> Void)?
    private var eligibleAssetIDs: Set<String>?
    private var undoAssetID: String?
    private var undoPreviousDecision: PhotoDecision?
    private var favoriteOverrides: [String: Bool] = [:]
    private var favoriteInFlightAssetID: String?

    private(set) var currentIndex: Int
    private(set) var decisions: [String: PhotoDecision] = [:]
    private(set) var isCompleted: Bool
    private(set) var canUndo = false
    private(set) var isFavoriteOperationInFlight = false
    private(set) var favoriteErrorMessage: String?

    init(
        task: CleanupTask,
        descriptors: [PhotoAssetDescriptor],
        decisionWorkflow: any SingleDecisionApplying,
        existingDecisions: [PhotoDecision] = [],
        hasReversibleUndo: Bool = false,
        eligibleAssetIDs: Set<String>? = nil,
        undoAssetID: String? = nil,
        undoPreviousDecision: PhotoDecision? = nil,
        onDecisionsChanged: (() -> Void)? = nil,
        onArchiveRequested: ((String) -> Void)? = nil,
        onArchivePreviewRequested: ((String) -> Void)? = nil,
        onFavoriteRequested: ((String, Bool) -> Void)? = nil,
        onSelectionChanged: ((Int) throws -> Void)? = nil
    ) {
        self.task = task
        self.descriptors = descriptors
        self.decisionWorkflow = decisionWorkflow
        self.onDecisionsChanged = onDecisionsChanged
        self.onArchiveRequested = onArchiveRequested
        self.onArchivePreviewRequested = onArchivePreviewRequested
        self.onFavoriteRequested = onFavoriteRequested
        self.onSelectionChanged = onSelectionChanged
        self.eligibleAssetIDs = eligibleAssetIDs
        self.undoAssetID = undoAssetID
        self.undoPreviousDecision = undoPreviousDecision
        currentIndex = min(task.currentAssetIndex, max(descriptors.count - 1, 0))
        decisions = Dictionary(uniqueKeysWithValues: existingDecisions.map { ($0.assetID, $0) })
        isCompleted = false
        canUndo = hasReversibleUndo
        normalizeCursor(preferredIndex: task.currentAssetIndex)
    }

    var currentDescriptor: PhotoAssetDescriptor? {
        descriptors.indices.contains(currentIndex) ? descriptors[currentIndex] : nil
    }

    var allDescriptors: [PhotoAssetDescriptor] { descriptors }

    /// The current session may end before the fixed batch is complete when assets become unavailable.
    var isSessionExhausted: Bool {
        !isFavoriteOperationInFlight && firstUndecidedIndex(startingAt: 0) == nil
    }

    var isCurrentFavorite: Bool {
        guard let descriptor = currentDescriptor else { return false }
        return favoriteOverrides[descriptor.id] ?? descriptor.isFavorite
    }

    func requestFavoriteToggle() {
        guard let descriptor = currentDescriptor,
              isSelectable(index: currentIndex), let onFavoriteRequested else { return }
        isFavoriteOperationInFlight = true
        favoriteInFlightAssetID = descriptor.id
        favoriteErrorMessage = nil
        onFavoriteRequested(descriptor.id, !isCurrentFavorite)
    }

    func recordFavoriteResult(assetID: String, isFavorite: Bool, succeeded: Bool) {
        guard isFavoriteOperationInFlight, favoriteInFlightAssetID == assetID else { return }
        isFavoriteOperationInFlight = false
        favoriteInFlightAssetID = nil
        if !succeeded { favoriteErrorMessage = "无法更新收藏状态，请重试。" }
        else {
            favoriteOverrides[assetID] = isFavorite
            favoriteErrorMessage = nil
        }
        normalizeCursor(preferredIndex: currentIndex)
        onDecisionsChanged?()
    }

    @discardableResult
    func select(index: Int) -> Bool {
        guard !isFavoriteOperationInFlight,
              isSelectable(index: index) else { return false }
        guard index != currentIndex else { return true }
        let previousIndex = currentIndex
        let previousCompletion = isCompleted
        do {
            try onSelectionChanged?(index)
        } catch {
            currentIndex = previousIndex
            isCompleted = previousCompletion
            return false
        }
        currentIndex = index
        isCompleted = allPhotosDecided
        return true
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
              !isCompleted else { return false }
        let remaining = descriptors.filter { decisions[$0.id] == nil }
        return !remaining.isEmpty && remaining.allSatisfy {
            $0.availability == .local && !$0.isFavorite && !$0.isEdited
        }
    }

    func decide(_ kind: PhotoDecisionKind) throws {
        guard !isFavoriteOperationInFlight else { throw DecisionFlowError.operationInFlight }
        guard kind != .archive, let descriptor = currentDescriptor,
              isSelectable(index: currentIndex) else {
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

        undoAssetID = descriptor.id
        undoPreviousDecision = decisions[descriptor.id]
        decisions[descriptor.id] = decision
        advanceToNextUndecided(after: currentIndex)
        canUndo = true
        onDecisionsChanged?()
    }

    func decideRemainingAsDeleteCandidate() throws {
        guard !isFavoriteOperationInFlight else { throw DecisionFlowError.operationInFlight }
        guard canBatchDeleteRemaining else { throw DecisionFlowError.batchUnavailable }
        let remaining = descriptors.indices
            .filter { isSelectable(index: $0) && decisions[descriptors[$0].id] == nil }
            .sorted { orderedDistance(from: currentIndex, to: $0) < orderedDistance(from: currentIndex, to: $1) }
        for (offset, index) in remaining.enumerated() {
            let descriptor = descriptors[index]
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
                currentIndex = index
                isCompleted = false
                canUndo = offset > 0
                if offset > 0 {
                    onDecisionsChanged?()
                }
                throw DecisionFlowError.persistenceFailed
            }
            decisions[descriptor.id] = decision
            undoAssetID = descriptor.id
            undoPreviousDecision = nil
            currentIndex = index
        }
        isCompleted = allPhotosDecided
        canUndo = true
        onDecisionsChanged?()
    }

    func requestArchive() {
        guard isSelectable(index: currentIndex) else { return }
        guard let assetID = currentDescriptor?.id else { return }
        onArchiveRequested?(assetID)
    }

    func requestArchivePreview() {
        guard isSelectable(index: currentIndex) else { return }
        guard let assetID = currentDescriptor?.id else { return }
        onArchivePreviewRequested?(assetID)
    }

    func recordArchiveSuccess(_ decision: PhotoDecision) {
        guard !isFavoriteOperationInFlight else { return }
        guard decision.kind == .archive,
              decision.isSubmitted,
              decision.taskID == task.id,
              currentDescriptor?.id == decision.assetID else { return }
        decisions[decision.assetID] = decision
        advanceToNextUndecided(after: currentIndex)
        canUndo = false
        onDecisionsChanged?()
    }

    func undo() throws {
        guard !isFavoriteOperationInFlight else { throw DecisionFlowError.operationInFlight }
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
        if let undoAssetID, let index = descriptors.firstIndex(where: { $0.id == undoAssetID }) {
            currentIndex = index
            eligibleAssetIDs?.insert(undoAssetID)
        } else {
            currentIndex = max(currentIndex - 1, 0)
        }
        if let undoAssetID {
            if let undoPreviousDecision {
                decisions[undoAssetID] = undoPreviousDecision
            } else {
                decisions.removeValue(forKey: undoAssetID)
            }
        }
        undoPreviousDecision = nil
        isCompleted = allPhotosDecided
        canUndo = false
        onDecisionsChanged?()
    }

    func updateEligibility(_ assetIDs: Set<String>) {
        guard task.type == .dateBatch else { return }
        eligibleAssetIDs = assetIDs
        guard !isFavoriteOperationInFlight else { return }
        normalizeCursor(preferredIndex: currentIndex)
    }

    private var allPhotosDecided: Bool {
        !descriptors.isEmpty && descriptors.allSatisfy { decisions[$0.id] != nil }
    }

    private func isEligible(_ descriptor: PhotoAssetDescriptor) -> Bool {
        eligibleAssetIDs?.contains(descriptor.id) ?? true
    }

    private func isSelectable(index: Int) -> Bool {
        guard descriptors.indices.contains(index), !isFavoriteOperationInFlight else { return false }
        let descriptor = descriptors[index]
        guard isEligible(descriptor) else { return false }
        guard let decision = decisions[descriptor.id] else { return true }
        return !decision.isSubmitted
    }

    private func normalizeCursor(preferredIndex: Int) {
        guard !descriptors.isEmpty else {
            currentIndex = 0
            isCompleted = false
            return
        }
        let start = min(max(preferredIndex, 0), descriptors.count - 1)
        if descriptors.indices.contains(preferredIndex), isSelectable(index: preferredIndex) {
            currentIndex = preferredIndex
        } else if let next = firstUndecidedIndex(startingAt: start) {
            currentIndex = next
        } else {
            currentIndex = descriptors.indices.first(where: { isSelectable(index: $0) }) ?? descriptors.count
        }
        isCompleted = allPhotosDecided
    }

    private func advanceToNextUndecided(after index: Int) {
        if let next = firstUndecidedIndex(startingAt: (index + 1) % max(descriptors.count, 1)) {
            currentIndex = next
        }
        isCompleted = allPhotosDecided
    }

    private func firstUndecidedIndex(startingAt start: Int) -> Int? {
        guard !descriptors.isEmpty else { return nil }
        let normalizedStart = ((start % descriptors.count) + descriptors.count) % descriptors.count
        for offset in 0..<descriptors.count {
            let index = (normalizedStart + offset) % descriptors.count
            let descriptor = descriptors[index]
            if isEligible(descriptor), decisions[descriptor.id] == nil { return index }
        }
        return nil
    }

    private func orderedDistance(from start: Int, to target: Int) -> Int {
        guard !descriptors.isEmpty else { return 0 }
        return (target - start + descriptors.count) % descriptors.count
    }
}
