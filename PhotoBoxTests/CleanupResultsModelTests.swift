import Foundation
import SwiftData
import Testing
@testable import PhotoBox

@MainActor
struct CleanupResultsModelTests {
    // Production break: a result view substitutes another transaction or includes resolved IDs in retry.
    @Test("Result projection retries only the exact unresolved identifiers")
    func projectionRetriesOnlyUnresolvedIdentifiers() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        try repository.save(decisions: [
            PhotoDecision(assetID: "succeeded", kind: .deleteCandidate, estimatedBytes: 1_000, taskID: "result-task", isSubmitted: true),
            PhotoDecision(assetID: "failed", kind: .deleteCandidate, estimatedBytes: 2_000, taskID: "result-task"),
            PhotoDecision(assetID: "cancelled", kind: .deleteCandidate, estimatedBytes: 3_000, taskID: "result-task"),
            PhotoDecision(assetID: "stale", kind: .deleteCandidate, estimatedBytes: 4_000, taskID: "result-task"),
            PhotoDecision(assetID: "protected", kind: .protect, taskID: "result-task"),
            PhotoDecision(assetID: "later", kind: .decideLater, taskID: "result-task"),
            PhotoDecision(assetID: "keep", kind: .keep, taskID: "result-task"),
            PhotoDecision(assetID: "archive", kind: .archive, taskID: "result-task", isSubmitted: true),
            PhotoDecision(assetID: "unrelated", kind: .protect, taskID: "other-task")
        ])
        try repository.save(transaction: MutationTransaction(
            id: "result-archive",
            operation: .archive,
            items: [MutationItem(assetID: "archive", state: .succeeded)],
            backendMode: .simulated
        ))
        try repository.save(transaction: MutationTransaction(
            id: "result-transaction",
            operation: .delete,
            items: [
                MutationItem(assetID: "succeeded", state: .succeeded),
                MutationItem(assetID: "failed", state: .failed),
                MutationItem(assetID: "cancelled", state: .cancelled),
                MutationItem(assetID: "stale", state: .stale)
            ],
            createdAt: Date(timeIntervalSince1970: 1_000),
            completedAt: Date(timeIntervalSince1970: 1_060),
            backendMode: .simulated
        ))
        let mutator = ResultsRecordingMutator(assetIDs: ["failed", "cancelled"])
        let model = CleanupResultsModel(
            source: .transaction("result-transaction"),
            repository: repository,
            mutator: mutator
        )

        await model.load()

        #expect(model.projection?.succeededDeleteCount == 1)
        #expect(model.projection?.unresolvedIDs == ["cancelled", "failed"])
        #expect(model.projection?.staleDeleteCount == 1)
        #expect(model.projection?.elapsedSeconds == 60)
        #expect(model.projection?.estimatedReclaimableBytes == 1_000)
        #expect(model.projection?.protectCount == 1)
        #expect(model.projection?.decideLaterCount == 1)
        #expect(model.projection?.keepCount == 1)
        #expect(model.projection?.archiveSucceededCount == 1)
        await model.retry()
        #expect(model.recoveryMessage == nil, "Retry recovery: \(model.recoveryMessage ?? "none")")
        let requests = await mutator.deleteRequests()
        #expect(requests.count == 1)
        #expect(Set(requests.first ?? []) == ["cancelled", "failed"], "Recorded requests: \(requests)")

        let relaunched = CleanupResultsModel(
            source: .transaction("result-transaction"),
            repository: repository,
            mutator: mutator
        )
        await relaunched.load()
        #expect(relaunched.projection?.succeededDeleteCount == 3)
        #expect(relaunched.canRetry == false)
    }

    // Production break: an invalid result route silently shows a different transaction.
    @Test("Missing transaction remains a recoverable missing result")
    func missingTransactionIsNotSubstituted() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        try repository.save(transaction: MutationTransaction(
            id: "other-transaction",
            operation: .delete,
            items: [MutationItem(assetID: "other", state: .succeeded)],
            backendMode: .simulated
        ))
        let model = CleanupResultsModel(
            source: .transaction("missing-transaction"),
            repository: repository,
            mutator: ResultsRecordingMutator(assetIDs: [])
        )

        await model.load()

        #expect(model.loadState == .missing)
        #expect(model.projection == nil)
        #expect(model.recoveryMessage != nil)
    }

    // Production break: a submitted delete journal is displayed as a finished result without reconciliation.
    @Test("Result loading reconciles its exact submitted delete journal before projection")
    func loadReconcilesSubmittedDeleteJournal() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        try repository.save(transaction: MutationTransaction(
            id: "submitted-result",
            operation: .delete,
            items: [MutationItem(assetID: "removed", state: .submitted)],
            backendMode: .simulated
        ))
        let model = CleanupResultsModel(
            source: .transaction("submitted-result"),
            repository: repository,
            mutator: ResultsRecordingMutator(assetIDs: [])
        )

        await model.load()

        #expect(model.projection?.succeededDeleteCount == 1)
        #expect(model.projection?.unresolvedDeleteCount == 0)
    }

    // Production break: opening one result reconciles an unrelated submitted journal as a side effect.
    @Test("Transaction result reconciles only its exact submitted journal")
    func loadReconcilesOnlyExactTransaction() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        try repository.save(transaction: MutationTransaction(
            id: "exact-submitted",
            operation: .delete,
            items: [MutationItem(assetID: "exact", state: .submitted)],
            backendMode: .simulated
        ))
        try repository.save(transaction: MutationTransaction(
            id: "competing-submitted",
            operation: .delete,
            items: [MutationItem(assetID: "competing", state: .submitted)],
            backendMode: .simulated
        ))
        let model = CleanupResultsModel(
            source: .transaction("exact-submitted"),
            repository: repository,
            mutator: ResultsRecordingMutator(assetIDs: [])
        )

        await model.load()

        let transactions = try repository.transactions()
        #expect(transactions.first(where: { $0.id == "exact-submitted" })?.items[0].state == .succeeded)
        #expect(transactions.first(where: { $0.id == "competing-submitted" })?.items[0].state == .submitted)
    }

    // Production break: a submitted journal from another backend is projected as an empty finished result.
    @Test("Backend mismatch retains the exact source and performs no deletion")
    func backendMismatchFailsTruthfullyAndRecoversExactSource() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        try repository.save(transaction: MutationTransaction(
            id: "backend-mismatch",
            operation: .delete,
            items: [MutationItem(assetID: "asset", state: .submitted)],
            backendMode: .live
        ))
        try repository.save(transaction: MutationTransaction(
            id: "competing-result",
            operation: .delete,
            items: [MutationItem(assetID: "other", state: .succeeded)],
            backendMode: .simulated
        ))
        let mismatchedMutator = BackendResultsMutator(mode: .simulated, assetIDs: ["asset"])
        let model = CleanupResultsModel(
            source: .transaction("backend-mismatch"),
            repository: repository,
            mutator: mismatchedMutator
        )

        await model.load()

        #expect(model.loadState == .failed)
        #expect(model.projection == nil)
        #expect(model.recoveryMessage?.contains("处理模式") == true)
        #expect(await mismatchedMutator.deleteRequests().isEmpty)
        #expect(try repository.transactions().first(where: { $0.id == "backend-mismatch" })?.items[0].state == .submitted)

        let matchingMutator = BackendResultsMutator(mode: .live, assetIDs: ["asset"])
        model.replaceMutator(matchingMutator)
        await model.load()

        #expect(model.loadState == .ready)
        #expect(model.projection?.source == .transaction("backend-mismatch"))
        #expect(model.projection?.unresolvedIDs == ["asset"])
        #expect(await matchingMutator.deleteRequests().isEmpty)
    }

    // Production break: a reload read failure clears the last valid result or substitutes a competing transaction.
    @Test("Repository reload failures preserve the last exact projection")
    func reloadReadFailuresPreserveProjection() async throws {
        let storage = try SwiftDataTaskRepository(inMemory: true)
        try storage.save(decision: PhotoDecision(assetID: "exact", kind: .deleteCandidate, taskID: "exact-task"))
        try storage.save(transaction: MutationTransaction(
            id: "read-failure-exact",
            operation: .delete,
            items: [MutationItem(assetID: "exact", state: .failed)],
            backendMode: .simulated
        ))
        try storage.save(transaction: MutationTransaction(
            id: "read-failure-competing",
            operation: .delete,
            items: [MutationItem(assetID: "other", state: .succeeded)],
            backendMode: .simulated
        ))
        let repository = CleanupResultFailingRepository(storage: storage)
        let model = CleanupResultsModel(
            source: .transaction("read-failure-exact"),
            repository: repository,
            mutator: ResultsRecordingMutator(assetIDs: ["exact"])
        )
        await model.load()
        let validProjection = try #require(model.projection)

        repository.failTransactionReads = true
        await model.load()

        #expect(model.loadState == .ready)
        #expect(model.projection == validProjection)
        #expect(model.recoveryMessage?.contains("已保留上次结果") == true)

        repository.failTransactionReads = false
        repository.failDecisionReads = true
        await model.load()

        #expect(model.loadState == .ready)
        #expect(model.projection == validProjection)
        #expect(model.recoveryMessage?.contains("已保留上次结果") == true)
    }

    // Production break: an initial repository read failure presents a false empty or competing result.
    @Test("Initial repository read failure has no projection")
    func initialReadFailureHasNoProjection() async throws {
        let storage = try SwiftDataTaskRepository(inMemory: true)
        try storage.save(transaction: MutationTransaction(
            id: "initial-read-failure",
            operation: .delete,
            items: [MutationItem(assetID: "exact", state: .failed)],
            backendMode: .simulated
        ))
        try storage.save(transaction: MutationTransaction(
            id: "initial-competing",
            operation: .delete,
            items: [MutationItem(assetID: "other", state: .succeeded)],
            backendMode: .simulated
        ))
        let repository = CleanupResultFailingRepository(storage: storage)
        repository.failTransactionReads = true
        let model = CleanupResultsModel(
            source: .transaction("initial-read-failure"),
            repository: repository,
            mutator: ResultsRecordingMutator(assetIDs: ["exact"])
        )

        await model.load()

        #expect(model.loadState == .failed)
        #expect(model.projection == nil)
        #expect(model.recoveryMessage?.contains("无法读取") == true)
    }

    // Production break: overlapping retry calls submit the same journal item twice while the first request is suspended.
    @Test("Suspended overlapping retries issue one actual request")
    func suspendedOverlappingRetrySubmitsOnce() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        try repository.save(transaction: MutationTransaction(
            id: "suspended-retry",
            operation: .delete,
            items: [MutationItem(assetID: "retry", state: .failed)],
            backendMode: .simulated
        ))
        let mutator = SuspendedResultsMutator(assetIDs: ["retry"])
        let model = CleanupResultsModel(
            source: .transaction("suspended-retry"),
            repository: repository,
            mutator: mutator
        )
        await model.load()

        let firstRetry = Task { @MainActor in await model.retry() }
        await mutator.waitUntilDeleteStarts()
        let overlappingRetry = Task { @MainActor in await model.retry() }
        await Task.yield()

        #expect(await mutator.deleteRequests() == [["retry"]])
        await mutator.releaseDelete()
        await firstRetry.value
        await overlappingRetry.value

        #expect(await mutator.deleteRequests() == [["retry"]])
        #expect(try repository.transactions().first(where: { $0.id == "suspended-retry" })?.items[0].state == .succeeded)
        #expect(model.projection?.succeededDeleteCount == 1)
        #expect(model.canRetry == false)
    }

    // Production break: a partial retry replaces prior success/stale state or resubmits the first resolved retry item.
    @Test("Same model partial retries retain prior results and narrow the next request")
    func sameModelPartialRetryNarrowsUnresolvedIDs() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        try repository.save(transaction: MutationTransaction(
            id: "partial-retry",
            operation: .delete,
            items: [
                MutationItem(assetID: "prior-success", state: .succeeded),
                MutationItem(assetID: "prior-stale", state: .stale),
                MutationItem(assetID: "first", state: .failed),
                MutationItem(assetID: "second", state: .cancelled)
            ],
            backendMode: .simulated
        ))
        let mutator = SequencedResultsMutator(
            assetIDs: ["first", "second"],
            outcomes: [
                ["first": .succeeded, "second": .failed],
                ["second": .succeeded]
            ]
        )
        let model = CleanupResultsModel(
            source: .transaction("partial-retry"),
            repository: repository,
            mutator: mutator
        )
        await model.load()

        await model.retry()

        let firstRequests = await mutator.deleteRequests()
        #expect(model.projection?.succeededDeleteCount == 2)
        #expect(model.projection?.staleDeleteCount == 1)
        #expect(model.projection?.unresolvedIDs == ["second"])
        #expect(firstRequests.count == 1)
        #expect(Set(firstRequests[0]) == ["first", "second"])

        await model.retry()

        #expect(await mutator.deleteRequests() == [["first", "second"], ["second"]])
        #expect(model.projection?.succeededDeleteCount == 3)
        #expect(model.projection?.staleDeleteCount == 1)
        #expect(model.projection?.unresolvedIDs.isEmpty == true)
        #expect(model.canRetry == false)
    }

    // Production break: decision persistence failure leaves already resolved IDs eligible for destructive resubmission.
    @Test("Post-mutation decision write failure reloads the exact journal before retry recovery")
    func postMutationPersistenceFailureNarrowsRetrySurface() async throws {
        let storage = try SwiftDataTaskRepository(inMemory: true)
        try storage.save(decisions: [
            PhotoDecision(assetID: "success", kind: .deleteCandidate, taskID: "failure-task"),
            PhotoDecision(assetID: "stale", kind: .deleteCandidate, taskID: "failure-task")
        ])
        try storage.save(transaction: MutationTransaction(
            id: "post-mutation-failure",
            operation: .delete,
            items: [
                MutationItem(assetID: "success", state: .failed),
                MutationItem(assetID: "stale", state: .failed)
            ],
            backendMode: .simulated
        ))
        let repository = CleanupResultFailingRepository(storage: storage)
        repository.decisionSaveFailures = 1
        let mutator = ResultsRecordingMutator(assetIDs: ["success"])
        let model = CleanupResultsModel(
            source: .transaction("post-mutation-failure"),
            repository: repository,
            mutator: mutator
        )
        await model.load()

        await model.retry()

        #expect(await mutator.deleteRequests() == [["success"]])
        #expect(model.projection?.succeededDeleteCount == 1)
        #expect(model.projection?.staleDeleteCount == 1)
        #expect(model.projection?.unresolvedIDs.isEmpty == true)
        #expect(model.canRetry == false)
        #expect(model.recoveryMessage?.contains("当前结果已保留") == true)

        await model.retry()

        #expect(await mutator.deleteRequests() == [["success"]])
    }

    // Production break: a no-delete route cannot project its exact persisted summary and instead shows a placeholder.
    @Test("Exact summary source projects meaningful no-delete counts without delete recovery")
    func exactSummaryProjection() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let exactID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let competingID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        try repository.save(summary: CleanupSummary(
            decisions: [
                PhotoDecision(assetID: "keep", kind: .keep, taskID: "summary-task"),
                PhotoDecision(assetID: "archive", kind: .archive, taskID: "summary-task", isSubmitted: true),
                PhotoDecision(assetID: "protect", kind: .protect, taskID: "summary-task"),
                PhotoDecision(assetID: "later", kind: .decideLater, taskID: "summary-task")
            ],
            elapsedSeconds: nil,
            id: exactID
        ))
        try repository.save(summary: CleanupSummary(
            decisions: [PhotoDecision(assetID: "other", kind: .keep, taskID: "other-task")],
            elapsedSeconds: 99,
            id: competingID
        ))
        let model = CleanupResultsModel(
            source: .summary(exactID),
            repository: repository,
            mutator: ResultsRecordingMutator(assetIDs: [])
        )

        await model.load()

        #expect(model.projection?.succeededDeleteCount == 0)
        #expect(model.projection?.unresolvedDeleteCount == 0)
        #expect(model.projection?.staleDeleteCount == 0)
        #expect(model.projection?.archiveSucceededCount == 1)
        #expect(model.projection?.protectCount == 1)
        #expect(model.projection?.decideLaterCount == 1)
        #expect(model.projection?.keepCount == 1)
        #expect(model.projection?.elapsedSeconds == nil)
        #expect(model.projection?.hasDeletionResult == false)
        #expect(model.canRetry == false)
    }

    // Production break: a missing tagged summary can silently display a competing summary or transaction.
    @Test("Missing exact summary never substitutes competing persisted results")
    func missingSummaryIsNotSubstituted() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        try repository.save(summary: CleanupSummary(
            decisions: [PhotoDecision(assetID: "other", kind: .keep, taskID: "other-task")],
            elapsedSeconds: 7
        ))
        try repository.save(transaction: MutationTransaction(
            id: "competing-transaction",
            operation: .delete,
            items: [MutationItem(assetID: "other-delete", state: .succeeded)],
            backendMode: .simulated
        ))
        let missingID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
        let model = CleanupResultsModel(
            source: .summary(missingID),
            repository: repository,
            mutator: ResultsRecordingMutator(assetIDs: [])
        )

        await model.load()

        #expect(model.loadState == .missing)
        #expect(model.projection == nil)
        #expect(model.canRetry == false)
    }

    // Production break: protocol-backed repositories cannot resolve one source without scanning at call sites.
    @Test("Default exact lookup distinguishes found and missing sources")
    func defaultExactLookupFindsOnlyRequestedSource() throws {
        let storage = try SwiftDataTaskRepository(inMemory: true)
        try storage.save(transaction: MutationTransaction(
            id: "default-exact",
            operation: .delete,
            items: [MutationItem(assetID: "exact", state: .succeeded)],
            backendMode: .simulated
        ))
        let exactSummary = CleanupSummary(
            decisions: [PhotoDecision(assetID: "keep", kind: .keep)],
            elapsedSeconds: nil,
            id: UUID(uuidString: "31000000-0000-0000-0000-000000000003")!
        )
        try storage.save(summary: exactSummary)
        let repository: any TaskRepository = CleanupResultFailingRepository(storage: storage)

        switch try repository.transaction(id: "default-exact") {
        case .found(let transaction): #expect(transaction.id == "default-exact")
        case .missing, .corrupt: Issue.record("Expected the exact transaction")
        }
        switch try repository.transaction(id: "missing") {
        case .missing: break
        case .found, .corrupt: Issue.record("Expected a missing transaction")
        }
        switch try repository.summary(id: exactSummary.id) {
        case .found(let summary): #expect(summary.id == exactSummary.id)
        case .missing, .corrupt: Issue.record("Expected the exact summary")
        }
    }

    // Production break: corrupt payloads are compact-mapped away and reported as ordinary missing results.
    @Test("SwiftData exact lookup reports a corrupt transaction without substituting a competitor")
    func corruptTransactionPayloadIsReportedExactly() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Schema(versionedSchema: PhotoBoxSchemaV1.self),
            configurations: [configuration]
        )
        let repository = SwiftDataTaskRepository(container: container)
        try repository.save(transaction: MutationTransaction(
            id: "corrupt-exact",
            operation: .delete,
            items: [MutationItem(assetID: "exact", state: .failed)],
            backendMode: .simulated
        ))
        try repository.save(transaction: MutationTransaction(
            id: "corrupt-competitor",
            operation: .delete,
            items: [MutationItem(assetID: "other", state: .succeeded)],
            backendMode: .simulated
        ))
        let corruptID = "corrupt-exact"
        var settings = WorkflowSettings.defaults
        settings.pendingResultSource = .transaction(corruptID)
        try repository.save(settings: settings)
        let descriptor = FetchDescriptor<PersistedMutationTransaction>(
            predicate: #Predicate { $0.identifier == corruptID }
        )
        let record = try #require(container.mainContext.fetch(descriptor).first)
        record.payload = Data([0xFF])
        try container.mainContext.save()

        switch try repository.transaction(id: corruptID) {
        case .corrupt: break
        case .found, .missing: Issue.record("Expected corrupt exact transaction lookup")
        }

        let model = CleanupResultsModel(
            source: .transaction(corruptID),
            repository: repository,
            mutator: ResultsRecordingMutator(assetIDs: ["exact"])
        )
        await model.load()

        #expect(model.loadState == .failed)
        #expect(model.projection == nil)
        #expect(model.recoveryMessage?.contains("损坏") == true)

        let restored = AppModel(library: CleanupResultsReader(assetIDs: []), repository: repository)
        #expect(restored.activeRoute == .result(.transaction(corruptID)))
        #expect(restored.taskNavigationPath == [.result(.transaction(corruptID))])
        #expect(try repository.settings().pendingResultSource == .transaction(corruptID))
    }

    // Production break: invalid summary scalars decode into a plausible result instead of corruption recovery.
    @Test("Persisted summary rejects negative and non-finite scalars")
    func persistedSummaryRejectsInvalidScalars() {
        let summary = CleanupSummary(
            id: UUID(uuidString: "32000000-0000-0000-0000-000000000003")!,
            keptCount: 1,
            deleteCandidateCount: 1,
            archivedCount: 1,
            protectedCount: 1,
            deferredCount: 1,
            estimatedReclaimableBytes: 1,
            elapsedSeconds: 1,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let record = PersistedCleanupSummary(summary)

        record.keptCount = -1
        #expect(record.value == nil)
        record.keptCount = 1
        record.deleteCandidateCount = -1
        #expect(record.value == nil)
        record.deleteCandidateCount = 1
        record.archivedCount = -1
        #expect(record.value == nil)
        record.archivedCount = 1
        record.protectedCount = -1
        #expect(record.value == nil)
        record.protectedCount = 1
        record.deferredCount = -1
        #expect(record.value == nil)
        record.deferredCount = 1
        record.estimatedReclaimableBytes = -1
        #expect(record.value == nil)
        record.estimatedReclaimableBytes = 1
        record.elapsedSeconds = -1
        #expect(record.value == nil)
        record.elapsedSeconds = .infinity
        #expect(record.value == nil)
        record.elapsedSeconds = .nan
        #expect(record.value == nil)
    }

    // Production break: a corrupt exact summary is compact-mapped away and relaunch falls through to another route.
    @Test("SwiftData corrupt summary remains the exact pending Result across relaunch")
    func corruptSummaryIsReportedAndRestoredExactly() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Schema(versionedSchema: PhotoBoxSchemaV1.self),
            configurations: [configuration]
        )
        let repository = SwiftDataTaskRepository(container: container)
        let exactID = UUID(uuidString: "33000000-0000-0000-0000-000000000003")!
        let competingID = UUID(uuidString: "34000000-0000-0000-0000-000000000003")!
        try repository.save(summary: CleanupSummary(
            decisions: [PhotoDecision(assetID: "exact", kind: .keep, taskID: "exact-task")],
            elapsedSeconds: 4,
            id: exactID
        ))
        try repository.save(summary: CleanupSummary(
            decisions: [PhotoDecision(assetID: "other", kind: .keep, taskID: "other-task")],
            elapsedSeconds: 8,
            id: competingID
        ))
        var settings = WorkflowSettings.defaults
        settings.pendingResultSource = .summary(exactID)
        try repository.save(settings: settings)

        let exactIdentifier = exactID.uuidString
        let descriptor = FetchDescriptor<PersistedCleanupSummary>(
            predicate: #Predicate { $0.identifier == exactIdentifier }
        )
        let record = try #require(container.mainContext.fetch(descriptor).first)
        record.estimatedReclaimableBytes = -1
        try container.mainContext.save()

        switch try repository.summary(id: exactID) {
        case .corrupt: break
        case .found, .missing: Issue.record("Expected corrupt exact summary lookup")
        }

        let model = CleanupResultsModel(
            source: .summary(exactID),
            repository: repository,
            mutator: ResultsRecordingMutator(assetIDs: [])
        )
        await model.load()

        #expect(model.loadState == .failed)
        #expect(model.projection == nil)
        #expect(model.recoveryMessage?.contains("损坏") == true)

        let restored = AppModel(library: CleanupResultsReader(assetIDs: []), repository: repository)
        #expect(restored.activeRoute == .result(.summary(exactID)))
        #expect(restored.taskNavigationPath == [.result(.summary(exactID))])
        #expect(try repository.settings().pendingResultSource == .summary(exactID))
    }

    // Production break: an exact lookup throw discards the pending Result route and its visible recovery warning.
    @Test("Exact lookup failure restores pending Result with a persistence warning")
    func exactLookupFailureRestoresPendingResult() throws {
        let storage = try SwiftDataTaskRepository(inMemory: true)
        let transactionID = "lookup-failure-exact"
        try storage.save(transaction: MutationTransaction(
            id: transactionID,
            operation: .delete,
            items: [MutationItem(assetID: "exact", state: .failed)],
            backendMode: .simulated
        ))
        var settings = WorkflowSettings.defaults
        settings.pendingResultSource = .transaction(transactionID)
        try storage.save(settings: settings)
        let repository = CleanupResultFailingRepository(storage: storage)
        repository.failTransactionReads = true

        let restored = AppModel(library: CleanupResultsReader(assetIDs: []), repository: repository)

        #expect(restored.activeRoute == .result(.transaction(transactionID)))
        #expect(restored.taskNavigationPath == [.result(.transaction(transactionID))])
        #expect(restored.persistenceErrorMessage != nil)
        #expect(try storage.settings().pendingResultSource == .transaction(transactionID))
    }
}

@Suite("No-delete cleanup result routing")
@MainActor
struct NoDeleteCleanupResultRoutingTests {
    // Production break: completing a keep-only task leaves the user on the decision screen with no truthful result.
    @Test("Single-decision completion persists and routes its exact no-delete summary")
    func singleDecisionCompletionRoutesSummary() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let task = noDeleteTask(id: "keep-task", assetIDs: ["keep"], createdAt: Date(timeIntervalSince1970: 100))
        try repository.save(task: task)
        let model = AppModel(
            library: CleanupResultsReader(assetIDs: ["keep"]),
            repository: repository,
            mutator: ResultsRecordingMutator(assetIDs: ["keep"]),
            initialScan: .idle,
            initialActiveRoute: .task(task.id)
        )
        await model.prepareSingleDecision(taskID: task.id)

        try model.singleDecisionFlow(for: task.id)?.decide(.keep)

        let summary = try #require(repository.summaries().first)
        _ = try #require(repository.tasks().first)
        #expect(summary.id == CleanupSummary.identifier(forTaskID: task.id))
        #expect(summary.keptCount == 1)
        #expect(summary.deleteCandidateCount == 0)
        #expect(summary.elapsedSeconds == nil)
        #expect(model.taskNavigationPath == [.task(task.id), .result(.summary(summary.id))])
        #expect(try repository.settings().pendingResultSource == .summary(summary.id))
    }

    // Production break: a successful terminal archive advances the task but never creates its no-delete result.
    @Test("Terminal archive completion routes the task-scoped summary")
    func terminalArchiveRoutesSummary() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let task = noDeleteTask(id: "archive-task", assetIDs: ["archive"], createdAt: Date(timeIntervalSince1970: 200))
        try repository.save(task: task)
        let mutator = SimulatedPhotoLibraryMutator(
            assetIDs: ["archive"],
            albums: [PhotoAlbumDescriptor(id: "target", title: "目标", assetCount: 0)]
        )
        let model = AppModel(
            library: CleanupResultsReader(assetIDs: ["archive"]),
            repository: repository,
            mutator: mutator,
            initialScan: .idle,
            initialActiveRoute: .task(task.id)
        )
        await model.prepareSingleDecision(taskID: task.id)
        model.singleDecisionFlow(for: task.id)?.requestArchive()
        // Exercise the legacy routed album handoff, whose completion still
        // records the archive decision and result summary.
        model.taskNavigationPath = [.task(task.id), .albumSelection("archive")]
        model.inlineAlbumAssetID = nil
        await model.prepareAlbumSelection(assetID: "archive")

        await model.albumSelectionFlow(for: "archive")?.selectAlbum(id: "target")

        let summary = try #require(repository.summaries().first)
        #expect(summary.id == CleanupSummary.identifier(forTaskID: task.id))
        #expect(summary.archivedCount == 1)
        #expect(summary.deleteCandidateCount == 0)
        #expect(summary.elapsedSeconds == nil)
        #expect(model.taskNavigationPath == [.task(task.id), .result(.summary(summary.id))])
    }

    // Production break: repeated completion callbacks duplicate both the persisted summary and result route.
    @Test("No-delete completion is idempotent for the exact task")
    func completionIsIdempotent() throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        var task = noDeleteTask(id: "repeat-task", assetIDs: ["keep"], createdAt: Date(timeIntervalSince1970: 300))
        task.status = .completed
        task.currentAssetIndex = 1
        task.updatedAt = Date(timeIntervalSince1970: 330)
        try repository.save(task: task)
        try repository.save(decision: PhotoDecision(assetID: "keep", kind: .keep, taskID: task.id))
        let model = AppModel(
            library: CleanupResultsReader(assetIDs: ["keep"]),
            repository: repository,
            mutator: ResultsRecordingMutator(assetIDs: ["keep"]),
            initialScan: .idle,
            initialActiveRoute: .task(task.id)
        )

        model.completeNoDeleteCleanupIfEligible(taskID: task.id)
        model.completeNoDeleteCleanupIfEligible(taskID: task.id)

        let summaries = try repository.summaries()
        #expect(summaries.count == 1)
        #expect(model.taskNavigationPath == [.task(task.id), .result(.summary(summaries[0].id))])
    }

    // Production break: a task with pending deletion is incorrectly persisted as a no-delete summary.
    @Test("Delete candidates do not produce a no-delete result")
    func deleteCandidateDoesNotRouteSummary() throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        var task = noDeleteTask(id: "delete-task", assetIDs: ["keep", "delete"], createdAt: Date(timeIntervalSince1970: 350))
        task.status = .completed
        task.currentAssetIndex = 2
        task.updatedAt = Date(timeIntervalSince1970: 370)
        try repository.save(task: task)
        try repository.save(decisions: [
            PhotoDecision(assetID: "keep", kind: .keep, taskID: task.id),
            PhotoDecision(assetID: "delete", kind: .deleteCandidate, taskID: task.id)
        ])
        let model = AppModel(
            library: CleanupResultsReader(assetIDs: ["keep", "delete"]),
            repository: repository,
            mutator: ResultsRecordingMutator(assetIDs: ["keep", "delete"]),
            initialScan: .idle,
            initialActiveRoute: .task(task.id)
        )

        model.completeNoDeleteCleanupIfEligible(taskID: task.id)

        #expect(try repository.summaries().isEmpty)
        #expect(model.taskNavigationPath == [.task(task.id)])
    }

    // Production break: task completion produces unstable summary routes or aliases two different tasks.
    @Test("Task-scoped summary identity is stable and distinguishes exact task IDs")
    func taskSummaryIdentityIsStableAndDistinct() throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let firstID = CleanupSummary.identifier(forTaskID: "upsert-task")
        let otherID = CleanupSummary.identifier(forTaskID: "upsert-task-other")
        #expect(firstID == CleanupSummary.identifier(forTaskID: "upsert-task"))
        #expect(firstID != otherID)
        try repository.save(summary: CleanupSummary(
            decisions: [PhotoDecision(assetID: "keep", kind: .keep, taskID: "upsert-task")],
            elapsedSeconds: 10,
            id: firstID
        ))
        try repository.save(summary: CleanupSummary(
            decisions: [PhotoDecision(assetID: "protect", kind: .protect, taskID: "upsert-task")],
            elapsedSeconds: 20,
            id: firstID
        ))
        try repository.save(summary: CleanupSummary(
            decisions: [PhotoDecision(assetID: "other", kind: .keep, taskID: "upsert-task-other")],
            elapsedSeconds: nil,
            id: otherID
        ))

        let summaries = try repository.summaries()
        #expect(summaries.count == 2)
        let updated = try #require(summaries.first(where: { $0.id == firstID }))
        #expect(updated.protectedCount == 1)
        #expect(updated.keptCount == 0)
        #expect(updated.elapsedSeconds == 20)
        #expect(summaries.contains(where: { $0.id == otherID }))
    }

    // Production break: relaunch restoration substitutes whichever historical result happens to exist.
    @Test("Relaunch restores only the exact tagged summary source")
    func relaunchRestoresExactSummary() throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let exact = CleanupSummary(
            decisions: [PhotoDecision(assetID: "exact", kind: .keep, taskID: "exact-task")],
            elapsedSeconds: 5
        )
        let competing = CleanupSummary(
            decisions: [PhotoDecision(assetID: "other", kind: .protect, taskID: "other-task")],
            elapsedSeconds: 8
        )
        try repository.save(summary: competing)
        try repository.save(summary: exact)
        try repository.save(transaction: MutationTransaction(
            id: "other-transaction",
            operation: .delete,
            items: [MutationItem(assetID: "deleted", state: .succeeded)],
            backendMode: .simulated
        ))
        var settings = WorkflowSettings.defaults
        settings.pendingResultSource = .summary(exact.id)
        try repository.save(settings: settings)

        let restored = AppModel(library: CleanupResultsReader(assetIDs: []), repository: repository)

        #expect(restored.activeRoute == .result(.summary(exact.id)))
        #expect(restored.taskNavigationPath == [.result(.summary(exact.id))])
    }

    // Production break: an unavailable pending result source falls back to a competing historical result.
    @Test("Missing pending result source does not substitute a competing result")
    func missingPendingSourceDoesNotSubstitute() throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        try repository.save(summary: CleanupSummary(
            decisions: [PhotoDecision(assetID: "other", kind: .keep, taskID: "other-task")],
            elapsedSeconds: 1
        ))
        try repository.save(transaction: MutationTransaction(
            id: "other-transaction",
            operation: .delete,
            items: [MutationItem(assetID: "other", state: .succeeded)],
            backendMode: .simulated
        ))
        var settings = WorkflowSettings.defaults
        settings.pendingResultSource = .summary(UUID(uuidString: "40000000-0000-0000-0000-000000000004")!)
        try repository.save(settings: settings)

        let restored = AppModel(library: CleanupResultsReader(assetIDs: []), repository: repository)

        #expect(restored.activeRoute == nil)
        #expect(restored.taskNavigationPath.isEmpty)
    }

    // Production break: returning from Result leaves the pending source persisted and reopens it on relaunch.
    @Test("Explicit return clears the exact pending result source")
    func returnClearsPendingSource() throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let summary = CleanupSummary(
            decisions: [PhotoDecision(assetID: "keep", kind: .keep, taskID: "return-task")],
            elapsedSeconds: 2
        )
        try repository.save(summary: summary)
        var settings = WorkflowSettings.defaults
        settings.pendingResultSource = .summary(summary.id)
        try repository.save(settings: settings)
        let model = AppModel(library: CleanupResultsReader(assetIDs: []), repository: repository)

        model.returnFromCleanupResults()

        #expect(try repository.settings().pendingResultSource == nil)
        #expect(model.activeRoute == nil)
        #expect(model.taskNavigationPath.isEmpty)
    }

    // Production break: summary persistence failure still routes to a result that cannot be reconstructed.
    @Test("Summary write failure does not route")
    func summaryWriteFailureDoesNotRoute() throws {
        let storage = try SwiftDataTaskRepository(inMemory: true)
        var task = noDeleteTask(id: "summary-failure", assetIDs: ["keep"], createdAt: Date(timeIntervalSince1970: 500))
        task.status = .completed
        task.currentAssetIndex = 1
        task.updatedAt = Date(timeIntervalSince1970: 510)
        try storage.save(task: task)
        try storage.save(decision: PhotoDecision(assetID: "keep", kind: .keep, taskID: task.id))
        let repository = CleanupResultFailingRepository(storage: storage, failure: .summarySave)
        let model = AppModel(
            library: CleanupResultsReader(assetIDs: ["keep"]),
            repository: repository,
            mutator: ResultsRecordingMutator(assetIDs: ["keep"]),
            initialScan: .idle,
            initialActiveRoute: .task(task.id)
        )

        model.completeNoDeleteCleanupIfEligible(taskID: task.id)

        #expect(model.taskNavigationPath == [.task(task.id)])
        #expect(try storage.summaries().isEmpty)
        #expect(try storage.settings().pendingResultSource == nil)
    }

    // Production break: settings persistence failure blocks the in-memory result transition.
    @Test("Pending source write failure still routes with recovery guidance")
    func settingsWriteFailureStillRoutes() throws {
        let storage = try SwiftDataTaskRepository(inMemory: true)
        var task = noDeleteTask(id: "settings-failure", assetIDs: ["keep"], createdAt: Date(timeIntervalSince1970: 600))
        task.status = .completed
        task.currentAssetIndex = 1
        task.updatedAt = Date(timeIntervalSince1970: 610)
        try storage.save(task: task)
        try storage.save(decision: PhotoDecision(assetID: "keep", kind: .keep, taskID: task.id))
        let repository = CleanupResultFailingRepository(storage: storage, failure: .settingsSave)
        let model = AppModel(
            library: CleanupResultsReader(assetIDs: ["keep"]),
            repository: repository,
            mutator: ResultsRecordingMutator(assetIDs: ["keep"]),
            initialScan: .idle,
            initialActiveRoute: .task(task.id)
        )

        model.completeNoDeleteCleanupIfEligible(taskID: task.id)

        let summary = try #require(storage.summaries().first)
        #expect(model.taskNavigationPath == [.task(task.id), .result(.summary(summary.id))])
        #expect(model.activeRoute == .result(.summary(summary.id)))
        #expect(model.persistenceErrorMessage?.contains("无法保存") == true)
        #expect(try storage.summaries().count == 1)
        #expect(try storage.settings().pendingResultSource == nil)
    }

    // Production break: Result appends behind Delete Review, exposing its stale retry through native Back.
    @Test("Result replaces trailing Delete Review route")
    func resultReplacesDeleteReviewRoute() throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        var task = noDeleteTask(id: "replace-review", assetIDs: ["keep"], createdAt: Date(timeIntervalSince1970: 700))
        task.status = .completed
        task.currentAssetIndex = 1
        try repository.save(task: task)
        try repository.save(decision: PhotoDecision(assetID: "keep", kind: .keep, taskID: task.id))
        let model = AppModel(
            library: CleanupResultsReader(assetIDs: ["keep"]),
            repository: repository,
            mutator: ResultsRecordingMutator(assetIDs: ["keep"]),
            initialScan: .idle,
            initialActiveRoute: .deleteReview
        )

        model.completeNoDeleteCleanupIfEligible(taskID: task.id)

        let summary = try #require(repository.summaries().first)
        #expect(model.taskNavigationPath == [.result(.summary(summary.id))])
    }

    // Production break: a failed pending-source clear traps the user on Result in memory.
    @Test("Return leaves Result in memory even when pending-source clearing fails")
    func returnSettingsFailureStillReturnsInMemory() throws {
        let storage = try SwiftDataTaskRepository(inMemory: true)
        let summary = CleanupSummary(
            decisions: [PhotoDecision(assetID: "keep", kind: .keep, taskID: "return-failure")],
            elapsedSeconds: nil,
            id: CleanupSummary.identifier(forTaskID: "return-failure")
        )
        try storage.save(summary: summary)
        var settings = WorkflowSettings.defaults
        settings.pendingResultSource = .summary(summary.id)
        try storage.save(settings: settings)
        let repository = CleanupResultFailingRepository(storage: storage, failure: .settingsSave)
        let model = AppModel(library: CleanupResultsReader(assetIDs: []), repository: repository)

        model.returnFromCleanupResults()

        #expect(model.activeRoute == nil)
        #expect(model.taskNavigationPath.isEmpty)
        #expect(model.persistenceErrorMessage?.contains("无法清除") == true)
        #expect(try storage.settings().pendingResultSource == .summary(summary.id))
        let relaunched = AppModel(library: CleanupResultsReader(assetIDs: []), repository: storage)
        #expect(relaunched.activeRoute == .result(.summary(summary.id)))
    }

    // Production break: transaction result restoration and explicit consumption are only proven for summaries.
    @Test("Transaction result restores exactly and Return consumes it")
    func transactionResultRestoresAndReturnConsumesSource() throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        try repository.save(transaction: MutationTransaction(
            id: "restore-transaction",
            operation: .delete,
            items: [MutationItem(assetID: "exact", state: .succeeded)],
            backendMode: .simulated
        ))
        try repository.save(transaction: MutationTransaction(
            id: "competing-transaction",
            operation: .delete,
            items: [MutationItem(assetID: "other", state: .succeeded)],
            backendMode: .simulated
        ))
        var settings = WorkflowSettings.defaults
        settings.pendingResultSource = .transaction("restore-transaction")
        try repository.save(settings: settings)

        let restored = AppModel(library: CleanupResultsReader(assetIDs: []), repository: repository)
        #expect(restored.activeRoute == .result(.transaction("restore-transaction")))
        #expect(restored.taskNavigationPath == [.result(.transaction("restore-transaction"))])

        restored.returnFromCleanupResults()

        #expect(try repository.settings().pendingResultSource == nil)
        let relaunched = AppModel(library: CleanupResultsReader(assetIDs: []), repository: repository)
        #expect(relaunched.activeRoute == nil)
        #expect(relaunched.taskNavigationPath.isEmpty)
    }

    private func noDeleteTask(id: String, assetIDs: [String], createdAt: Date) -> CleanupTask {
        CleanupTask(
            id: id,
            type: .screenshots,
            title: "整理",
            reason: "测试",
            assetIDs: assetIDs,
            estimatedBytes: 0,
            estimatedMinutes: 1,
            risk: .low,
            confidence: 1,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }
}

private actor CleanupResultsReader: PhotoLibraryReading {
    private let assetIDs: [String]

    init(assetIDs: [String]) { self.assetIDs = assetIDs }

    func authorizationStatus() -> PhotoAuthorization { .authorized }
    func requestAuthorization() -> PhotoAuthorization { .authorized }
    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> {
        AsyncStream { $0.finish() }
    }
    func accessibleAssetDescriptors() -> [PhotoAssetDescriptor] {
        assetIDs.map {
            PhotoAssetDescriptor(
                id: $0,
                mediaType: .photo,
                creationDate: nil,
                pixelWidth: 1,
                pixelHeight: 1,
                duration: 0,
                estimatedBytes: 1,
                isFavorite: false,
                isEdited: false,
                isScreenshot: true,
                burstIdentifier: nil,
                availability: .local
            )
        }
    }
}

@MainActor
private final class CleanupResultFailingRepository: TaskRepository {
    enum Failure { case summarySave, settingsSave }

    private let storage: SwiftDataTaskRepository
    private let failure: Failure?
    var failTransactionReads = false
    var failDecisionReads = false
    var decisionSaveFailures = 0

    init(storage: SwiftDataTaskRepository, failure: Failure? = nil) {
        self.storage = storage
        self.failure = failure
    }

    func save(checkpoint: ScanCheckpoint) throws { try storage.save(checkpoint: checkpoint) }
    func latestCheckpoint() throws -> ScanCheckpoint? { try storage.latestCheckpoint() }
    func save(task: CleanupTask) throws { try storage.save(task: task) }
    func tasks() throws -> [CleanupTask] { try storage.tasks() }
    func save(decision: PhotoDecision) throws {
        if decisionSaveFailures > 0 {
            decisionSaveFailures -= 1
            throw CleanupResultPersistenceFailure.forced
        }
        try storage.save(decision: decision)
    }
    func applySingleDecision(_ decision: PhotoDecision, undo: DecisionUndoEntry, task: CleanupTask?) throws {
        try storage.applySingleDecision(decision, undo: undo, task: task)
    }
    func save(decisions: [PhotoDecision]) throws { try storage.save(decisions: decisions) }
    func completeComparison(taskID: String, decisions: [PhotoDecision]) throws {
        try storage.completeComparison(taskID: taskID, decisions: decisions)
    }
    func completeArchive(transaction: MutationTransaction, decision: PhotoDecision, recentAlbumIDs: [String]) throws {
        try storage.completeArchive(transaction: transaction, decision: decision, recentAlbumIDs: recentAlbumIDs)
    }
    func removeDecision(for assetID: String) throws { try storage.removeDecision(for: assetID) }
    func decision(for assetID: String) throws -> PhotoDecision? { try storage.decision(for: assetID) }
    func decisions() throws -> [PhotoDecision] {
        if failDecisionReads { throw CleanupResultPersistenceFailure.forced }
        return try storage.decisions()
    }
    func save(undo: DecisionUndoEntry) throws { try storage.save(undo: undo) }
    func latestUndo() throws -> DecisionUndoEntry? { try storage.latestUndo() }
    func removeUndo(id: UUID) throws { try storage.removeUndo(id: id) }
    func save(transaction: MutationTransaction) throws { try storage.save(transaction: transaction) }
    func transactions() throws -> [MutationTransaction] {
        if failTransactionReads { throw CleanupResultPersistenceFailure.forced }
        return try storage.transactions()
    }
    func save(settings: WorkflowSettings) throws {
        if failure == .settingsSave { throw CleanupResultPersistenceFailure.forced }
        try storage.save(settings: settings)
    }
    func settings() throws -> WorkflowSettings { try storage.settings() }
    func save(summary: CleanupSummary) throws {
        if failure == .summarySave { throw CleanupResultPersistenceFailure.forced }
        try storage.save(summary: summary)
    }
    func summaries() throws -> [CleanupSummary] { try storage.summaries() }
    func reconcile(availableAssetIDs: Set<String>) throws {
        try storage.reconcile(availableAssetIDs: availableAssetIDs)
    }
    func clearHistory() throws { try storage.clearHistory() }
}

private enum CleanupResultPersistenceFailure: Error { case forced }

private actor BackendResultsMutator: PhotoLibraryMutating {
    let backendMode: MutationBackendMode
    private let assetIDs: Set<String>
    private var requests: [[String]] = []

    init(mode: MutationBackendMode, assetIDs: Set<String>) {
        backendMode = mode
        self.assetIDs = assetIDs
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
        return PhotoMutationBatch(
            operation: .delete,
            items: assetIDs.map { MutationItem(assetID: $0, state: .succeeded) },
            targetAlbumID: nil
        )
    }
    func deleteRequests() -> [[String]] { requests }
}

private actor SuspendedResultsMutator: PhotoLibraryMutating {
    let backendMode = MutationBackendMode.simulated
    private let assetIDs: Set<String>
    private var requests: [[String]] = []
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

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
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
        return PhotoMutationBatch(
            operation: .delete,
            items: assetIDs.map { MutationItem(assetID: $0, state: .succeeded) },
            targetAlbumID: nil
        )
    }
    func waitUntilDeleteStarts() async {
        guard requests.isEmpty else { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func releaseDelete() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
    func deleteRequests() -> [[String]] { requests }
}

private actor SequencedResultsMutator: PhotoLibraryMutating {
    let backendMode = MutationBackendMode.simulated
    private let assetIDs: Set<String>
    private let outcomes: [[String: MutationItemState]]
    private var requests: [[String]] = []

    init(assetIDs: Set<String>, outcomes: [[String: MutationItemState]]) {
        self.assetIDs = assetIDs
        self.outcomes = outcomes
    }

    func availableAssetIDs(for requestedIDs: [String]) -> Set<String> { assetIDs.intersection(requestedIDs) }
    func listAlbums() -> [PhotoAlbumDescriptor] { [] }
    func createAlbum(named title: String) -> PhotoAlbumDescriptor? { nil }
    func archivedAssetIDs(for requestedIDs: [String], inAlbumID albumID: String) -> Set<String> { [] }
    func addAssets(withIDs assetIDs: [String], toAlbumID albumID: String) -> PhotoMutationBatch {
        PhotoMutationBatch(operation: .archive, items: [], targetAlbumID: albumID)
    }
    func deleteAssets(withIDs assetIDs: [String]) -> PhotoMutationBatch {
        let index = requests.count
        let outcome = outcomes.indices.contains(index) ? outcomes[index] : [:]
        requests.append(assetIDs)
        return PhotoMutationBatch(
            operation: .delete,
            items: assetIDs.map { MutationItem(assetID: $0, state: outcome[$0] ?? .succeeded) },
            targetAlbumID: nil
        )
    }
    func deleteRequests() -> [[String]] { requests }
}

actor ResultsRecordingMutator: PhotoLibraryMutating {
    let backendMode = MutationBackendMode.simulated
    let reconciliationMode = MutationReconciliationMode.deterministicSimulation
    private let assetIDs: Set<String>
    private var requests: [[String]] = []

    init(assetIDs: Set<String>) { self.assetIDs = assetIDs }

    func availableAssetIDs(for requestedIDs: [String]) -> Set<String> { assetIDs.intersection(requestedIDs) }
    func listAlbums() -> [PhotoAlbumDescriptor] { [] }
    func createAlbum(named title: String) -> PhotoAlbumDescriptor? { nil }
    func archivedAssetIDs(for requestedIDs: [String], inAlbumID albumID: String) -> Set<String> { [] }
    func addAssets(withIDs assetIDs: [String], toAlbumID albumID: String) -> PhotoMutationBatch {
        PhotoMutationBatch(operation: .archive, items: [], targetAlbumID: albumID)
    }
    func deleteAssets(withIDs assetIDs: [String]) -> PhotoMutationBatch {
        requests.append(assetIDs)
        return PhotoMutationBatch(
            operation: .delete,
            items: assetIDs.map { MutationItem(assetID: $0, state: .succeeded) },
            targetAlbumID: nil
        )
    }
    func deleteRequests() -> [[String]] { requests }
}
