import Foundation
import Testing
@testable import PhotoBox

@Suite("Unified delete review")
@MainActor
struct DeleteReviewModelTests {
    // Production break: review can substitute a missing asset, lose task provenance, or hide favorite risk.
    @Test("Projects exact accessible delete decisions with task and risk evidence")
    func projectsExactCandidates() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let task = makeTask(id: "task-a", assetIDs: ["favorite", "edited", "missing", "protected"])
        try repository.save(task: task)
        try repository.save(decisions: [
            decision(id: "favorite", kind: .deleteCandidate, taskID: task.id, bytes: 1_000),
            decision(id: "edited", kind: .deleteCandidate, taskID: task.id, bytes: 2_000),
            decision(id: "missing", kind: .deleteCandidate, taskID: task.id, bytes: 9_000),
            decision(id: "protected", kind: .protect, taskID: task.id, bytes: 3_000)
        ])
        let model = DeleteReviewModel(
            repository: repository,
            library: DeleteReviewReader(descriptors: [
                descriptor(id: "favorite", bytes: 1_000, isFavorite: true),
                descriptor(id: "edited", bytes: 2_000, isEdited: true),
                descriptor(id: "protected", bytes: 3_000)
            ]),
            mutator: SimulatedPhotoLibraryMutator(assetIDs: ["favorite", "edited"])
        )

        await model.load()

        #expect(model.loadState == .ready)
        #expect(model.candidates.map(\.id) == ["edited", "favorite"])
        #expect(model.candidates.first(where: { $0.id == "favorite" })?.descriptor.isFavorite == true)
        #expect(model.candidates.first(where: { $0.id == "edited" })?.descriptor.isEdited == true)
        #expect(model.candidates.allSatisfy { $0.sourceTask.id == task.id })
        #expect(model.protectedExclusionCount == 1)
        #expect(model.estimatedReclaimableBytes == 3_000)
    }

    // Production break: removing or cancelling review persists a destructive decision change before confirmation.
    @Test("Removing and cancelling keep persisted decisions reversible")
    func removalAndCancellationAreInMemoryOnly() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let task = makeTask(id: "task-a", assetIDs: ["first", "second"])
        try repository.save(task: task)
        try repository.save(decisions: [
            decision(id: "first", kind: .deleteCandidate, taskID: task.id),
            decision(id: "second", kind: .deleteCandidate, taskID: task.id)
        ])
        let mutator = RecordingDeleteMutator(assetIDs: ["first", "second"])
        let model = DeleteReviewModel(
            repository: repository,
            library: DeleteReviewReader(descriptors: [descriptor(id: "first"), descriptor(id: "second")]),
            mutator: mutator
        )
        await model.load()

        model.removeCandidate(id: "first")
        model.cancelConfirmation()

        #expect(model.selectedCandidateIDs == ["second"])
        #expect(try repository.decision(for: "first")?.isSubmitted == false)
        #expect(try repository.decision(for: "second")?.isSubmitted == false)
        #expect(await mutator.deleteRequests().isEmpty)
    }

    // Production break: confirmation includes removed/protected/stale IDs or submits more than once.
    @Test("Final confirmation submits only remaining exact reviewed IDs once")
    func confirmationSubmitsRemainingCandidatesOnce() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let task = makeTask(id: "task-a", assetIDs: ["first", "second", "protected", "missing"])
        try repository.save(task: task)
        try repository.save(decisions: [
            decision(id: "first", kind: .deleteCandidate, taskID: task.id),
            decision(id: "second", kind: .deleteCandidate, taskID: task.id),
            decision(id: "protected", kind: .protect, taskID: task.id),
            decision(id: "missing", kind: .deleteCandidate, taskID: task.id)
        ])
        let mutator = RecordingDeleteMutator(assetIDs: ["first", "second"])
        let model = DeleteReviewModel(
            repository: repository,
            library: DeleteReviewReader(descriptors: [descriptor(id: "first"), descriptor(id: "second")]),
            mutator: mutator
        )
        await model.load()
        model.removeCandidate(id: "first")

        await model.confirmDeletion()
        await model.confirmDeletion()

        #expect(await mutator.deleteRequests() == [["second"]])
        #expect(try repository.decision(for: "second")?.isSubmitted == true)
        #expect(try repository.decision(for: "first")?.isSubmitted == false)
        #expect(try repository.decision(for: "protected")?.isSubmitted == false)
        #expect(try repository.decision(for: "missing")?.isSubmitted == false)
    }

    // Production break: an empty review reaches the mutation boundary.
    @Test("Empty review cannot submit")
    func emptyReviewCannotSubmit() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let mutator = RecordingDeleteMutator(assetIDs: [])
        let model = DeleteReviewModel(
            repository: repository,
            library: DeleteReviewReader(descriptors: []),
            mutator: mutator
        )

        await model.load()
        await model.confirmDeletion()

        #expect(model.loadState == .empty)
        #expect(await mutator.deleteRequests().isEmpty)
    }

    // Production break: a completed transaction with failed items clears review state and hides recovery.
    @Test("Submission failure retains review selection and retry guidance")
    func submissionFailureRetainsSelection() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let task = makeTask(id: "task-a", assetIDs: ["first"])
        try repository.save(task: task)
        try repository.save(decision: decision(id: "first", kind: .deleteCandidate, taskID: task.id))
        let mutator = RecordingDeleteMutator(assetIDs: ["first"], resultState: .failed)
        let model = DeleteReviewModel(
            repository: repository,
            library: DeleteReviewReader(descriptors: [descriptor(id: "first")]),
            mutator: mutator
        )
        await model.load()

        await model.confirmDeletion()

        #expect(model.selectedCandidateIDs == ["first"])
        #expect(model.submissionErrorMessage == "无法完成删除请求，请重新确认后重试或返回任务列表。")
        #expect(try repository.decision(for: "first")?.isSubmitted == false)
    }

    // Production break: inaccessible/orphaned protected records inflate the visible exclusion count.
    @Test("Projection scopes candidates and protected exclusions to exact accessible task context")
    func projectionScopesCandidatesAndProtectedExclusions() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let first = makeTask(id: "first", assetIDs: ["a", "protected"])
        let second = makeTask(id: "second", assetIDs: ["b"])
        try repository.save(task: first)
        try repository.save(task: second)
        try repository.save(decisions: [
            decision(id: "a", kind: .deleteCandidate, taskID: first.id),
            decision(id: "b", kind: .deleteCandidate, taskID: second.id),
            decision(id: "protected", kind: .protect, taskID: first.id),
            decision(id: "unavailable-protected", kind: .protect, taskID: first.id),
            decision(id: "orphan-protected", kind: .protect, taskID: "missing-task"),
            decision(id: "orphan-delete", kind: .deleteCandidate, taskID: "missing-task")
        ])
        let model = DeleteReviewModel(
            repository: repository,
            library: DeleteReviewReader(descriptors: [descriptor(id: "a"), descriptor(id: "b"), descriptor(id: "protected")]),
            mutator: SimulatedPhotoLibraryMutator(assetIDs: ["a", "b"])
        )

        await model.load()

        #expect(model.candidates.map(\.id) == ["a", "b"])
        #expect(model.candidates.map(\.sourceTask.id) == ["first", "second"])
        #expect(model.protectedExclusionCount == 1)
    }

    // Production break: a load error renders stale ready content and its retry can submit deletion.
    @Test("Load retry recovers a failed review without touching mutation state")
    func loadRetryIsSeparateFromDeletion() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let task = makeTask(id: "task", assetIDs: ["asset"])
        try repository.save(task: task)
        try repository.save(decision: decision(id: "asset", kind: .deleteCandidate, taskID: task.id))
        let reader = SequencedDeleteReviewReader(responses: [.failure, .descriptors([descriptor(id: "asset")])])
        let mutator = RecordingDeleteMutator(assetIDs: ["asset"])
        let model = DeleteReviewModel(repository: repository, library: reader, mutator: mutator)

        await model.load()
        await model.retryLoad()

        #expect(model.loadState == .ready)
        #expect(model.selectedCandidateIDs == ["asset"])
        #expect(await mutator.deleteRequests().isEmpty)
    }

    // Production break: retry creates a second journal via submit instead of retrying the retained transaction.
    @Test("Mutation retry uses the retained transaction and removes resolved candidates")
    func mutationRetryUsesRetainedTransaction() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let task = makeTask(id: "task", assetIDs: ["asset"])
        try repository.save(task: task)
        try repository.save(decision: decision(id: "asset", kind: .deleteCandidate, taskID: task.id))
        let mutator = RecordingDeleteMutator(assetIDs: ["asset"], resultStates: [.failed, .succeeded])
        let model = DeleteReviewModel(
            repository: repository,
            library: DeleteReviewReader(descriptors: [descriptor(id: "asset")]),
            mutator: mutator
        )
        await model.load()
        await model.confirmDeletion()
        let transactionID = try #require(model.retryTransactionID)

        await model.retryDeletion()

        #expect(await mutator.deleteRequests() == [["asset"], ["asset"]])
        #expect(try repository.transactions().map(\.id) == [transactionID])
        #expect(model.selectedCandidateIDs.isEmpty)
        #expect(model.lastTransaction?.id == transactionID)
    }

    // Production break: removing one failed candidate does not constrain the existing journal retry.
    @Test("Retry submits only the still-selected unresolved candidates")
    func retryUsesCurrentUnresolvedSelection() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let task = makeTask(id: "task", assetIDs: ["first", "second"])
        try repository.save(task: task)
        try repository.save(decisions: [
            decision(id: "first", kind: .deleteCandidate, taskID: task.id),
            decision(id: "second", kind: .deleteCandidate, taskID: task.id)
        ])
        let mutator = RecordingDeleteMutator(assetIDs: ["first", "second"], resultStates: [.failed, .succeeded])
        let model = DeleteReviewModel(
            repository: repository,
            library: DeleteReviewReader(descriptors: [descriptor(id: "first"), descriptor(id: "second")]),
            mutator: mutator
        )
        await model.load()
        await model.confirmDeletion()
        model.removeCandidate(id: "first")

        await model.retryDeletion()

        #expect(await mutator.deleteRequests() == [["first", "second"], ["second"]])
        #expect(model.selectedCandidateIDs.isEmpty)
        #expect(model.lastTransaction?.items == [
            MutationItem(assetID: "first", state: .failed),
            MutationItem(assetID: "second", state: .succeeded)
        ])
    }

    // Production break: clearing a retry selection still submits the full unresolved journal.
    @Test("An empty retry selection does not contact the mutator")
    func emptyRetrySelectionDoesNotSubmit() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let task = makeTask(id: "task", assetIDs: ["asset"])
        try repository.save(task: task)
        try repository.save(decision: decision(id: "asset", kind: .deleteCandidate, taskID: task.id))
        let mutator = RecordingDeleteMutator(assetIDs: ["asset"], resultStates: [.failed, .succeeded])
        let model = DeleteReviewModel(
            repository: repository,
            library: DeleteReviewReader(descriptors: [descriptor(id: "asset")]),
            mutator: mutator
        )
        await model.load()
        await model.confirmDeletion()
        model.removeCandidate(id: "asset")

        await model.retryDeletion()

        #expect(await mutator.deleteRequests() == [["asset"]])
        #expect(model.retryTransactionID != nil)
    }

    // Production break: a partial delete remains on Delete Review and makes Result-owned same-journal retry unreachable.
    @Test("Partial results hand off their persisted journal to Result")
    func partialResultCompletesReviewIntoResult() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let task = makeTask(id: "task", assetIDs: ["succeeded", "failed"])
        try repository.save(task: task)
        try repository.save(decisions: [
            decision(id: "succeeded", kind: .deleteCandidate, taskID: task.id),
            decision(id: "failed", kind: .deleteCandidate, taskID: task.id)
        ])
        let mutator = SimulatedPhotoLibraryMutator(
            assetIDs: ["succeeded", "failed"],
            configuredOutcomes: ["failed": .failed]
        )
        var completedTransactions: [MutationTransaction] = []
        let model = DeleteReviewModel(
            repository: repository,
            library: DeleteReviewReader(descriptors: [descriptor(id: "succeeded"), descriptor(id: "failed")]),
            mutator: mutator,
            onTransactionCompleted: { completedTransactions.append($0) }
        )
        await model.load()

        await model.confirmDeletion()

        #expect(model.selectedCandidateIDs == ["failed"])
        #expect(model.retryTransactionID != nil)
        #expect(completedTransactions.map(\.id) == [try #require(model.lastTransaction).id])
    }

    // Production break: relaunch forgets the recoverable journal and repopulates resolved candidates.
    @Test("Load restores only exact accessible unresolved candidates from the latest delete journal")
    func loadRestoresLatestRecoverableDeleteTransaction() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let task = makeTask(id: "task", assetIDs: ["resolved", "retry", "unavailable"])
        try repository.save(task: task)
        try repository.save(decisions: [
            decision(id: "resolved", kind: .deleteCandidate, taskID: task.id, isSubmitted: true),
            decision(id: "retry", kind: .deleteCandidate, taskID: task.id),
            decision(id: "unavailable", kind: .deleteCandidate, taskID: task.id)
        ])
        let transaction = MutationTransaction(
            id: "recoverable-delete",
            operation: .delete,
            items: [
                MutationItem(assetID: "resolved", state: .succeeded),
                MutationItem(assetID: "retry", state: .failed),
                MutationItem(assetID: "unavailable", state: .pending)
            ],
            backendMode: .simulated
        )
        try repository.save(transaction: transaction)
        let model = DeleteReviewModel(
            repository: repository,
            library: DeleteReviewReader(descriptors: [
                descriptor(id: "resolved"),
                descriptor(id: "retry"),
                descriptor(id: "unavailable", availability: .unavailable)
            ]),
            mutator: RecordingDeleteMutator(assetIDs: ["retry"])
        )

        await model.load()
        await model.confirmDeletion()

        #expect(model.lastTransaction?.id == transaction.id)
        #expect(model.retryTransactionID == transaction.id)
        #expect(model.candidates.map(\.id) == ["retry"])
        #expect(model.selectedCandidateIDs == ["retry"])
    }

    // Production break: cancelling a retry confirmation clears the only visible recovery guidance.
    @Test("Cancelling a retry confirmation retains recovery guidance")
    func cancellingRetryConfirmationRetainsGuidance() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let task = makeTask(id: "task", assetIDs: ["asset"])
        try repository.save(task: task)
        try repository.save(decision: decision(id: "asset", kind: .deleteCandidate, taskID: task.id))
        let model = DeleteReviewModel(
            repository: repository,
            library: DeleteReviewReader(descriptors: [descriptor(id: "asset")]),
            mutator: RecordingDeleteMutator(assetIDs: ["asset"], resultState: .failed)
        )
        await model.load()
        await model.confirmDeletion()
        let guidance = model.submissionErrorMessage

        model.cancelConfirmation()

        #expect(model.submissionErrorMessage == guidance)
        #expect(model.retryTransactionID != nil)
    }

    // Production break: a failed journal save reaches the mutator or discards the reversible selection.
    @Test("Initial journal save failure preserves review selection without mutation")
    func initialJournalSaveFailurePreservesReview() async throws {
        let storage = try SwiftDataTaskRepository(inMemory: true)
        let task = makeTask(id: "task", assetIDs: ["asset"])
        try storage.save(task: task)
        try storage.save(decision: decision(id: "asset", kind: .deleteCandidate, taskID: task.id))
        let repository = FailingDeleteReviewRepository(storage: storage)
        let mutator = RecordingDeleteMutator(assetIDs: ["asset"])
        let model = DeleteReviewModel(
            repository: repository,
            library: DeleteReviewReader(descriptors: [descriptor(id: "asset")]),
            mutator: mutator
        )
        await model.load()
        repository.transactionSaveFailures = 1

        await model.confirmDeletion()

        #expect(model.selectedCandidateIDs == ["asset"])
        #expect(model.retryTransactionID == nil)
        #expect(model.submissionErrorMessage == "无法提交删除请求，请重试或返回任务列表。")
        #expect(await mutator.deleteRequests().isEmpty)
    }

    // Production break: a retry journal-save error drops the retained transaction or resubmits the mutator request.
    @Test("Retry journal save failure retains the existing recovery state")
    func retryJournalSaveFailureRetainsRecovery() async throws {
        let storage = try SwiftDataTaskRepository(inMemory: true)
        let task = makeTask(id: "task", assetIDs: ["asset"])
        try storage.save(task: task)
        try storage.save(decision: decision(id: "asset", kind: .deleteCandidate, taskID: task.id))
        let repository = FailingDeleteReviewRepository(storage: storage)
        let mutator = RecordingDeleteMutator(assetIDs: ["asset"], resultStates: [.failed, .succeeded])
        let model = DeleteReviewModel(
            repository: repository,
            library: DeleteReviewReader(descriptors: [descriptor(id: "asset")]),
            mutator: mutator
        )
        await model.load()
        await model.confirmDeletion()
        let transactionID = try #require(model.retryTransactionID)
        repository.transactionSaveFailures = 1

        await model.retryDeletion()

        #expect(model.retryTransactionID == transactionID)
        #expect(model.selectedCandidateIDs == ["asset"])
        #expect(model.submissionErrorMessage == "无法重试删除请求，请重新确认或返回任务列表。")
        #expect(await mutator.deleteRequests() == [["asset"]])
        #expect(try storage.transactions().first?.items == [MutationItem(assetID: "asset", state: .failed)])
    }

    // Production break: a fully failed transaction remains on Delete Review and makes same-journal result retry unreachable.
    @Test("Fully unresolved transactions hand off the persisted journal to Result")
    func unresolvedTransactionCompletesReviewIntoResult() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let task = makeTask(id: "task", assetIDs: ["asset"])
        try repository.save(task: task)
        try repository.save(decision: decision(id: "asset", kind: .deleteCandidate, taskID: task.id))
        let mutator = RecordingDeleteMutator(assetIDs: ["asset"], resultState: .failed)
        var completedTransactions: [MutationTransaction] = []
        let model = DeleteReviewModel(
            repository: repository,
            library: DeleteReviewReader(descriptors: [descriptor(id: "asset")]),
            mutator: mutator,
            onTransactionCompleted: { completedTransactions.append($0) }
        )
        await model.load()

        await model.confirmDeletion()

        #expect(model.selectedCandidateIDs == ["asset"])
        #expect(model.retryTransactionID != nil)
        #expect(completedTransactions.map(\.id) == [try #require(model.lastTransaction).id])
    }

    // Production break: stale IDs survive review and are sent to the destructive mutator.
    @Test("Stale candidates are journaled and excluded from the destructive request")
    func staleCandidateIsExcludedBeforeMutation() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let task = makeTask(id: "task", assetIDs: ["available", "stale"])
        try repository.save(task: task)
        try repository.save(decisions: [
            decision(id: "available", kind: .deleteCandidate, taskID: task.id),
            decision(id: "stale", kind: .deleteCandidate, taskID: task.id)
        ])
        let mutator = RecordingDeleteMutator(assetIDs: ["available"])
        var completedTransactions: [MutationTransaction] = []
        let model = DeleteReviewModel(
            repository: repository,
            library: DeleteReviewReader(descriptors: [descriptor(id: "available"), descriptor(id: "stale")]),
            mutator: mutator,
            onTransactionCompleted: { completedTransactions.append($0) }
        )
        await model.load()

        await model.confirmDeletion()

        #expect(await mutator.deleteRequests() == [["available"]])
        #expect(model.selectedCandidateIDs.isEmpty)
        #expect(completedTransactions.count == 1)
        #expect(completedTransactions[0].items.contains(MutationItem(assetID: "stale", state: .stale)))
    }

    // Production break: a repository read error clears a prior selection and presents a false empty state.
    @Test("Repository load failure retains the current review selection")
    func repositoryLoadFailureRetainsReview() async throws {
        let storage = try SwiftDataTaskRepository(inMemory: true)
        let task = makeTask(id: "task", assetIDs: ["asset"])
        try storage.save(task: task)
        try storage.save(decision: decision(id: "asset", kind: .deleteCandidate, taskID: task.id))
        let repository = FailingDeleteReviewRepository(storage: storage)
        let model = DeleteReviewModel(
            repository: repository,
            library: DeleteReviewReader(descriptors: [descriptor(id: "asset")]),
            mutator: RecordingDeleteMutator(assetIDs: ["asset"])
        )
        await model.load()
        repository.failReads = true

        await model.load()

        guard case .failed = model.loadState else {
            Issue.record("Expected a repository load failure")
            return
        }
        #expect(model.selectedCandidateIDs == ["asset"])
        #expect(model.submissionErrorMessage == "无法载入删除复核，请重试。")
    }

    // Production break: an older asynchronous load overwrites a newer review projection.
    @Test("Overlapping loads publish only the newest projection")
    func overlappingLoadsPublishLatestProjection() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let task = makeTask(id: "task", assetIDs: ["old", "new"])
        try repository.save(task: task)
        try repository.save(decisions: [
            decision(id: "old", kind: .deleteCandidate, taskID: task.id),
            decision(id: "new", kind: .deleteCandidate, taskID: task.id)
        ])
        let reader = LatestWinsDeleteReviewReader(
            first: [descriptor(id: "old")],
            latest: [descriptor(id: "new")]
        )
        let model = DeleteReviewModel(
            repository: repository,
            library: reader,
            mutator: RecordingDeleteMutator(assetIDs: ["old", "new"])
        )

        let firstLoad = Task { await model.load() }
        await reader.waitForFirstRequest()
        await model.load()
        await reader.resumeFirstRequest()
        await firstLoad.value

        #expect(model.candidates.map(\.id) == ["new"])
        #expect(model.selectedCandidateIDs == ["new"])
    }

    // Production break: two explicit confirmations can enter the mutation coordinator concurrently.
    @Test("Concurrent confirmations submit once")
    func concurrentConfirmationsSubmitOnce() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let task = makeTask(id: "task", assetIDs: ["asset"])
        try repository.save(task: task)
        try repository.save(decision: decision(id: "asset", kind: .deleteCandidate, taskID: task.id))
        let mutator = SuspendingDeleteMutator(assetIDs: ["asset"])
        let model = DeleteReviewModel(
            repository: repository,
            library: DeleteReviewReader(descriptors: [descriptor(id: "asset")]),
            mutator: mutator
        )
        await model.load()

        let firstConfirmation = Task { await model.confirmDeletion() }
        await mutator.waitUntilDeleteStarts()
        await model.confirmDeletion()
        await mutator.completeDelete()
        await firstConfirmation.value

        #expect(await mutator.deleteRequests() == [["asset"]])
    }

    // Production break: a post-mutation result save leaves a submitted journal that a relaunch ignores and replaces.
    @Test("Relaunch reconciles a submitted delete journal after its result save fails")
    func relaunchReconcilesSubmittedDeleteAfterResultSaveFailure() async throws {
        let storage = try SwiftDataTaskRepository(inMemory: true)
        let task = makeTask(id: "task", assetIDs: ["asset"])
        try storage.save(task: task)
        try storage.save(decision: decision(id: "asset", kind: .deleteCandidate, taskID: task.id))
        let repository = FailingDeleteReviewRepository(storage: storage)
        let mutator = SimulatedPhotoLibraryMutator(
            assetIDs: ["asset"],
            reconciliationMode: .deterministicSimulation
        )
        let model = DeleteReviewModel(
            repository: repository,
            library: DeleteReviewReader(descriptors: [descriptor(id: "asset")]),
            mutator: mutator
        )
        await model.load()
        repository.transactionSaveFailureCalls = [3]

        await model.confirmDeletion()

        #expect(await mutator.submittedAssetIDs == ["asset"])
        #expect(try storage.transactions().first?.items == [MutationItem(assetID: "asset", state: .submitted)])

        let reloaded = DeleteReviewModel(
            repository: repository,
            library: DeleteReviewReader(descriptors: [descriptor(id: "asset")]),
            mutator: mutator
        )
        await reloaded.load()

        #expect(try storage.transactions().first?.items == [MutationItem(assetID: "asset", state: .succeeded)])
        #expect(try storage.decision(for: "asset")?.isSubmitted == true)
        #expect(reloaded.candidates.isEmpty)
        #expect(reloaded.retryTransactionID == nil)
    }

    // Production break: a decision persistence failure after mutation lets the same persisted success reappear for deletion.
    @Test("Relaunch completes decision persistence for a saved delete result")
    func relaunchCompletesDecisionAfterPostMutationDecisionSaveFailure() async throws {
        let storage = try SwiftDataTaskRepository(inMemory: true)
        let task = makeTask(id: "task", assetIDs: ["asset"])
        try storage.save(task: task)
        try storage.save(decision: decision(id: "asset", kind: .deleteCandidate, taskID: task.id))
        let repository = FailingDeleteReviewRepository(storage: storage)
        let mutator = SimulatedPhotoLibraryMutator(assetIDs: ["asset"])
        let model = DeleteReviewModel(
            repository: repository,
            library: DeleteReviewReader(descriptors: [descriptor(id: "asset")]),
            mutator: mutator
        )
        await model.load()
        repository.decisionSaveFailures = 1

        await model.confirmDeletion()

        #expect(try storage.transactions().first?.items == [MutationItem(assetID: "asset", state: .succeeded)])
        #expect(try storage.decision(for: "asset")?.isSubmitted == false)

        let reloaded = DeleteReviewModel(
            repository: repository,
            library: DeleteReviewReader(descriptors: [descriptor(id: "asset")]),
            mutator: mutator
        )
        await reloaded.load()

        #expect(try storage.decision(for: "asset")?.isSubmitted == true)
        #expect(reloaded.candidates.isEmpty)
    }

    // Production break: terminal delete recovery repairs the decision but omits the transaction from result handoff.
    @Test("Terminal delete recovery repairs its decision and hands off exactly once")
    func terminalDeleteRecoveryRepairsDecisionAndHandsOffOnce() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let task = makeTask(id: "task", assetIDs: ["deleted"])
        try repository.save(task: task)
        try repository.save(decision: decision(id: "deleted", kind: .deleteCandidate, taskID: task.id))
        try repository.save(transaction: MutationTransaction(
            id: "terminal-delete",
            operation: .delete,
            items: [MutationItem(assetID: "deleted", state: .succeeded)],
            submittedAt: Date(timeIntervalSince1970: 1_100),
            completedAt: Date(timeIntervalSince1970: 1_101),
            backendMode: .simulated
        ))
        let mutator = RecordingDeleteMutator(assetIDs: [])
        var completedTransactions: [MutationTransaction] = []
        let model = DeleteReviewModel(
            repository: repository,
            library: DeleteReviewReader(descriptors: []),
            mutator: mutator,
            onTransactionCompleted: { completedTransactions.append($0) }
        )

        await model.load()
        await model.load()

        #expect(completedTransactions.map(\.id) == ["terminal-delete"])
        #expect(try repository.decision(for: "deleted")?.isSubmitted == true)
        #expect(await mutator.deleteRequests().isEmpty)
    }

    // Production break: stale-only delete journals do not suppress their unsubmitted decisions on a later review.
    @Test("Resolved IDs from every persisted delete journal stay excluded from review")
    func staleOnlyJournalExcludesResolvedIDFromLaterReview() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let task = makeTask(id: "task", assetIDs: ["stale", "fresh"])
        try repository.save(task: task)
        try repository.save(decisions: [
            decision(id: "stale", kind: .deleteCandidate, taskID: task.id),
            decision(id: "fresh", kind: .deleteCandidate, taskID: task.id)
        ])
        try repository.save(transaction: MutationTransaction(
            id: "stale-only",
            operation: .delete,
            items: [MutationItem(assetID: "stale", state: .stale)],
            backendMode: .simulated
        ))
        let model = DeleteReviewModel(
            repository: repository,
            library: DeleteReviewReader(descriptors: [descriptor(id: "stale"), descriptor(id: "fresh")]),
            mutator: RecordingDeleteMutator(assetIDs: ["fresh"])
        )

        await model.load()

        #expect(model.candidates.map(\.id) == ["fresh"])
        #expect(model.selectedCandidateIDs == ["fresh"])
    }

    // Production break: an inaccessible unresolved journal allows an unrelated candidate to create an overlapping delete.
    @Test("Inaccessible unresolved journal blocks unrelated fresh deletion")
    func inaccessibleUnresolvedJournalBlocksFreshDeletion() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let task = makeTask(id: "task", assetIDs: ["unavailable", "fresh"])
        try repository.save(task: task)
        try repository.save(decisions: [
            decision(id: "unavailable", kind: .deleteCandidate, taskID: task.id),
            decision(id: "fresh", kind: .deleteCandidate, taskID: task.id)
        ])
        try repository.save(transaction: MutationTransaction(
            id: "blocked-recovery",
            operation: .delete,
            items: [MutationItem(assetID: "unavailable", state: .failed)],
            backendMode: .simulated
        ))
        let mutator = RecordingDeleteMutator(assetIDs: ["fresh"])
        let model = DeleteReviewModel(
            repository: repository,
            library: DeleteReviewReader(descriptors: [descriptor(id: "fresh")]),
            mutator: mutator
        )

        await model.load()
        await model.confirmDeletion()

        #expect(model.candidates.isEmpty)
        #expect(model.selectedCandidateIDs.isEmpty)
        #expect(model.retryTransactionID == "blocked-recovery")
        #expect(model.recoveryRequiresReload)
        #expect(model.submissionErrorMessage == "存在未完成的删除请求，但相关照片当前不可访问。请返回任务列表后稍后重试。")
        #expect(await mutator.deleteRequests().isEmpty)
    }

    // Production break: the recovery reload preserves an empty selection and cannot restore unresolved work.
    @Test("Recovery reload selects exact accessible unresolved items without submitting")
    func recoveryReloadSelectsAccessibleUnresolvedItemsWithoutSubmitting() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let task = makeTask(id: "task", assetIDs: ["selected", "deselected", "inaccessible"])
        try repository.save(task: task)
        try repository.save(decisions: [
            decision(id: "selected", kind: .deleteCandidate, taskID: task.id),
            decision(id: "deselected", kind: .deleteCandidate, taskID: task.id),
            decision(id: "inaccessible", kind: .deleteCandidate, taskID: task.id)
        ])
        try repository.save(transaction: MutationTransaction(
            id: "selected-retry",
            operation: .delete,
            items: [
                MutationItem(assetID: "selected", state: .failed),
                MutationItem(assetID: "deselected", state: .failed),
                MutationItem(assetID: "inaccessible", state: .failed)
            ],
            backendMode: .simulated
        ))
        let mutator = RecordingDeleteMutator(assetIDs: ["selected"], resultState: .succeeded)
        let model = DeleteReviewModel(
            repository: repository,
            library: DeleteReviewReader(descriptors: [descriptor(id: "selected"), descriptor(id: "deselected")]),
            mutator: mutator
        )
        await model.load()
        model.removeCandidate(id: "deselected")

        await model.retryDeletion()

        #expect(model.candidates.map(\.id) == ["deselected"])
        #expect(model.selectedCandidateIDs.isEmpty)
        #expect(model.recoveryRequiresReload)
        #expect(!model.canConfirm)

        await model.reloadRecovery()

        #expect(model.candidates.map(\.id) == ["deselected"])
        #expect(model.selectedCandidateIDs == ["deselected"])
        #expect(!model.recoveryRequiresReload)
        #expect(model.canConfirm)
        #expect(try repository.decision(for: "deselected")?.isSubmitted == false)
        #expect(try repository.decision(for: "inaccessible")?.isSubmitted == false)
        #expect(await mutator.deleteRequests() == [["selected"]])
    }

    // Production break: load reconciliation resolves the journal but never reaches the existing result handoff.
    @Test("Load hands off a newly reconciled resolved delete transaction once")
    func loadHandsOffReconciledResolvedDeleteTransactionOnce() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let task = makeTask(id: "task", assetIDs: ["deleted"])
        try repository.save(task: task)
        try repository.save(decision: decision(id: "deleted", kind: .deleteCandidate, taskID: task.id))
        try repository.save(transaction: MutationTransaction(
            id: "submitted-delete",
            operation: .delete,
            items: [MutationItem(assetID: "deleted", state: .submitted)],
            submittedAt: Date(timeIntervalSince1970: 1_100),
            backendMode: .simulated
        ))
        let mutator = SimulatedPhotoLibraryMutator(
            assetIDs: [],
            reconciliationMode: .deterministicSimulation
        )
        var completedTransactions: [MutationTransaction] = []
        let model = DeleteReviewModel(
            repository: repository,
            library: DeleteReviewReader(descriptors: []),
            mutator: mutator,
            onTransactionCompleted: { completedTransactions.append($0) }
        )

        await model.load()
        await model.load()

        #expect(completedTransactions.map(\.id) == ["submitted-delete"])
        #expect(completedTransactions.first?.items == [MutationItem(assetID: "deleted", state: .succeeded)])
        #expect(try repository.transactions().first?.items == [MutationItem(assetID: "deleted", state: .succeeded)])
        #expect(try repository.decision(for: "deleted")?.isSubmitted == true)
        #expect(await mutator.submittedAssetIDs.isEmpty)
    }

    private func makeTask(id: String, assetIDs: [String]) -> CleanupTask {
        CleanupTask(
            id: id,
            type: .screenshots,
            title: "截图整理",
            reason: "测试删除复核",
            assetIDs: assetIDs,
            estimatedBytes: 10_000,
            estimatedMinutes: 1,
            risk: .low,
            confidence: 1,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func decision(
        id: String,
        kind: PhotoDecisionKind,
        taskID: String,
        bytes: Int64 = 1_000,
        isSubmitted: Bool = false
    ) -> PhotoDecision {
        PhotoDecision(
            assetID: id,
            kind: kind,
            estimatedBytes: bytes,
            taskID: taskID,
            createdAt: Date(timeIntervalSince1970: 1_000),
            isSubmitted: isSubmitted
        )
    }

    private func descriptor(
        id: String,
        bytes: Int64 = 1_000,
        isFavorite: Bool = false,
        isEdited: Bool = false,
        availability: AssetAvailability = .local
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
            isEdited: isEdited,
            isScreenshot: false,
            burstIdentifier: nil,
            availability: availability
        )
    }
}

private actor DeleteReviewReader: PhotoLibraryReading {
    let descriptors: [PhotoAssetDescriptor]

    init(descriptors: [PhotoAssetDescriptor]) { self.descriptors = descriptors }
    func authorizationStatus() -> PhotoAuthorization { .authorized }
    func requestAuthorization() -> PhotoAuthorization { .authorized }
    func accessibleAssetDescriptors() -> [PhotoAssetDescriptor] { descriptors }
    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> {
        AsyncStream { $0.finish() }
    }
}

private actor RecordingDeleteMutator: PhotoLibraryMutating {
    let backendMode = MutationBackendMode.simulated
    private let assetIDs: Set<String>
    private var resultStates: [MutationItemState]
    private var requests: [[String]] = []

    init(assetIDs: Set<String>, resultState: MutationItemState = .succeeded) {
        self.assetIDs = assetIDs
        resultStates = [resultState]
    }
    init(assetIDs: Set<String>, resultStates: [MutationItemState]) {
        self.assetIDs = assetIDs
        self.resultStates = resultStates
    }
    func availableAssetIDs(for requestedIDs: [String]) -> Set<String> { assetIDs.intersection(requestedIDs) }
    func listAlbums() -> [PhotoAlbumDescriptor] { [] }
    func createAlbum(named title: String) -> PhotoAlbumDescriptor? { nil }
    func archivedAssetIDs(for requestedIDs: [String], inAlbumID albumID: String) -> Set<String> { [] }
    func addAssets(withIDs assetIDs: [String], toAlbumID albumID: String) -> PhotoMutationBatch {
        PhotoMutationBatch(operation: .archive, items: [], targetAlbumID: albumID)
    }
    func deleteAssets(withIDs assetIDs: [String]) -> PhotoMutationBatch {
        requests.append(assetIDs)
        let resultState = resultStates.isEmpty ? .succeeded : resultStates.removeFirst()
        return PhotoMutationBatch(
            operation: .delete,
            items: assetIDs.map { MutationItem(assetID: $0, state: resultState) },
            targetAlbumID: nil
        )
    }
    func deleteRequests() -> [[String]] { requests }
}

private actor SequencedDeleteReviewReader: PhotoLibraryReading {
    enum Response { case failure, descriptors([PhotoAssetDescriptor]) }
    private var responses: [Response]
    init(responses: [Response]) { self.responses = responses }
    func authorizationStatus() -> PhotoAuthorization { .authorized }
    func requestAuthorization() -> PhotoAuthorization { .authorized }
    func accessibleAssetDescriptors() throws -> [PhotoAssetDescriptor] {
        switch responses.removeFirst() {
        case .failure: throw PhotoLibraryReadError.scopeUnavailable
        case .descriptors(let descriptors): return descriptors
        }
    }
    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> { AsyncStream { $0.finish() } }
}

private actor LatestWinsDeleteReviewReader: PhotoLibraryReading {
    private let first: [PhotoAssetDescriptor]
    private let latest: [PhotoAssetDescriptor]
    private var requestCount = 0
    private var firstRequestContinuation: CheckedContinuation<[PhotoAssetDescriptor], Never>?

    init(first: [PhotoAssetDescriptor], latest: [PhotoAssetDescriptor]) {
        self.first = first
        self.latest = latest
    }

    func authorizationStatus() -> PhotoAuthorization { .authorized }
    func requestAuthorization() -> PhotoAuthorization { .authorized }
    func accessibleAssetDescriptors() async -> [PhotoAssetDescriptor] {
        requestCount += 1
        guard requestCount == 1 else { return latest }
        return await withCheckedContinuation { continuation in
            firstRequestContinuation = continuation
        }
    }
    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> { AsyncStream { $0.finish() } }

    func waitForFirstRequest() async {
        while firstRequestContinuation == nil {
            await Task.yield()
        }
    }

    func resumeFirstRequest() {
        firstRequestContinuation?.resume(returning: first)
        firstRequestContinuation = nil
    }
}

private actor SuspendingDeleteMutator: PhotoLibraryMutating {
    let backendMode = MutationBackendMode.simulated
    private let assetIDs: Set<String>
    private var requests: [[String]] = []
    private var deleteContinuation: CheckedContinuation<PhotoMutationBatch, Never>?

    init(assetIDs: Set<String>) { self.assetIDs = assetIDs }

    func availableAssetIDs(for requestedIDs: [String]) -> Set<String> { assetIDs.intersection(requestedIDs) }
    func listAlbums() -> [PhotoAlbumDescriptor] { [] }
    func createAlbum(named title: String) -> PhotoAlbumDescriptor? { nil }
    func archivedAssetIDs(for requestedIDs: [String], inAlbumID albumID: String) -> Set<String> { [] }
    func addAssets(withIDs assetIDs: [String], toAlbumID albumID: String) -> PhotoMutationBatch {
        PhotoMutationBatch(operation: .archive, items: [], targetAlbumID: albumID)
    }
    func deleteAssets(withIDs assetIDs: [String]) async -> PhotoMutationBatch {
        requests.append(assetIDs)
        return await withCheckedContinuation { continuation in
            deleteContinuation = continuation
        }
    }

    func waitUntilDeleteStarts() async {
        while deleteContinuation == nil {
            await Task.yield()
        }
    }

    func completeDelete() {
        let submittedIDs = requests.last ?? []
        deleteContinuation?.resume(returning: PhotoMutationBatch(
            operation: .delete,
            items: submittedIDs.map { MutationItem(assetID: $0, state: .succeeded) },
            targetAlbumID: nil
        ))
        deleteContinuation = nil
    }

    func deleteRequests() -> [[String]] { requests }
}

@MainActor
private final class FailingDeleteReviewRepository: TaskRepository {
    private let storage: SwiftDataTaskRepository
    var failReads = false
    var transactionSaveFailures = 0
    var transactionSaveFailureCalls: Set<Int> = []
    var transactionSaveCallCount = 0
    var decisionSaveFailures = 0

    init(storage: SwiftDataTaskRepository) {
        self.storage = storage
    }

    func save(checkpoint: ScanCheckpoint) throws { try storage.save(checkpoint: checkpoint) }
    func latestCheckpoint() throws -> ScanCheckpoint? { try storage.latestCheckpoint() }
    func save(task: CleanupTask) throws { try storage.save(task: task) }
    func tasks() throws -> [CleanupTask] {
        if failReads { throw DeleteReviewRepositoryFailure.forced }
        return try storage.tasks()
    }
    func save(decision: PhotoDecision) throws {
        if decisionSaveFailures > 0 {
            decisionSaveFailures -= 1
            throw DeleteReviewRepositoryFailure.forced
        }
        try storage.save(decision: decision)
    }
    func applySingleDecision(
        _ decision: PhotoDecision,
        undo: DecisionUndoEntry,
        task: CleanupTask?
    ) throws {
        try storage.applySingleDecision(decision, undo: undo, task: task)
    }
    func save(decisions: [PhotoDecision]) throws { try storage.save(decisions: decisions) }
    func completeComparison(taskID: String, decisions: [PhotoDecision]) throws {
        try storage.completeComparison(taskID: taskID, decisions: decisions)
    }
    func completeArchive(
        transaction: MutationTransaction,
        decision: PhotoDecision,
        recentAlbumIDs: [String]
    ) throws {
        try storage.completeArchive(transaction: transaction, decision: decision, recentAlbumIDs: recentAlbumIDs)
    }
    func removeDecision(for assetID: String) throws { try storage.removeDecision(for: assetID) }
    func decision(for assetID: String) throws -> PhotoDecision? { try storage.decision(for: assetID) }
    func decisions() throws -> [PhotoDecision] {
        if failReads { throw DeleteReviewRepositoryFailure.forced }
        return try storage.decisions()
    }
    func save(undo: DecisionUndoEntry) throws { try storage.save(undo: undo) }
    func latestUndo() throws -> DecisionUndoEntry? { try storage.latestUndo() }
    func removeUndo(id: UUID) throws { try storage.removeUndo(id: id) }
    func save(transaction: MutationTransaction) throws {
        transactionSaveCallCount += 1
        if transactionSaveFailureCalls.contains(transactionSaveCallCount) {
            throw DeleteReviewRepositoryFailure.forced
        }
        if transactionSaveFailures > 0 {
            transactionSaveFailures -= 1
            throw DeleteReviewRepositoryFailure.forced
        }
        try storage.save(transaction: transaction)
    }
    func transactions() throws -> [MutationTransaction] { try storage.transactions() }
    func save(settings: WorkflowSettings) throws { try storage.save(settings: settings) }
    func settings() throws -> WorkflowSettings { try storage.settings() }
    func save(summary: CleanupSummary) throws { try storage.save(summary: summary) }
    func summaries() throws -> [CleanupSummary] { try storage.summaries() }
    func reconcile(availableAssetIDs: Set<String>) throws { try storage.reconcile(availableAssetIDs: availableAssetIDs) }
    func clearHistory() throws { try storage.clearHistory() }
}

private enum DeleteReviewRepositoryFailure: Error {
    case forced
}
