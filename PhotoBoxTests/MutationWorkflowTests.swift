import Foundation
import Testing
@testable import PhotoBox

@Suite("Deterministic simulated mutations")
struct SimulatedMutationTests {
    @Test("Configured per-asset outcomes never invoke a live backend")
    func configuredOutcomes() async {
        let mutator = SimulatedPhotoLibraryMutator(
            assetIDs: ["success", "failure", "stale", "cancelled"],
            configuredOutcomes: [
                "failure": .failed,
                "stale": .stale,
                "cancelled": .cancelled
            ]
        )

        let result = await mutator.deleteAssets(withIDs: [
            "success", "failure", "stale", "cancelled"
        ])

        #expect(await mutator.backendMode == .simulated)
        #expect(result.items == [
            MutationItem(assetID: "success", state: .succeeded),
            MutationItem(assetID: "failure", state: .failed),
            MutationItem(assetID: "stale", state: .stale),
            MutationItem(assetID: "cancelled", state: .cancelled)
        ])
        #expect(await mutator.availableAssetIDs(for: ["success", "failure", "stale", "cancelled"])
            == ["failure", "stale", "cancelled"])
        #expect(await mutator.submittedAssetIDs == ["success", "failure", "stale", "cancelled"])
    }

    @Test("Album creation succeeds while a missing target preserves the asset")
    func albumFailureRecovery() async throws {
        let mutator = SimulatedPhotoLibraryMutator(assetIDs: ["asset"])
        let album = try #require(await mutator.createAlbum(named: "旅行"))
        let archived = await mutator.addAssets(withIDs: ["asset"], toAlbumID: album.id)
        let missing = await mutator.addAssets(withIDs: ["asset"], toAlbumID: "missing")

        #expect(archived.items == [MutationItem(assetID: "asset", state: .succeeded)])
        #expect(missing.items == [MutationItem(assetID: "asset", state: .failed)])
        #expect(await mutator.availableAssetIDs(for: ["asset"]) == ["asset"])
        #expect(await mutator.listAlbums().first?.title == "旅行")
    }

    @Test("The live PhotoKit mutator is an explicit backend")
    func liveBackendExists() async {
        let mutator: any PhotoLibraryMutating = LivePhotoLibraryMutator()
        #expect(await mutator.backendMode == .live)
    }
}

@Suite("Journaled mutation coordination")
@MainActor
struct MutationCoordinatorTests {
    @Test("Partial retry submits only unresolved available identifiers")
    func retriesOnlyFailures() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let mutator = SimulatedPhotoLibraryMutator(
            assetIDs: ["a", "b"],
            configuredOutcomes: ["b": .failed]
        )
        let coordinator = MutationCoordinator(repository: repository, mutator: mutator)

        let first = try await coordinator.submit(
            operation: .delete,
            assetIDs: ["a", "b", "stale"]
        )
        #expect(first.backendMode == .simulated)
        #expect(first.items == [
            MutationItem(assetID: "a", state: .succeeded),
            MutationItem(assetID: "b", state: .failed),
            MutationItem(assetID: "stale", state: .stale)
        ])

        await mutator.setOutcome(.succeeded, for: "b")
        let retried = try await coordinator.retry(transactionID: first.id)

        #expect(retried.items.map(\.state) == [.succeeded, .succeeded, .stale])
        #expect(await mutator.submittedAssetIDs == ["a", "b", "b"])
    }

    // Production break: a retry ignores a changed review selection and resubmits every unresolved journal item.
    @Test("Selected retry submits only the requested unresolved journal IDs")
    func selectedRetrySubmitsOnlyRequestedUnresolvedIDs() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let mutator = SimulatedPhotoLibraryMutator(
            assetIDs: ["a", "b"],
            configuredOutcomes: ["a": .failed, "b": .failed]
        )
        let coordinator = MutationCoordinator(repository: repository, mutator: mutator)
        let first = try await coordinator.submit(operation: .delete, assetIDs: ["a", "b"])
        await mutator.setOutcome(.succeeded, for: "a")
        await mutator.setOutcome(.succeeded, for: "b")

        let retried = try await coordinator.retry(transactionID: first.id, assetIDs: ["b"])

        #expect(retried.items == [
            MutationItem(assetID: "a", state: .failed),
            MutationItem(assetID: "b", state: .succeeded)
        ])
        #expect(await mutator.submittedAssetIDs == ["a", "b", "b"])
        #expect(try repository.transactions().map(\.id) == [first.id])
    }

    // Production break: a retry accepts a succeeded or stale journal ID and repeats resolved work.
    @Test("Selected retry rejects IDs that are no longer unresolved")
    func selectedRetryRejectsResolvedIDs() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let mutator = SimulatedPhotoLibraryMutator(assetIDs: ["resolved", "retry"], configuredOutcomes: ["retry": .failed])
        let coordinator = MutationCoordinator(repository: repository, mutator: mutator)
        let transaction = try await coordinator.submit(operation: .delete, assetIDs: ["resolved", "retry"])

        do {
            _ = try await coordinator.retry(transactionID: transaction.id, assetIDs: ["resolved"])
            Issue.record("Expected retry selection validation to reject a resolved ID")
        } catch let error as MutationCoordinatorError {
            #expect(error == .invalidRetrySelection(transaction.id))
        }

        #expect(await mutator.submittedAssetIDs == ["resolved", "retry"])
    }

    @Test("Relaunch reconciliation resolves interrupted deletion before retry")
    func relaunchReconciliation() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        try repository.save(transaction: MutationTransaction(
            id: "interrupted",
            operation: .delete,
            items: [
                MutationItem(assetID: "already-gone", state: .submitted),
                MutationItem(assetID: "still-here", state: .submitted)
            ],
            submittedAt: Date(timeIntervalSince1970: 100),
            backendMode: .simulated
        ))
        let mutator = SimulatedPhotoLibraryMutator(assetIDs: ["still-here"])
        let coordinator = MutationCoordinator(repository: repository, mutator: mutator)

        try await coordinator.reconcileInterruptedTransactions()

        #expect(try repository.transactions().first?.items == [
            MutationItem(assetID: "already-gone", state: .succeeded),
            MutationItem(assetID: "still-here", state: .failed)
        ])
        #expect(await mutator.submittedAssetIDs.isEmpty)
    }

    @Test("Deletion reconciliation stays retryable when the library scope is empty")
    func emptyScopeDoesNotClaimDeletionSuccess() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        try repository.save(transaction: MutationTransaction(
            id: "empty-scope",
            operation: .delete,
            items: [MutationItem(assetID: "asset", state: .submitted)],
            submittedAt: Date(timeIntervalSince1970: 100),
            backendMode: .simulated
        ))
        let coordinator = MutationCoordinator(
            repository: repository,
            mutator: SimulatedPhotoLibraryMutator(assetIDs: [])
        )

        try await coordinator.reconcileInterruptedTransactions()

        let item = try #require(repository.transactions().first?.items.first)
        #expect(item.state == .failed)
        #expect(item.errorCode == "reconciliation-unavailable")
    }

    // Production break: a submitted live transaction is reconciled against the current simulated backend after Debug opt-out.
    @Test("Submitted transactions refuse reconciliation through a different backend")
    func submittedTransactionRejectsDifferentBackend() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        try repository.save(transaction: MutationTransaction(
            id: "live-interrupted-archive",
            operation: .archive,
            items: [MutationItem(assetID: "asset", state: .submitted)],
            targetAlbumID: "target",
            submittedAt: Date(timeIntervalSince1970: 100),
            backendMode: .live
        ))
        let simulatedMutator = SimulatedPhotoLibraryMutator(
            assetIDs: ["asset"],
            albums: [PhotoAlbumDescriptor(id: "target", title: "目标", assetCount: 0)]
        )
        _ = await simulatedMutator.addAssets(withIDs: ["asset"], toAlbumID: "target")
        let coordinator = MutationCoordinator(repository: repository, mutator: simulatedMutator)

        do {
            try await coordinator.reconcileInterruptedTransactions()
            Issue.record("Expected backend mismatch to leave the transaction submitted")
        } catch let error as MutationCoordinatorError {
            #expect(error == .backendMismatch(
                transactionID: "live-interrupted-archive",
                expected: .live,
                actual: .simulated
            ))
        }

        #expect(try repository.transactions().first?.items == [
            MutationItem(assetID: "asset", state: .submitted)
        ])
    }

    // Production break: a submitted archive already present in its exact target is marked failed and offered for resubmission.
    @Test("Submitted archive membership reconciles success without another add request")
    func submittedArchiveMembershipReconcilesWithoutResubmission() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let mutator = SimulatedPhotoLibraryMutator(
            assetIDs: ["asset"],
            albums: [PhotoAlbumDescriptor(id: "target", title: "目标", assetCount: 0)]
        )
        _ = await mutator.addAssets(withIDs: ["asset"], toAlbumID: "target")
        let submittedBeforeRecovery = await mutator.submittedAssetIDs
        let decision = PhotoDecision(
            assetID: "asset",
            kind: .archive,
            targetAlbumID: "target",
            isSubmitted: true
        )
        try repository.save(transaction: MutationTransaction(
            id: "interrupted-archive",
            operation: .archive,
            items: [MutationItem(assetID: "asset", state: .submitted)],
            targetAlbumID: "target",
            submittedAt: Date(timeIntervalSince1970: 100),
            archiveDecision: decision,
            recentAlbumIDs: ["target"],
            backendMode: .simulated
        ))
        let coordinator = MutationCoordinator(repository: repository, mutator: mutator)

        try await coordinator.reconcileInterruptedTransactions()

        #expect(try repository.transactions().first?.items == [
            MutationItem(assetID: "asset", state: .succeeded)
        ])
        #expect(await mutator.submittedAssetIDs == submittedBeforeRecovery)
    }

    // Production break: post-mutation relaunch recovery cannot atomically apply the archive decision/task/recent state exactly once.
    @Test("Relaunch recovery applies interrupted archive state exactly once")
    func relaunchRecoveryAppliesArchiveStateOnce() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let task = archiveTask(assetIDs: ["asset", "next"])
        try repository.save(task: task)
        _ = try TaskLifecycleController(repository: repository).start(taskID: task.id)
        let prior = PhotoDecision(assetID: "asset", kind: .keep, taskID: task.id)
        try repository.save(decision: prior)
        var settings = WorkflowSettings.defaults
        settings.debugRealMutationEnabled = false
        try repository.save(settings: settings)
        let mutator = SimulatedPhotoLibraryMutator(
            assetIDs: ["asset", "next"],
            albums: [PhotoAlbumDescriptor(id: "target", title: "目标", assetCount: 0)]
        )
        _ = await mutator.addAssets(withIDs: ["asset"], toAlbumID: "target")
        let submittedBeforeRecovery = await mutator.submittedAssetIDs
        let decision = PhotoDecision(
            assetID: "asset",
            kind: .archive,
            estimatedBytes: 9_000,
            targetAlbumID: "target",
            taskID: task.id,
            isSubmitted: true
        )
        try repository.save(transaction: MutationTransaction(
            id: "post-mutation",
            operation: .archive,
            items: [MutationItem(assetID: "asset", state: .submitted)],
            targetAlbumID: "target",
            submittedAt: Date(timeIntervalSince1970: 100),
            archiveDecision: decision,
            recentAlbumIDs: ["target"],
            backendMode: .simulated
        ))
        let model = AppModel(
            library: MutationReader(),
            repository: repository,
            mutator: mutator,
            initialScan: .idle
        )

        await model.reconcileInterruptedMutations()
        await model.reconcileInterruptedMutations()

        #expect(try repository.decision(for: "asset") == decision)
        #expect(try repository.tasks().first?.currentAssetIndex == 1)
        #expect(try repository.tasks().first?.ownedAssetIDs == ["next"])
        #expect(try repository.settings().recentAlbumIDs == ["target"])
        #expect(try !repository.settings().debugRealMutationEnabled)
        #expect(await mutator.submittedAssetIDs == submittedBeforeRecovery)
    }

    // Production break: AppModel obtains readable authorization but leaves submitted mutations unreconciled unless a view calls recovery.
    @Test("Initial authorized refresh reconciles submitted archive state")
    func authorizedRefreshReconcilesSubmittedArchive() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let mutator = SimulatedPhotoLibraryMutator(
            assetIDs: ["asset"],
            albums: [PhotoAlbumDescriptor(id: "target", title: "目标", assetCount: 0)]
        )
        _ = await mutator.addAssets(withIDs: ["asset"], toAlbumID: "target")
        try repository.save(transaction: MutationTransaction(
            id: "startup-archive",
            operation: .archive,
            items: [MutationItem(assetID: "asset", state: .submitted)],
            targetAlbumID: "target",
            submittedAt: Date(timeIntervalSince1970: 100),
            backendMode: .simulated
        ))
        let model = AppModel(
            library: MutationReader(),
            repository: repository,
            mutator: mutator,
            initialScan: .idle
        )

        await model.refreshAuthorization()

        #expect(try repository.transactions().first?.items == [
            MutationItem(assetID: "asset", state: .succeeded)
        ])
    }

    // Production break: readable authorization exposes the stale first task item while startup archive recovery is suspended.
    @Test("Initial authorized refresh stays unreadable until archive recovery finishes")
    func authorizedRefreshWaitsForArchiveRecovery() async throws {
        try await assertAuthorizationPublicationWaitsForRecovery(using: .refresh)
    }

    // Production break: granting access exposes the stale first task item while startup archive recovery is suspended.
    @Test("Granted authorization stays unreadable until archive recovery finishes")
    func grantedAuthorizationWaitsForArchiveRecovery() async throws {
        try await assertAuthorizationPublicationWaitsForRecovery(using: .request)
    }

    // Production break: an older readable refresh can overwrite a newer denied result after recovery resumes.
    @Test("Newer denied refresh supersedes suspended readable recovery")
    func newerDeniedRefreshSupersedesReadableRecovery() async throws {
        let repository = try repositoryWithSubmittedArchive(transactionID: "superseded-readable-refresh")
        let reader = SequencedAuthorizationReader(
            authorizationStatuses: [.authorized, .denied],
            requestedAuthorizations: []
        )
        let mutator = FirstSuspendedRecoveryMutator()
        let model = AppModel(
            library: reader,
            repository: repository,
            mutator: mutator,
            initialScan: .idle
        )

        let olderRefresh = Task { @MainActor in
            await model.refreshAuthorization()
        }
        await mutator.waitUntilFirstBackendModeRequested()

        await model.refreshAuthorization()

        #expect(model.hasLoadedAuthorization)
        #expect(model.authorization == .denied)
        #expect(model.scan.phase == .idle)

        await mutator.resumeFirstBackendMode()
        await olderRefresh.value

        #expect(model.hasLoadedAuthorization)
        #expect(model.authorization == .denied)
        #expect(model.scan.phase == .idle)
    }

    // Production break: a newer readable request returns early while an older readable recovery is suspended.
    @Test("Newer limited request supersedes suspended authorized refresh")
    func newerLimitedRequestSupersedesAuthorizedRefresh() async throws {
        let repository = try repositoryWithSubmittedArchive(transactionID: "superseded-authorized-refresh")
        let reader = SequencedAuthorizationReader(
            authorizationStatuses: [.authorized],
            requestedAuthorizations: [.limited]
        )
        let mutator = FirstSuspendedRecoveryMutator()
        let model = AppModel(
            library: reader,
            repository: repository,
            mutator: mutator,
            initialScan: .idle
        )

        let olderRefresh = Task { @MainActor in
            await model.refreshAuthorization()
        }
        await mutator.waitUntilFirstBackendModeRequested()

        await model.requestPhotoAccess()

        #expect(model.hasLoadedAuthorization)
        #expect(model.authorization == .limited)
        #expect(model.scan.isScanning)

        await mutator.resumeFirstBackendMode()
        await olderRefresh.value

        #expect(model.hasLoadedAuthorization)
        #expect(model.authorization == .limited)
        #expect(model.scan.isScanning)
    }

    // Production break: retrying archive after add failure creates a second system album instead of reusing the journaled target.
    @Test("Created album is reused when its first asset addition fails")
    func createdAlbumIsReusedAfterAddFailure() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let mutator = SimulatedPhotoLibraryMutator(
            assetIDs: ["asset"],
            configuredOutcomes: ["asset": .failed]
        )
        let flow = AlbumSelectionFlow(
            assetID: "asset",
            taskID: nil,
            estimatedBytes: 0,
            repository: repository,
            mutator: mutator
        )
        await flow.loadAlbums()

        await flow.createAndArchive(named: "旅行")
        let createdAlbumID = try #require(await mutator.listAlbums().first?.id)
        await mutator.setOutcome(.succeeded, for: "asset")
        await flow.createAndArchive(named: "旅行")

        #expect(await mutator.createAlbumRequests == ["旅行"])
        #expect(try repository.decision(for: "asset")?.targetAlbumID == createdAlbumID)
        #expect(try repository.transactions().filter { $0.operation == .createAlbum }.count == 1)
    }

    // Production break: relaunch after album creation but before result persistence issues another create request.
    @Test("Submitted album creation reuses the uniquely created post-snapshot album")
    func submittedAlbumCreationReusesRecoveredAlbum() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        try repository.save(transaction: MutationTransaction(
            id: "interrupted-create",
            operation: .createAlbum,
            items: [MutationItem(assetID: "asset", state: .submitted)],
            createdAt: Date(timeIntervalSince1970: 100),
            submittedAt: Date(timeIntervalSince1970: 101),
            albumTitle: "旅行",
            albumIDsBeforeCreation: ["existing"],
            backendMode: .simulated
        ))
        let mutator = SimulatedPhotoLibraryMutator(
            assetIDs: ["asset"],
            albums: [
                PhotoAlbumDescriptor(id: "existing", title: "已有", assetCount: 0),
                PhotoAlbumDescriptor(id: "recovered", title: "旅行", assetCount: 0)
            ]
        )
        let flow = AlbumSelectionFlow(
            assetID: "asset",
            taskID: nil,
            estimatedBytes: 0,
            repository: repository,
            mutator: mutator
        )
        await flow.loadAlbums()

        await flow.createAndArchive(named: "旅行")

        #expect(await mutator.createAlbumRequests.isEmpty)
        #expect(try repository.decision(for: "asset")?.targetAlbumID == "recovered")
        let creation = try #require(repository.transactions().first(where: { $0.operation == .createAlbum }))
        #expect(creation.targetAlbumID == "recovered")
        #expect(creation.items == [MutationItem(assetID: "asset", state: .succeeded)])
    }

    // Production break: one empty album-list read marks a submitted creation failed, so retry creates the same system album again.
    @Test("Delayed album visibility keeps one creation submitted until unique recovery")
    func delayedAlbumVisibilityDoesNotDuplicateCreation() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let mutator = DelayedAlbumVisibilityMutator()
        let coordinator = MutationCoordinator(repository: repository, mutator: mutator)

        let firstResult = try await coordinator.createAlbum(named: "旅行", forAssetID: "asset")
        #expect(firstResult == nil)
        var creation = try #require(repository.transactions().first)
        #expect(creation.items == [MutationItem(assetID: "asset", state: .submitted)])
        #expect(await mutator.createAlbumRequests == ["旅行"])

        let repeatedResult = try await coordinator.createAlbum(named: "旅行", forAssetID: "asset")
        #expect(repeatedResult == nil)
        try await coordinator.reconcileInterruptedTransactions()
        let unresolvedTransactions = try repository.transactions()
        creation = try #require(unresolvedTransactions.first)
        #expect(creation.items == [MutationItem(assetID: "asset", state: .submitted)])
        #expect(unresolvedTransactions.count == 1)
        #expect(await mutator.createAlbumRequests == ["旅行"])

        await mutator.revealCreatedAlbum()
        try await coordinator.reconcileInterruptedTransactions()

        creation = try #require(repository.transactions().first)
        #expect(creation.items == [MutationItem(assetID: "asset", state: .succeeded)])
        #expect(creation.targetAlbumID == "delayed-created")
        #expect(await mutator.createAlbumRequests == ["旅行"])
    }

    // Production break: choosing one of multiple post-snapshot title matches can bind recovery to an arbitrary system album.
    @Test("Multiple matching created albums remain submitted without another request")
    func multipleMatchingAlbumsFailClosed() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        try repository.save(transaction: MutationTransaction(
            id: "ambiguous-create",
            operation: .createAlbum,
            items: [MutationItem(assetID: "asset", state: .submitted)],
            createdAt: Date(timeIntervalSince1970: 100),
            submittedAt: Date(timeIntervalSince1970: 101),
            albumTitle: "旅行",
            albumIDsBeforeCreation: ["existing"],
            backendMode: .simulated
        ))
        let mutator = SimulatedPhotoLibraryMutator(
            assetIDs: ["asset"],
            albums: [
                PhotoAlbumDescriptor(id: "existing", title: "已有", assetCount: 0),
                PhotoAlbumDescriptor(id: "match-1", title: "旅行", assetCount: 0),
                PhotoAlbumDescriptor(id: "match-2", title: "旅行", assetCount: 0)
            ]
        )
        let coordinator = MutationCoordinator(repository: repository, mutator: mutator)

        try await coordinator.reconcileInterruptedTransactions()

        let transactions = try repository.transactions()
        #expect(transactions.count == 1)
        #expect(transactions.first?.items == [
            MutationItem(assetID: "asset", state: .submitted)
        ])
        #expect(transactions.first?.targetAlbumID == nil)
        #expect(transactions.first?.completedAt == nil)
        #expect(await mutator.createAlbumRequests.isEmpty)
    }

    // Production break: adding recovery metadata makes previously persisted mutation JSON undecodable.
    @Test("Legacy mutation journals decode with absent recovery metadata")
    func legacyMutationJournalDecodes() throws {
        let payload = Data(#"{"id":"legacy","operation":"archive","items":[{"assetID":"asset","state":"submitted"}],"targetAlbumID":"target","createdAt":0}"#.utf8)

        let transaction = try JSONDecoder().decode(MutationTransaction.self, from: payload)

        #expect(transaction.albumTitle == nil)
        #expect(transaction.albumIDsBeforeCreation == nil)
        #expect(transaction.archiveDecision == nil)
        #expect(transaction.recentAlbumIDs == nil)
        #expect(transaction.backendMode == nil)
    }

    // Production break: submitting the same asset and target as a legacy interrupted archive creates and executes a duplicate transaction.
    @Test("Legacy submitted archive fails closed before duplicate submission")
    func legacySubmittedArchiveFailsClosed() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let payload = Data(#"{"id":"legacy","operation":"archive","items":[{"assetID":"asset","state":"submitted"}],"targetAlbumID":"target","createdAt":0}"#.utf8)
        let legacyTransaction = try JSONDecoder().decode(MutationTransaction.self, from: payload)
        try repository.save(transaction: legacyTransaction)
        let mutator = SimulatedPhotoLibraryMutator(
            assetIDs: ["asset"],
            albums: [PhotoAlbumDescriptor(id: "target", title: "目标", assetCount: 0)]
        )
        let coordinator = MutationCoordinator(repository: repository, mutator: mutator)
        let decision = PhotoDecision(
            assetID: "asset",
            kind: .archive,
            targetAlbumID: "target",
            isSubmitted: true
        )

        do {
            _ = try await coordinator.submitArchive(
                decision: decision,
                recentAlbumIDs: ["target"]
            )
            Issue.record("Expected incomplete legacy recovery metadata to block duplicate archive submission")
        } catch let error as MutationCoordinatorError {
            #expect(error == .incompleteLegacyArchiveRecovery("legacy"))
        }

        let transactions = try repository.transactions()
        #expect(transactions.count == 1)
        #expect(transactions.first?.items == [
            MutationItem(assetID: "asset", state: .submitted)
        ])
        #expect(await mutator.submittedAssetIDs.isEmpty)
    }

    private func archiveTask(assetIDs: [String]) -> CleanupTask {
        CleanupTask(
            id: "archive-recovery-task",
            type: .screenshots,
            title: "归档恢复",
            reason: "测试中断恢复",
            assetIDs: assetIDs,
            estimatedBytes: 9_000,
            estimatedMinutes: 1,
            risk: .low,
            confidence: 1,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func repositoryWithSubmittedArchive(
        transactionID: String
    ) throws -> SwiftDataTaskRepository {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        try repository.save(transaction: MutationTransaction(
            id: transactionID,
            operation: .archive,
            items: [MutationItem(assetID: "asset", state: .submitted)],
            targetAlbumID: "target",
            submittedAt: Date(timeIntervalSince1970: 100),
            backendMode: .simulated
        ))
        return repository
    }

    private func assertAuthorizationPublicationWaitsForRecovery(
        using loadPath: AuthorizationLoadPath
    ) async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let task = archiveTask(assetIDs: ["asset", "next"])
        try repository.save(task: task)
        _ = try TaskLifecycleController(repository: repository).start(taskID: task.id)
        let archiveDecision = PhotoDecision(
            assetID: "asset",
            kind: .archive,
            targetAlbumID: "target",
            taskID: task.id,
            isSubmitted: true
        )
        try repository.save(transaction: MutationTransaction(
            id: "startup-gated-archive",
            operation: .archive,
            items: [MutationItem(assetID: "asset", state: .submitted)],
            targetAlbumID: "target",
            submittedAt: Date(timeIntervalSince1970: 100),
            archiveDecision: archiveDecision,
            recentAlbumIDs: ["target"],
            backendMode: .simulated
        ))
        let mutator = SuspendedRecoveryMutator()
        let model = AppModel(
            library: MutationReader(),
            repository: repository,
            mutator: mutator,
            initialScan: .idle
        )

        let authorizationTask = Task { @MainActor in
            switch loadPath {
            case .refresh:
                await model.refreshAuthorization()
            case .request:
                await model.requestPhotoAccess()
            }
        }
        await mutator.waitUntilBackendModeRequested()

        #expect(!model.hasLoadedAuthorization)
        #expect(model.authorization == .notDetermined)
        await model.prepareSingleDecision(taskID: task.id)
        #expect(model.decisionFlow == nil)

        await mutator.resumeBackendMode()
        await authorizationTask.value

        #expect(model.hasLoadedAuthorization)
        #expect(model.authorization == .authorized)
        await model.prepareSingleDecision(taskID: task.id)
        #expect(model.decisionFlow?.currentDescriptor?.id == "next")
    }
}

private enum AuthorizationLoadPath: Sendable {
    case refresh
    case request
}

@Suite("Mutation backend composition")
struct MutationCompositionTests {
    @Test("Debug and UI tests are simulated by default while Release is live")
    func backendMatrix() async {
        let debug = MutationComposition.make(
            build: .debug,
            isUITesting: false,
            debugRealMutationEnabled: false
        )
        let uiTest = MutationComposition.make(
            build: .debug,
            isUITesting: true,
            debugRealMutationEnabled: true
        )
        let optedInDebug = MutationComposition.make(
            build: .debug,
            isUITesting: false,
            debugRealMutationEnabled: true
        )
        let release = MutationComposition.make(
            build: .release,
            isUITesting: false,
            debugRealMutationEnabled: false
        )

        #expect(await debug.backendMode == .simulated)
        #expect(await uiTest.backendMode == .simulated)
        #expect(await optedInDebug.backendMode == .live)
        #expect(await release.backendMode == .live)
        #expect(MutationComposition.modeLabel(for: .simulated).contains("不会修改"))
        #expect(MutationComposition.modeLabel(for: .live).contains("真实"))
    }

    @Test("Debug opt-in persists and updates the visible backend mode")
    @MainActor
    func debugOptIn() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let model = AppModel(library: MutationReader(), repository: repository)
        await model.refreshMutationMode()

        #expect(!model.debugRealMutationEnabled)
        #expect(model.mutationBackendMode == .simulated)

        model.updateDebugRealMutation(true)
        await model.refreshMutationMode()

        #expect(try repository.settings().debugRealMutationEnabled)
        #expect(model.mutationBackendMode == .live)
        #expect(model.mutationModeLabel.contains("真实"))
    }
}

private actor MutationReader: PhotoLibraryReading {
    func authorizationStatus() -> PhotoAuthorization { .authorized }
    func requestAuthorization() -> PhotoAuthorization { .authorized }
    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> {
        AsyncStream { $0.finish() }
    }
}

private actor SequencedAuthorizationReader: PhotoLibraryReading {
    private var authorizationStatuses: [PhotoAuthorization]
    private var requestedAuthorizations: [PhotoAuthorization]

    init(
        authorizationStatuses: [PhotoAuthorization],
        requestedAuthorizations: [PhotoAuthorization]
    ) {
        self.authorizationStatuses = authorizationStatuses
        self.requestedAuthorizations = requestedAuthorizations
    }

    func authorizationStatus() -> PhotoAuthorization {
        authorizationStatuses.removeFirst()
    }

    func requestAuthorization() -> PhotoAuthorization {
        requestedAuthorizations.removeFirst()
    }

    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> {
        AsyncStream { $0.finish() }
    }
}

private actor FirstSuspendedRecoveryMutator: PhotoLibraryMutating {
    private var backendModeRequestCount = 0
    private var firstBackendModeContinuation: CheckedContinuation<MutationBackendMode, Never>?
    private var firstRequestWaiters: [CheckedContinuation<Void, Never>] = []

    var backendMode: MutationBackendMode {
        get async {
            backendModeRequestCount += 1
            guard backendModeRequestCount == 1 else { return .simulated }
            let waiters = firstRequestWaiters
            firstRequestWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            return await withCheckedContinuation { continuation in
                firstBackendModeContinuation = continuation
            }
        }
    }

    func waitUntilFirstBackendModeRequested() async {
        guard backendModeRequestCount == 0 else { return }
        await withCheckedContinuation { continuation in
            firstRequestWaiters.append(continuation)
        }
    }

    func resumeFirstBackendMode() {
        let continuation = firstBackendModeContinuation
        firstBackendModeContinuation = nil
        continuation?.resume(returning: .simulated)
    }

    func availableAssetIDs(for requestedIDs: [String]) -> Set<String> {
        Set(requestedIDs)
    }

    func listAlbums() -> [PhotoAlbumDescriptor] {
        [PhotoAlbumDescriptor(id: "target", title: "目标", assetCount: 1)]
    }

    func createAlbum(named title: String) -> PhotoAlbumDescriptor? { nil }

    func archivedAssetIDs(for requestedIDs: [String], inAlbumID albumID: String) -> Set<String> {
        guard albumID == "target" else { return [] }
        return Set(requestedIDs).intersection(["asset"])
    }

    func addAssets(withIDs assetIDs: [String], toAlbumID albumID: String) -> PhotoMutationBatch {
        PhotoMutationBatch(
            operation: .archive,
            items: assetIDs.map { MutationItem(assetID: $0, state: .failed) },
            targetAlbumID: albumID
        )
    }

    func deleteAssets(withIDs assetIDs: [String]) -> PhotoMutationBatch {
        PhotoMutationBatch(
            operation: .delete,
            items: assetIDs.map { MutationItem(assetID: $0, state: .failed) },
            targetAlbumID: nil
        )
    }
}

private actor SuspendedRecoveryMutator: PhotoLibraryMutating {
    private var backendModeContinuation: CheckedContinuation<MutationBackendMode, Never>?
    private var backendModeWasRequested = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []

    var backendMode: MutationBackendMode {
        get async {
            backendModeWasRequested = true
            let waiters = requestWaiters
            requestWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            return await withCheckedContinuation { continuation in
                backendModeContinuation = continuation
            }
        }
    }

    func waitUntilBackendModeRequested() async {
        guard !backendModeWasRequested else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func resumeBackendMode() {
        let continuation = backendModeContinuation
        backendModeContinuation = nil
        continuation?.resume(returning: .simulated)
    }

    func availableAssetIDs(for requestedIDs: [String]) -> Set<String> {
        Set(requestedIDs)
    }

    func listAlbums() -> [PhotoAlbumDescriptor] {
        [PhotoAlbumDescriptor(id: "target", title: "目标", assetCount: 1)]
    }

    func createAlbum(named title: String) -> PhotoAlbumDescriptor? { nil }

    func archivedAssetIDs(for requestedIDs: [String], inAlbumID albumID: String) -> Set<String> {
        guard albumID == "target" else { return [] }
        return Set(requestedIDs).intersection(["asset"])
    }

    func addAssets(withIDs assetIDs: [String], toAlbumID albumID: String) -> PhotoMutationBatch {
        PhotoMutationBatch(
            operation: .archive,
            items: assetIDs.map { MutationItem(assetID: $0, state: .failed) },
            targetAlbumID: albumID
        )
    }

    func deleteAssets(withIDs assetIDs: [String]) -> PhotoMutationBatch {
        PhotoMutationBatch(
            operation: .delete,
            items: assetIDs.map { MutationItem(assetID: $0, state: .failed) },
            targetAlbumID: nil
        )
    }
}

private actor DelayedAlbumVisibilityMutator: PhotoLibraryMutating {
    let backendMode = MutationBackendMode.simulated
    private let existingAlbum = PhotoAlbumDescriptor(id: "existing", title: "已有", assetCount: 0)
    private let createdAlbum = PhotoAlbumDescriptor(id: "delayed-created", title: "旅行", assetCount: 0)
    private var hasCommittedCreation = false
    private var isCreatedAlbumVisible = false
    private(set) var createAlbumRequests: [String] = []

    func availableAssetIDs(for requestedIDs: [String]) -> Set<String> {
        Set(requestedIDs)
    }

    func listAlbums() -> [PhotoAlbumDescriptor] {
        isCreatedAlbumVisible ? [existingAlbum, createdAlbum] : [existingAlbum]
    }

    func createAlbum(named title: String) -> PhotoAlbumDescriptor? {
        createAlbumRequests.append(title)
        hasCommittedCreation = true
        return nil
    }

    func revealCreatedAlbum() {
        guard hasCommittedCreation else { return }
        isCreatedAlbumVisible = true
    }

    func archivedAssetIDs(for requestedIDs: [String], inAlbumID albumID: String) -> Set<String> {
        []
    }

    func addAssets(withIDs assetIDs: [String], toAlbumID albumID: String) -> PhotoMutationBatch {
        PhotoMutationBatch(
            operation: .archive,
            items: assetIDs.map { MutationItem(assetID: $0, state: .failed) },
            targetAlbumID: albumID
        )
    }

    func deleteAssets(withIDs assetIDs: [String]) -> PhotoMutationBatch {
        PhotoMutationBatch(
            operation: .delete,
            items: assetIDs.map { MutationItem(assetID: $0, state: .failed) },
            targetAlbumID: nil
        )
    }
}
