import Foundation
import Testing
@testable import PhotoBox

@Suite("Similar and burst comparison flow")
@MainActor
struct ComparisonFlowTests {
    @Test("Invalid or unreasoned recommendations require an explicit keep choice")
    func unsafeRecommendationsBecomeLowConfidence() throws {
        let group = PhotoCandidateGroup(
            id: "group",
            kind: .similar,
            candidates: [
                candidate(id: "first", bytes: 8_000, sharpness: 0.9),
                candidate(id: "second", bytes: 5_000, sharpness: 0.2)
            ]
        )
        let workflow = DecisionWorkflow(repository: try SwiftDataTaskRepository(inMemory: true))
        let unsafeRecommendations = [
            PhotoGroupRecommendation(
                groupID: group.id,
                recommendedKeepID: "missing",
                reasons: [.sharper],
                confidence: 1
            ),
            PhotoGroupRecommendation(
                groupID: group.id,
                recommendedKeepID: "first",
                reasons: [],
                confidence: 1
            ),
            PhotoGroupRecommendation(
                groupID: group.id,
                recommendedKeepID: "first",
                reasons: [.sharper],
                confidence: 0
            )
        ]

        for recommendation in unsafeRecommendations {
            let flow = ComparisonFlowModel(
                groups: [group],
                recommendations: [recommendation],
                decisionWorkflow: workflow
            )

            #expect(flow.isLowConfidence)
            #expect(flow.selectedKeepIDs.isEmpty)
            #expect(!flow.canCompleteCurrentGroup)
        }
    }

    @Test("Changing the recommended keep removes the algorithm reason from the selected item")
    func editedKeepDistinguishesUserChoiceFromRecommendation() throws {
        let group = PhotoCandidateGroup(
            id: "group",
            kind: .similar,
            candidates: [
                candidate(id: "recommended", bytes: 8_000, sharpness: 0.95),
                candidate(id: "chosen", bytes: 5_000, sharpness: 0.30)
            ]
        )
        let flow = ComparisonFlowModel(
            groups: [group],
            recommendations: [PhotoGroupRecommendation(
                groupID: group.id,
                recommendedKeepID: "recommended",
                reasons: [.sharper],
                confidence: 1
            )],
            decisionWorkflow: DecisionWorkflow(repository: try SwiftDataTaskRepository(inMemory: true))
        )

        flow.selectKeep(assetID: "chosen")

        #expect(flow.isRecommendationOverridden)
        #expect(flow.displayedRecommendation == nil)
        #expect(flow.selectedKeepIDs == ["chosen"])
    }

    @Test("Favorite and edited items are never preselected for deletion")
    func protectedSemanticStatesRemainKeeps() throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let group = PhotoCandidateGroup(
            id: "group",
            kind: .burst,
            candidates: [
                candidate(id: "recommended", bytes: 8_000, sharpness: 0.95),
                candidate(id: "favorite", bytes: 5_000, sharpness: 0.3, isFavorite: true),
                candidate(id: "edited", bytes: 4_000, sharpness: 0.3, isEdited: true),
                candidate(id: "discard", bytes: 2_000, sharpness: 0.2)
            ]
        )
        let flow = ComparisonFlowModel(
            groups: [group],
            recommendations: [PhotoGroupRecommendation(
                groupID: group.id,
                recommendedKeepID: "recommended",
                reasons: [.sharper],
                confidence: 1
            )],
            decisionWorkflow: DecisionWorkflow(repository: repository)
        )

        try flow.completeCurrentGroup()

        #expect(try repository.decision(for: "favorite")?.kind == .keep)
        #expect(try repository.decision(for: "edited")?.kind == .keep)
        #expect(try repository.decision(for: "discard")?.kind == .deleteCandidate)
    }

    @Test("A failed group save leaves counters unchanged and retry applies one complete batch")
    func failedCompletionIsRetrySafe() throws {
        let applier = ControllableGroupApplier()
        let group = PhotoCandidateGroup(
            id: "group",
            kind: .similar,
            candidates: [
                candidate(id: "keep", bytes: 5_000, sharpness: 0.95),
                candidate(id: "delete", bytes: 8_000, sharpness: 0.2)
            ]
        )
        let flow = ComparisonFlowModel(
            groups: [group],
            recommendations: [PhotoGroupRecommendation(
                groupID: group.id,
                recommendedKeepID: "keep",
                reasons: [.sharper],
                confidence: 1
            )],
            decisionWorkflow: applier
        )

        applier.shouldFail = true
        #expect(throws: ControllableGroupApplier.Error.saveFailed) {
            try flow.completeCurrentGroup()
        }
        #expect(flow.currentGroup?.id == "group")
        #expect(flow.deleteCandidateCount == 0)
        #expect(flow.estimatedReclaimableBytes == 0)
        #expect(applier.appliedBatches.isEmpty)

        applier.shouldFail = false
        try flow.completeCurrentGroup()
        #expect(applier.appliedBatches.count == 1)
        #expect(applier.appliedBatches[0].map(\.assetID) == ["keep", "delete"])
        #expect(applier.appliedBatches[0].map(\.kind) == [.keep, .deleteCandidate])
        #expect(applier.appliedBatches[0].map(\.estimatedBytes) == [0, 8_000])
        #expect(flow.deleteCandidateCount == 1)
        #expect(flow.estimatedReclaimableBytes == 8_000)
    }

    @Test("A final group stays retryable until its decisions and task completion both persist")
    func finalGroupCompletionIsAtomic() throws {
        let applier = ControllableGroupApplier()
        let group = PhotoCandidateGroup(
            id: "group",
            kind: .similar,
            candidates: [
                candidate(id: "keep", bytes: 5_000, sharpness: 0.95),
                candidate(id: "delete", bytes: 8_000, sharpness: 0.2)
            ]
        )
        let flow = ComparisonFlowModel(
            groups: [group],
            recommendations: [PhotoGroupRecommendation(
                groupID: group.id,
                recommendedKeepID: "keep",
                reasons: [.sharper],
                confidence: 1
            )],
            decisionWorkflow: applier,
            taskID: "task"
        )

        applier.shouldFailFinalCompletion = true
        #expect(throws: ControllableGroupApplier.Error.saveFailed) {
            try flow.completeCurrentGroup()
        }
        #expect(!flow.isFinished)
        #expect(flow.deleteCandidateCount == 0)
        #expect(applier.taskStatus == .inProgress)
        #expect(applier.finalBatches.isEmpty)

        applier.shouldFailFinalCompletion = false
        try flow.completeCurrentGroup()
        #expect(flow.isFinished)
        #expect(flow.deleteCandidateCount == 1)
        #expect(applier.finalBatches.count == 1)
        #expect(applier.taskStatus == .completed)
    }

    @Test("Completing groups accumulates exact deletion totals before advancing")
    func multiGroupCompletionAccumulatesTotals() throws {
        let applier = ControllableGroupApplier()
        let first = PhotoCandidateGroup(
            id: "first",
            kind: .similar,
            candidates: [
                candidate(id: "first-keep", bytes: 1_000, sharpness: 0.95),
                candidate(id: "first-delete", bytes: 8_000, sharpness: 0.2)
            ]
        )
        let second = PhotoCandidateGroup(
            id: "second",
            kind: .burst,
            candidates: [
                candidate(id: "second-first", bytes: 3_000, sharpness: 0.7),
                candidate(id: "second-keep", bytes: 2_000, sharpness: 0.69)
            ]
        )
        let flow = ComparisonFlowModel(
            groups: [first, second],
            recommendations: [PhotoGroupRecommendation(
                groupID: first.id,
                recommendedKeepID: "first-keep",
                reasons: [.sharper],
                confidence: 1
            )],
            decisionWorkflow: applier
        )

        try flow.completeCurrentGroup()
        flow.selectKeep(assetID: "second-keep")
        try flow.completeCurrentGroup()

        #expect(flow.isFinished)
        #expect(flow.deleteCandidateCount == 2)
        #expect(flow.estimatedReclaimableBytes == 11_000)
    }
    @Test("Changing the recommended keep persists the edited group selection and cumulative bytes")
    func editedRecommendationCompletesCurrentGroup() throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let workflow = DecisionWorkflow(repository: repository)
        let group = PhotoCandidateGroup(
            id: "confident",
            kind: .similar,
            candidates: [
                candidate(id: "recommended", bytes: 8_000, sharpness: 0.95),
                candidate(id: "chosen", bytes: 5_000, sharpness: 0.30),
                candidate(id: "protected", bytes: 3_000, sharpness: 0.20, manualProtection: true)
            ]
        )
        let recommendation = PhotoGroupRecommendation(
            groupID: group.id,
            recommendedKeepID: "recommended",
            reasons: [.sharper],
            confidence: 0.9
        )
        let flow = ComparisonFlowModel(
            groups: [group],
            recommendations: [recommendation],
            decisionWorkflow: workflow
        )

        flow.selectKeep(assetID: "chosen")
        try flow.completeCurrentGroup()

        #expect(try repository.decision(for: "chosen")?.kind == .keep)
        #expect(try repository.decision(for: "protected")?.kind == .keep)
        #expect(try repository.decision(for: "recommended")?.kind == .deleteCandidate)
        #expect(flow.deleteCandidateCount == 1)
        #expect(flow.estimatedReclaimableBytes == 8_000)
        #expect(flow.isFinished)
    }

    @Test("A low-confidence group requires an explicit keep choice")
    func lowConfidenceGroupRequiresSelection() throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let workflow = DecisionWorkflow(repository: repository)
        let group = PhotoCandidateGroup(
            id: "low-confidence",
            kind: .burst,
            candidates: [
                candidate(id: "first", bytes: 1_000, sharpness: 0.70),
                candidate(id: "second", bytes: 2_000, sharpness: 0.69)
            ]
        )
        let flow = ComparisonFlowModel(
            groups: [group],
            recommendations: [PhotoGroupRecommendation(
                groupID: group.id,
                recommendedKeepID: nil,
                reasons: [],
                confidence: 0
            )],
            decisionWorkflow: workflow
        )

        #expect(throws: ComparisonFlowError.keepSelectionRequired) {
            try flow.completeCurrentGroup()
        }
        flow.selectKeep(assetID: "second")
        try flow.completeCurrentGroup()

        #expect(try repository.decision(for: "second")?.kind == .keep)
        #expect(try repository.decision(for: "first")?.kind == .deleteCandidate)
    }

    private func candidate(
        id: String,
        bytes: Int64,
        sharpness: Double,
        manualProtection: Bool = false,
        isFavorite: Bool = false,
        isEdited: Bool = false
    ) -> PhotoCandidate {
        PhotoCandidate(
            asset: PhotoAssetDescriptor(
                id: id,
                mediaType: .photo,
                creationDate: Date(timeIntervalSince1970: 1_000),
                pixelWidth: 1_200,
                pixelHeight: 900,
                duration: 0,
                estimatedBytes: bytes,
                isFavorite: isFavorite,
                isEdited: isEdited,
                isScreenshot: false,
                burstIdentifier: nil,
                availability: .local
            ),
            quality: PhotoQualitySignals(
                sharpness: sharpness,
                exposure: 0.8,
                completeness: 0.8
            ),
            manualProtection: manualProtection
        )
    }
}

@MainActor
private final class ControllableGroupApplier: ComparisonGroupDecisionApplying {
    enum Error: Swift.Error, Equatable {
        case saveFailed
    }

    var shouldFail = false
    var shouldFailFinalCompletion = false
    private(set) var appliedBatches: [[PhotoDecision]] = []
    private(set) var finalBatches: [[PhotoDecision]] = []
    private(set) var taskStatus: CleanupTaskStatus = .inProgress

    func applyGroup(_ decisions: [PhotoDecision]) throws {
        if shouldFail { throw Error.saveFailed }
        appliedBatches.append(decisions)
    }

    func completeGroup(_ decisions: [PhotoDecision], taskID: String) throws {
        if shouldFailFinalCompletion { throw Error.saveFailed }
        finalBatches.append(decisions)
        taskStatus = .completed
    }
}
