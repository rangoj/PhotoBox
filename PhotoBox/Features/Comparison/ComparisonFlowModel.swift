import Foundation
import Observation

nonisolated enum ComparisonFlowError: Error, Equatable {
    case keepSelectionRequired
}

@MainActor
@Observable
final class ComparisonFlowModel {
    private let groups: [PhotoCandidateGroup]
    private let recommendations: [String: PhotoGroupRecommendation]
    private let decisionWorkflow: any ComparisonGroupDecisionApplying
    private let onDecisionsChanged: (() -> Void)?
    private let taskID: String?
    private let minimumRecommendationConfidence: Double

    private(set) var currentGroupIndex = 0
    private(set) var selectedKeepID: String?
    private(set) var hasExplicitKeepSelection = false
    private(set) var deleteCandidateCount = 0
    private(set) var estimatedReclaimableBytes: Int64 = 0

    init(
        groups: [PhotoCandidateGroup],
        recommendations: [PhotoGroupRecommendation],
        decisionWorkflow: any ComparisonGroupDecisionApplying,
        taskID: String? = nil,
        minimumRecommendationConfidence: Double = 0.5,
        onDecisionsChanged: (() -> Void)? = nil
    ) {
        self.groups = groups
        self.recommendations = Dictionary(
            uniqueKeysWithValues: recommendations.map { ($0.groupID, $0) }
        )
        self.decisionWorkflow = decisionWorkflow
        self.taskID = taskID
        self.minimumRecommendationConfidence = minimumRecommendationConfidence
        self.onDecisionsChanged = onDecisionsChanged
        prepareCurrentGroup()
    }

    var currentGroup: PhotoCandidateGroup? {
        groups.indices.contains(currentGroupIndex) ? groups[currentGroupIndex] : nil
    }

    var currentRecommendation: PhotoGroupRecommendation? {
        currentGroup.flatMap { recommendations[$0.id] }
    }

    var displayedRecommendation: PhotoGroupRecommendation? {
        guard !isRecommendationOverridden else { return nil }
        return confidentRecommendation
    }

    var groupPositionText: String {
        "第 \(min(currentGroupIndex + 1, groups.count)) 组，共 \(groups.count) 组"
    }

    var isLowConfidence: Bool {
        confidentRecommendation == nil
    }

    var isRecommendationOverridden: Bool {
        guard let recommendedKeepID = confidentRecommendation?.recommendedKeepID else { return false }
        return selectedKeepID != nil && selectedKeepID != recommendedKeepID
    }

    var selectedKeepIDs: Set<String> {
        guard let group = currentGroup else { return [] }
        var keepIDs = Set(group.protectedKeepIDs)
        if let selectedKeepID {
            keepIDs.insert(selectedKeepID)
        }
        return keepIDs
    }

    var canCompleteCurrentGroup: Bool {
        !isLowConfidence || hasExplicitKeepSelection
    }

    var isFinished: Bool {
        currentGroup == nil
    }

    func selectKeep(assetID: String) {
        guard currentGroup?.candidates.contains(where: { $0.id == assetID }) == true else { return }
        selectedKeepID = assetID
        hasExplicitKeepSelection = true
    }

    func completeCurrentGroup() throws {
        guard let group = currentGroup else { return }
        guard canCompleteCurrentGroup else { throw ComparisonFlowError.keepSelectionRequired }

        let keepIDs = selectedKeepIDs
        let decisions = group.candidates.map { candidate in
            let isKeep = keepIDs.contains(candidate.id)
            return PhotoDecision(
                assetID: candidate.id,
                kind: isKeep ? .keep : .deleteCandidate,
                estimatedBytes: isKeep ? 0 : candidate.asset.estimatedBytes,
                taskID: taskID
            )
        }
        if currentGroupIndex + 1 == groups.count, let taskID {
            try decisionWorkflow.completeGroup(decisions, taskID: taskID)
        } else {
            try decisionWorkflow.applyGroup(decisions)
        }

        let deletedCandidates = group.candidates.filter { !keepIDs.contains($0.id) }
        deleteCandidateCount += deletedCandidates.count
        estimatedReclaimableBytes += deletedCandidates.reduce(0) { $0 + $1.asset.estimatedBytes }

        currentGroupIndex += 1
        prepareCurrentGroup()
        onDecisionsChanged?()
    }

    private func prepareCurrentGroup() {
        guard let group = currentGroup else {
            selectedKeepID = nil
            hasExplicitKeepSelection = false
            return
        }
        selectedKeepID = confidentRecommendation(for: group)?.recommendedKeepID
        hasExplicitKeepSelection = false
    }

    private var confidentRecommendation: PhotoGroupRecommendation? {
        guard let group = currentGroup else { return nil }
        return confidentRecommendation(for: group)
    }

    private func confidentRecommendation(for group: PhotoCandidateGroup) -> PhotoGroupRecommendation? {
        guard let recommendation = recommendations[group.id],
              let recommendedKeepID = recommendation.recommendedKeepID,
              recommendation.confidence >= minimumRecommendationConfidence,
              !recommendation.reasons.isEmpty,
              let candidate = group.candidates.first(where: { $0.id == recommendedKeepID }),
              candidate.asset.availability == .local else { return nil }
        return recommendation
    }
}
