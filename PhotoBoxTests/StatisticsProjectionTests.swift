import Foundation
import SwiftData
import Testing
@testable import PhotoBox

@Suite("Statistics projection")
struct StatisticsProjectionTests {
    @Test("Statistics fixture rescan retains its iCloud-only inventory")
    func statisticsFixtureRescanRetainsICloudOnlyInventory() async throws {
        let service = UITestPhotoLibraryService(
            authorization: .authorized,
            fixture: .statistics
        )

        let descriptors = try await service.accessibleAssetDescriptors()

        #expect(descriptors.map(\.availability) == [.iCloudOnly])
    }

    // Production break: duplicate decision rows or failed/stale mutations inflate
    // organization and deletion totals, or present estimated storage as freed space.
    @Test("Projection separates organization metrics and excludes unresolved deletion")
    func separatesOrganizationMetrics() {
        let date = Date(timeIntervalSince1970: 1_000)
        var checkpointSnapshot = LibraryScanSnapshot.idle
        checkpointSnapshot.phase = .completed
        checkpointSnapshot.localCount = 10
        checkpointSnapshot.iCloudOnlyCount = 2
        let checkpoint = ScanCheckpoint(
            id: "scan",
            stage: .completed,
            processedAssetIDs: ["new-1", "new-2"],
            discoveredCount: 12,
            snapshot: checkpointSnapshot,
            updatedAt: date
        )
        let tasks = [
            task(id: "complete-1", status: .completed, date: date),
            task(id: "queued", status: .queued, date: date),
            task(id: "complete-2", status: .completed, date: date)
        ]
        let decisions = [
            decision("archive", .archive, date: date),
            decision("protect", .protect, date: date),
            decision("later", .decideLater, date: date),
            decision("delete-success", .deleteCandidate, bytes: 4_096, date: date),
            decision("delete-success", .deleteCandidate, bytes: 4_096, date: date.addingTimeInterval(1))
        ]
        let transactions = [
            transaction("archive", operation: .archive, state: .succeeded, date: date),
            transaction("delete-success", operation: .delete, state: .succeeded, date: date),
            transaction("delete-failed", operation: .delete, state: .failed, date: date),
            transaction("delete-stale", operation: .delete, state: .stale, date: date)
        ]

        let projection = StatisticsProjection.project(
            checkpoint: checkpoint,
            tasks: tasks,
            decisions: decisions,
            transactions: transactions,
            summaries: []
        )

        #expect(projection.newItemCount == 2)
        #expect(projection.processedItemCount == 4)
        #expect(projection.successfulArchiveCount == 1)
        #expect(projection.protectionCount == 1)
        #expect(projection.deferralCount == 1)
        #expect(projection.reviewedDeletionCount == 1)
        #expect(projection.estimatedReclaimableBytes == 4_096)
        #expect(projection.completedTaskCount == 2)
        #expect(projection.totalTaskCount == 3)
        #expect(projection.hasEstimatedAvailability)
        #expect(projection.hasEstimatedReclaimableSpace)
        #expect(projection.hasRecentlyDeletedEstimate)
    }

    // Production break: a no-delete cleanup is rendered as empty or claims
    // deletion activity/space despite only keep, archive, protect, and defer work.
    @Test("Keep archive protect and defer remain meaningful without deletion")
    func noDeleteOrganizationRemainsMeaningful() {
        let date = Date(timeIntervalSince1970: 2_000)
        let decisions = [
            decision("keep", .keep, date: date),
            decision("archive", .archive, date: date),
            decision("protect", .protect, date: date),
            decision("later", .decideLater, date: date)
        ]

        let projection = StatisticsProjection.project(
            checkpoint: nil,
            tasks: [task(id: "completed", status: .completed, date: date)],
            decisions: decisions,
            transactions: [transaction("archive", operation: .archive, state: .succeeded, date: date)],
            summaries: [CleanupSummary(decisions: decisions, elapsedSeconds: 30, createdAt: date)]
        )

        #expect(projection.processedItemCount == 4)
        #expect(projection.successfulArchiveCount == 1)
        #expect(projection.protectionCount == 1)
        #expect(projection.deferralCount == 1)
        #expect(projection.reviewedDeletionCount == 0)
        #expect(projection.estimatedReclaimableBytes == 0)
        #expect(projection.hasOrganizationActivity)
    }

    // Production break: anonymous summary totals and duplicate mutation rows
    // invent an untraceable union, while failed mutation states count as work.
    @Test("Projection uses exact current identifiers and successful mutations only")
    func projectionUsesExactCurrentIdentifiersAndSuccessfulMutationsOnly() {
        let date = Date(timeIntervalSince1970: 2_500)
        var snapshot = LibraryScanSnapshot.idle
        snapshot.phase = .completed
        snapshot.localCount = 8
        let checkpoint = ScanCheckpoint(
            id: "scan",
            stage: .completed,
            processedAssetIDs: ["keep", "archive", "delete", "new-a", "new-b", "new-b"],
            discoveredCount: 6,
            snapshot: snapshot,
            updatedAt: date
        )
        let decisions = [
            decision("keep", .keep, date: date),
            decision("archive", .archive, date: date),
            decision("delete", .deleteCandidate, bytes: 4_096, date: date),
            decision("failed-delete", .deleteCandidate, bytes: 8_192, date: date),
            decision("later", .decideLater, date: date),
            decision("protect", .protect, date: date),
            decision("keep", .keep, date: date.addingTimeInterval(1))
        ]
        let transactions = [
            transaction("archive", operation: .archive, state: .succeeded, date: date),
            transaction("archive", operation: .archive, state: .succeeded, date: date),
            transaction("delete", operation: .delete, state: .succeeded, date: date),
            transaction("failed-delete", operation: .delete, state: .failed, date: date),
            transaction("stale", operation: .delete, state: .stale, date: date),
            transaction("cancelled", operation: .delete, state: .cancelled, date: date),
            transaction("pending", operation: .delete, state: .pending, date: date)
        ]
        let projection = StatisticsProjection.project(
            checkpoint: checkpoint,
            tasks: [
                task(id: "same", status: .queued, date: date),
                task(id: "same", status: .completed, date: date.addingTimeInterval(1))
            ],
            decisions: decisions,
            transactions: transactions,
            summaries: []
        )

        #expect(projection.newItemCount == 2)
        #expect(projection.processedItemCount == 5)
        #expect(projection.successfulArchiveCount == 1)
        #expect(projection.protectionCount == 1)
        #expect(projection.deferralCount == 1)
        #expect(projection.reviewedDeletionCount == 1)
        #expect(projection.estimatedReclaimableBytes == 4_096)
        #expect(projection.completedTaskCount == 1)
        #expect(projection.totalTaskCount == 1)
    }

    // Production break: valid summary-only history is displayed as zero metrics,
    // or duplicate summary rows are counted twice.
    @Test("Summary-only history contributes de-duplicated decision metrics and estimated space")
    func summaryOnlyHistoryContributesDeduplicatedAggregateMetrics() {
        let date = Date(timeIntervalSince1970: 2_600)
        let summary = CleanupSummary(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            keptCount: 1,
            deleteCandidateCount: 2,
            archivedCount: 3,
            protectedCount: 4,
            deferredCount: 5,
            estimatedReclaimableBytes: 6_000,
            elapsedSeconds: nil,
            createdAt: date
        )

        let projection = StatisticsProjection.project(
            checkpoint: nil,
            tasks: [],
            decisions: [],
            transactions: [],
            summaries: [summary, summary]
        )

        #expect(projection.newItemCount == 0)
        #expect(projection.processedItemCount == 15)
        #expect(projection.successfulArchiveCount == 0)
        #expect(projection.protectionCount == 4)
        #expect(projection.deferralCount == 5)
        #expect(projection.reviewedDeletionCount == 0)
        #expect(projection.estimatedReclaimableBytes == 6_000)
        #expect(projection.hasEstimatedReclaimableSpace)
    }

    // Production break: completed summary rows overlap their detailed source
    // records and numeric maximums inflate the current detailed history.
    @Test("Detailed history owns overlapping summary metrics without inflation")
    func detailedHistoryOwnsOverlappingSummaryMetricsWithoutInflation() {
        let date = Date(timeIntervalSince1970: 2_625)
        let projection = StatisticsProjection.project(
            checkpoint: nil,
            tasks: [],
            decisions: [
                decision("keep", .keep, date: date),
                decision("archive", .archive, date: date),
                decision("delete", .deleteCandidate, bytes: 1_024, date: date)
            ],
            transactions: [
                transaction("archive", operation: .archive, state: .succeeded, date: date),
                transaction("delete", operation: .delete, state: .succeeded, date: date)
            ],
            summaries: [CleanupSummary(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                keptCount: 9,
                deleteCandidateCount: 8,
                archivedCount: 7,
                protectedCount: 6,
                deferredCount: 5,
                estimatedReclaimableBytes: 4_096,
                elapsedSeconds: nil,
                createdAt: date
            )]
        )

        #expect(projection.processedItemCount == 3)
        #expect(projection.successfulArchiveCount == 1)
        #expect(projection.protectionCount == 0)
        #expect(projection.deferralCount == 0)
        #expect(projection.reviewedDeletionCount == 1)
        #expect(projection.estimatedReclaimableBytes == 1_024)
    }

    // Production break: rescan treats every pre-existing baseline identifier as
    // newly discovered, while a genuinely new item with a prior decision vanishes.
    @Test("New items are measured against the initial completed scan baseline")
    func newItemsAreMeasuredAgainstInitialCompletedScanBaseline() {
        let date = Date(timeIntervalSince1970: 2_650)
        let checkpoint = ScanCheckpoint(
            id: "rescan",
            stage: .completed,
            processedAssetIDs: ["baseline", "new-with-decision", "new-unreviewed"],
            discoveredCount: 3,
            updatedAt: date
        )
        let projection = StatisticsProjection.project(
            checkpoint: checkpoint,
            baselineAssetIDs: ["baseline"],
            tasks: [],
            decisions: [decision("new-with-decision", .keep, date: date)],
            transactions: [],
            summaries: []
        )

        #expect(projection.newItemCount == 2)
    }

    // Production break: an empty local store is rendered with invented metrics
    // instead of an explicit no-history state.
    @MainActor
    @Test("Empty repository publishes no history")
    func emptyRepositoryPublishesNoHistory() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let model = StatisticsModel(repository: repository)

        await model.load()

        #expect(model.state == .noHistory)
    }

    // Production break: a repository read failure replaces prior visible metrics
    // with an unrelated empty summary.
    @MainActor
    @Test("Read failure retains the last projection")
    func readFailureRetainsLastProjection() async throws {
        let storage = try SwiftDataTaskRepository(inMemory: true)
        try storage.save(decision: decision("keep", .keep, date: .now))
        let repository = StatisticsFailingRepository(storage: storage)
        let model = StatisticsModel(repository: repository)
        await model.load()
        let prior = try #require(model.projection)

        repository.failReads = true
        await model.load()

        #expect(model.projection == prior)
        #expect(model.state.isFailure)
    }

    // Production break: an initial repository failure is presented as an empty
    // history even though no trustworthy read completed.
    @MainActor
    @Test("Initial Statistics read failure is not no history")
    func initialStatisticsReadFailureIsNotNoHistory() async throws {
        let storage = try SwiftDataTaskRepository(inMemory: true)
        let repository = StatisticsFailingRepository(storage: storage)
        repository.failReads = true
        let model = StatisticsModel(repository: repository)

        await model.load()

        #expect(model.state.isFailure)
        #expect(model.projection == nil)
    }

    // Production break: readable decision history with missing scan/summary
    // records is presented as complete instead of explicitly partial.
    @MainActor
    @Test("Missing Statistics records publish partial metrics")
    func missingStatisticsRecordsPublishPartialMetrics() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        try repository.save(decision: decision("keep", .keep, date: .now))
        let model = StatisticsModel(repository: repository)

        await model.load()

        #expect(model.state == .partial)
        #expect(model.projection?.processedItemCount == 1)
    }

    // Production break: a load that captured history before clearing publishes
    // its stale projection after the clear has committed.
    @MainActor
    @Test("A captured Statistics load cannot publish after history clearing")
    func capturedLoadCannotPublishAfterHistoryClearing() async throws {
        let storage = try SwiftDataTaskRepository(inMemory: true)
        try storage.save(decision: decision("keep", .keep, date: .now))
        let repository = StatisticsFailingRepository(storage: storage)
        let model = StatisticsModel(repository: repository)

        let loadTask = Task { await model.load() }
        while !repository.didReadStatisticsSnapshot {
            await Task.yield()
        }

        #expect(model.projection == nil)
        #expect(model.clearHistory())
        await loadTask.value

        #expect(model.state == .noHistory)
        #expect(model.projection == nil)
        #expect(try storage.decisions().isEmpty)
    }

    // Production break: a second confirmation enters while the first clear is
    // suspended and clears the repository a second time.
    @MainActor
    @Test("Overlapping history confirmations are single flight")
    func overlappingHistoryConfirmationsAreSingleFlight() async throws {
        let storage = try SwiftDataTaskRepository(inMemory: true)
        try storage.save(decision: decision("keep", .keep, date: .now))
        let repository = StatisticsFailingRepository(storage: storage)
        let mutator = StatisticsSuspendingBackendMutator()
        let model = AppModel(
            library: StatisticsCountingReader(),
            repository: repository,
            mutator: mutator,
            initialScan: .idle
        )

        let firstClear = Task { await model.clearStatisticsHistory() }
        await mutator.waitUntilBackendReadIsSuspended()

        let overlappingResult = await model.clearStatisticsHistory()
        #expect(!overlappingResult)
        #expect(repository.clearCallCount == 0)

        await mutator.resumeBackendRead()
        #expect(await firstClear.value)
        #expect(repository.clearCallCount == 1)
        #expect(try storage.decisions().isEmpty)
    }

    // Production break: SwiftData has already deleted part of local history
    // when persistence fails, and rollback does not restore the original store.
    @MainActor
    @Test("SwiftData history clear rolls back after partial deletion")
    func swiftDataHistoryClearRollsBackAfterPartialDeletion() throws {
        let repository = try SwiftDataTaskRepository(
            inMemory: true,
            clearHistoryInterruption: { throw StatisticsTestError.forced }
        )
        let date = Date(timeIntervalSince1970: 2_900)
        try repository.save(checkpoint: ScanCheckpoint(
            id: "rollback-scan",
            stage: .completed,
            processedAssetIDs: ["rollback-asset"],
            discoveredCount: 1,
            updatedAt: date
        ))
        try repository.save(task: task(id: "rollback-task", status: .completed, date: date))
        try repository.save(decision: decision("rollback-asset", .keep, date: date))
        try repository.save(summary: CleanupSummary(
            decisions: [decision("rollback-asset", .keep, date: date)],
            elapsedSeconds: 1,
            createdAt: date
        ))
        let before = try repository.serializedStateForTesting()

        #expect(throws: StatisticsTestError.self) {
            try repository.clearHistory()
        }

        #expect(try repository.serializedStateForTesting() == before)
    }

    // Production break: comparison loading resumes after history clearing and
    // republishes a flow built from a task that no longer exists.
    @MainActor
    @Test("History clear invalidates a suspended comparison load")
    func historyClearInvalidatesSuspendedComparisonLoad() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let date = Date(timeIntervalSince1970: 2_925)
        let comparisonTask = CleanupTask(
            id: "comparison-load",
            type: .similar,
            title: "对比",
            reason: "对比",
            assetIDs: ["comparison-asset"],
            estimatedBytes: 1,
            estimatedMinutes: 1,
            risk: .low,
            confidence: 1,
            createdAt: date,
            updatedAt: date
        )
        try repository.save(task: comparisonTask)
        let reader = StatisticsSuspendingReader()
        let model = AppModel(
            library: reader,
            repository: repository,
            mutator: StatisticsInventoryMutator(assetIDs: ["comparison-asset"], albums: [:]),
            initialScan: .idle
        )

        let loadTask = Task { await model.prepareComparison(taskID: comparisonTask.id) }
        await reader.waitUntilDescriptorReadIsSuspended()

        #expect(await model.clearStatisticsHistory())
        await reader.resumeDescriptorRead(with: [descriptor("comparison-asset")])
        await loadTask.value

        #expect(model.comparisonFlow == nil)
        #expect(model.comparisonTaskID == nil)
        #expect(model.comparisonLoadError == nil)
        #expect(try repository.tasks().isEmpty)
    }

    // Production break: a single-decision descriptor load resumes after clear
    // and republishes a flow for a deleted task.
    @MainActor
    @Test("History clear invalidates a suspended single-decision load")
    func historyClearInvalidatesSuspendedSingleDecisionLoad() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let date = Date(timeIntervalSince1970: 2_950)
        let decisionTask = CleanupTask(
            id: "decision-load",
            type: .screenshots,
            title: "单张决定",
            reason: "单张决定",
            assetIDs: ["decision-asset"],
            estimatedBytes: 1,
            estimatedMinutes: 1,
            risk: .low,
            confidence: 1,
            createdAt: date,
            updatedAt: date
        )
        try repository.save(task: decisionTask)
        let reader = StatisticsSuspendingReader()
        let model = AppModel(
            library: reader,
            repository: repository,
            mutator: StatisticsInventoryMutator(assetIDs: ["decision-asset"], albums: [:]),
            initialScan: .idle
        )

        let loadTask = Task { await model.prepareSingleDecision(taskID: decisionTask.id) }
        await reader.waitUntilDescriptorReadIsSuspended()

        #expect(await model.clearStatisticsHistory())
        await reader.resumeDescriptorRead(with: [descriptor("decision-asset")])
        await loadTask.value

        #expect(model.decisionFlow == nil)
        #expect(model.decisionTaskID == nil)
        #expect(model.decisionLoadError == nil)
        #expect(try repository.tasks().isEmpty)
    }

    // Production break: an undecodable newest scan checkpoint is converted to
    // nil and shown as an empty history instead of a recoverable read failure.
    @MainActor
    @Test("Corrupt checkpoint never becomes no history")
    func corruptCheckpointNeverBecomesNoHistory() async throws {
        let schema = Schema(versionedSchema: PhotoBoxSchemaV1.self)
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let repository = SwiftDataTaskRepository(container: container)
        let checkpoint = ScanCheckpoint(
            id: "corrupt-statistics-checkpoint",
            stage: .completed,
            processedAssetIDs: ["asset"],
            discoveredCount: 1,
            updatedAt: .now
        )
        try repository.save(checkpoint: checkpoint)
        let identifier = checkpoint.id
        let record = try #require(container.mainContext.fetch(FetchDescriptor<PersistedScanCheckpoint>(
            predicate: #Predicate { $0.identifier == identifier }
        )).first)
        record.payload = Data([0xFF])
        try container.mainContext.save()

        let model = StatisticsModel(repository: repository)
        await model.load()

        #expect(model.state.isFailure)
        #expect(model.projection == nil)
    }

    // Production break: an undecodable task row is silently omitted and the
    // remaining store is presented as unrelated empty history.
    @MainActor
    @Test("Corrupt task never becomes no history")
    func corruptTaskNeverBecomesNoHistory() async throws {
        let schema = Schema(versionedSchema: PhotoBoxSchemaV1.self)
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let repository = SwiftDataTaskRepository(container: container)
        try repository.save(task: task(id: "corrupt-statistics-task", status: .queued, date: .now))
        let record = try #require(container.mainContext.fetch(
            FetchDescriptor<PersistedCleanupTask>()
        ).first)
        record.payload = Data([0xFF])
        try container.mainContext.save()

        let model = StatisticsModel(repository: repository)
        await model.load()

        #expect(model.state.isFailure)
        #expect(model.projection == nil)
    }

    // Production break: a decision with an unknown kind is silently omitted
    // and Statistics substitutes no history.
    @MainActor
    @Test("Corrupt decision never becomes no history")
    func corruptDecisionNeverBecomesNoHistory() async throws {
        let schema = Schema(versionedSchema: PhotoBoxSchemaV1.self)
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let repository = SwiftDataTaskRepository(container: container)
        try repository.save(decision: decision("corrupt-statistics-decision", .keep, date: .now))
        let record = try #require(container.mainContext.fetch(
            FetchDescriptor<PersistedPhotoDecision>()
        ).first)
        record.kindRawValue = "unknown-decision-kind"
        try container.mainContext.save()

        let model = StatisticsModel(repository: repository)
        await model.load()

        #expect(model.state.isFailure)
        #expect(model.projection == nil)
    }

    // Production break: an undecodable transaction journal row is silently
    // omitted and Statistics substitutes no history.
    @MainActor
    @Test("Corrupt transaction never becomes no history")
    func corruptTransactionNeverBecomesNoHistory() async throws {
        let schema = Schema(versionedSchema: PhotoBoxSchemaV1.self)
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let repository = SwiftDataTaskRepository(container: container)
        try repository.save(transaction: transaction(
            "corrupt-statistics-transaction",
            operation: .delete,
            state: .succeeded,
            date: .now
        ))
        let record = try #require(container.mainContext.fetch(
            FetchDescriptor<PersistedMutationTransaction>()
        ).first)
        record.payload = Data([0xFF])
        try container.mainContext.save()

        let model = StatisticsModel(repository: repository)
        await model.load()

        #expect(model.state.isFailure)
        #expect(model.projection == nil)
    }

    // Production break: an invalid aggregate summary is silently omitted and
    // Statistics substitutes no history.
    @MainActor
    @Test("Corrupt summary never becomes no history")
    func corruptSummaryNeverBecomesNoHistory() async throws {
        let schema = Schema(versionedSchema: PhotoBoxSchemaV1.self)
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let repository = SwiftDataTaskRepository(container: container)
        try repository.save(summary: CleanupSummary(
            decisions: [decision("corrupt-statistics-summary", .keep, date: .now)],
            elapsedSeconds: 1,
            createdAt: .now
        ))
        let record = try #require(container.mainContext.fetch(
            FetchDescriptor<PersistedCleanupSummary>()
        ).first)
        record.keptCount = -1
        try container.mainContext.save()

        let model = StatisticsModel(repository: repository)
        await model.load()

        #expect(model.state.isFailure)
        #expect(model.projection == nil)
    }

    // Production break: clear failure replaces visible metrics with a generic
    // read error, and users cannot retry the actual local clear operation.
    @MainActor
    @Test("Clear failure preserves statistics and is retryable")
    func clearFailurePreservesStatisticsAndIsRetryable() async throws {
        let storage = try SwiftDataTaskRepository(inMemory: true)
        let date = Date(timeIntervalSince1970: 2_750)
        try storage.save(decision: decision("keep", .keep, date: date))
        let repository = StatisticsFailingRepository(storage: storage)
        let statistics = StatisticsModel(repository: repository)
        await statistics.load()
        let prior = try #require(statistics.projection)

        repository.failClear = true
        #expect(!statistics.clearHistory())
        #expect(statistics.projection == prior)
        #expect(statistics.clearFailureMessage == "统计记录读取失败")
        #expect(!statistics.state.isFailure)

        repository.failClear = false
        #expect(statistics.clearHistory())
        #expect(statistics.state == .noHistory)
        #expect(statistics.clearFailureMessage == nil)
    }

    // Production break: confirmed history clearing invokes the mutator, retains
    // local records/navigation, or replaces the test mutator to hide inventory changes.
    @MainActor
    @Test("History clearing resets only local workflow state")
    func historyClearingResetsOnlyLocalWorkflowState() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let date = Date(timeIntervalSince1970: 3_000)
        let checkpoint = ScanCheckpoint(
            id: "scan",
            stage: .completed,
            processedAssetIDs: ["asset-a"],
            discoveredCount: 1,
            updatedAt: date
        )
        let cleanupTask = task(id: "task", status: .completed, date: date)
        let cleanupDecision = decision("asset-a", .keep, date: date)
        let cleanupTransaction = transaction("asset-b", operation: .delete, state: .succeeded, date: date)
        var settings = WorkflowSettings.defaults
        settings.weeklyModeEnabled = true
        settings.recentAlbumIDs = ["album"]
        try repository.save(checkpoint: checkpoint)
        try repository.save(task: cleanupTask)
        try repository.save(decision: cleanupDecision)
        try repository.save(undo: DecisionUndoEntry(
            assetID: cleanupDecision.assetID,
            previousDecision: nil,
            replacementDecision: cleanupDecision,
            taskID: cleanupTask.id,
            previousTaskIndex: nil
        ))
        try repository.save(transaction: cleanupTransaction)
        try repository.save(summary: CleanupSummary(decisions: [cleanupDecision], elapsedSeconds: 1, createdAt: date))
        try repository.save(settings: settings)

        let mutator = StatisticsInventoryMutator(
            assetIDs: ["asset-a", "asset-b"],
            albums: ["album": ["asset-a"]]
        )
        let model = AppModel(
            library: UITestPhotoLibraryService(authorization: .authorized),
            repository: repository,
            mutator: mutator,
            initialScan: .idle,
            initialActiveRoute: .weeklyInbox
        )
        let inventoryBefore = await mutator.inventory()

        #expect(await model.clearStatisticsHistory())

        #expect(try repository.latestCheckpoint() == nil)
        #expect(try repository.tasks().isEmpty)
        #expect(try repository.decisions().isEmpty)
        #expect(try repository.latestUndo() == nil)
        #expect(try repository.transactions().isEmpty)
        #expect(try repository.summaries().isEmpty)
        #expect(try repository.settings() == .defaults)
        #expect(model.activeRoute == nil)
        #expect(model.taskNavigationPath.isEmpty)
        #expect(await mutator.inventory() == inventoryBefore)
        #expect(await mutator.mutationCallCount() == 0)
    }

    // Production break: clear resets the Debug toggle but leaves an injected
    // live mutator behind it, or replaces a Release-injected live mutator.
    @MainActor
    @Test("History clear resets Debug live opt-in while preserving Release live injection")
    func historyClearResetsDebugLiveOptInWhilePreservingReleaseLiveInjection() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        var settings = WorkflowSettings.defaults
        settings.debugRealMutationEnabled = true
        try repository.save(settings: settings)
        let model = AppModel(
            library: UITestPhotoLibraryService(authorization: .authorized),
            repository: repository,
            mutator: LivePhotoLibraryMutator(),
            initialScan: .idle
        )

        await model.refreshMutationMode()
        #expect(model.mutationBackendMode == .live)
        #expect(await model.clearStatisticsHistory())
        await model.refreshMutationMode()

        #expect(!model.debugRealMutationEnabled)
        #expect(try !repository.settings().debugRealMutationEnabled)
        #if DEBUG
        #expect(model.mutationBackendMode == .simulated)
        #else
        #expect(model.mutationBackendMode == .live)
        #endif
    }

    // Production break: inventory signals omit album titles and createAlbum calls,
    // letting a clear-path mutation escape the unchanged-inventory assertion.
    @Test("Simulated inventory fingerprints include album titles and every mutation call")
    func simulatedInventoryFingerprintIncludesAlbumTitlesAndEveryMutationCall() async {
        let mutator = SimulatedPhotoLibraryMutator(
            assetIDs: ["asset"],
            albums: [PhotoAlbumDescriptor(id: "album", title: "原始相册", assetCount: 0)]
        )

        #expect(await mutator.inventoryFingerprint() == "assets=asset|albums=album:原始相册[]|mutationCalls=0")
        _ = await mutator.createAlbum(named: "")
        #expect(await mutator.inventoryFingerprint() == "assets=asset|albums=album:原始相册[]|mutationCalls=1")
    }

    // Production break: failed, cancelled, or pending archive journal rows are
    // presented as completed archive work.
    @Test("Only succeeded archive journal rows count as successful archives")
    func onlySucceededArchiveJournalRowsCountAsSuccessfulArchives() {
        let date = Date(timeIntervalSince1970: 3_100)
        let projection = StatisticsProjection.project(
            checkpoint: nil,
            tasks: [],
            decisions: [],
            transactions: [
                transaction("archive-success", operation: .archive, state: .succeeded, date: date),
                transaction("archive-failed", operation: .archive, state: .failed, date: date),
                transaction("archive-cancelled", operation: .archive, state: .cancelled, date: date),
                transaction("archive-pending", operation: .archive, state: .pending, date: date)
            ],
            summaries: []
        )

        #expect(projection.successfulArchiveCount == 1)
        #expect(projection.processedItemCount == 1)
    }

    // Production break: an older successful row for a transaction remains
    // visible after a newer failure for the same transaction identifier.
    @Test("Newest transaction record supersedes an older success with the same identifier")
    func newestTransactionRecordSupersedesOlderSuccessWithSameIdentifier() {
        let date = Date(timeIntervalSince1970: 3_150)
        let projection = StatisticsProjection.project(
            checkpoint: nil,
            tasks: [],
            decisions: [],
            transactions: [
                MutationTransaction(
                    id: "archive-retry",
                    operation: .archive,
                    items: [MutationItem(assetID: "asset", state: .succeeded)],
                    createdAt: date
                ),
                MutationTransaction(
                    id: "archive-retry",
                    operation: .archive,
                    items: [MutationItem(assetID: "asset", state: .failed)],
                    createdAt: date.addingTimeInterval(1)
                )
            ],
            summaries: []
        )

        #expect(projection.successfulArchiveCount == 0)
        #expect(projection.processedItemCount == 0)
    }

    // Production break: the Statistics rescan control bypasses the existing
    // scan boundary, clears persisted history, or replaces the injected mutator.
    @MainActor
    @Test("Full rescan invokes the scan boundary once and preserves local history")
    func fullRescanInvokesBoundaryOnceAndPreservesLocalHistory() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let date = Date(timeIntervalSince1970: 3_200)
        try repository.save(checkpoint: ScanCheckpoint(
            id: "initial",
            stage: .completed,
            processedAssetIDs: ["asset"],
            discoveredCount: 1,
            updatedAt: date
        ))
        let decision = decision("asset", .keep, date: date)
        try repository.save(decision: decision)
        let reader = StatisticsCountingReader()
        let mutator = StatisticsInventoryMutator(assetIDs: ["asset"], albums: [:])
        let model = AppModel(
            library: reader,
            repository: repository,
            mutator: mutator,
            initialScan: .idle
        )

        await model.refreshAuthorization()
        await settleScan(model)
        #expect(await reader.descriptorReadCount() == 1)
        #expect(try repository.decisions() == [decision])
        #expect(await mutator.mutationCallCount() == 0)

        model.rescan()
        await settleScan(model)

        #expect(await reader.descriptorReadCount() == 2)
        #expect(try repository.decisions() == [decision])
        #expect(await mutator.mutationCallCount() == 0)
        #expect(model.mutationBackendMode == .simulated)
        #expect(model.statistics.projection?.processedItemCount == 1)
    }

    // Production breaks caught: ScanCoordinator misclassifies CancellationError,
    // AppModel reloads a cancelled checkpoint over history, or resume restarts it.
    @MainActor
    @Test("Real coordinator cancellation preserves Statistics until resume completes")
    func realCoordinatorCancellationPreservesStatisticsUntilResumeCompletes() async throws {
        let storage = try SwiftDataTaskRepository(inMemory: true)
        let repository = StatisticsFailingRepository(storage: storage)
        let date = Date(timeIntervalSince1970: 3_300)
        var historicalScan = LibraryScanSnapshot.idle
        historicalScan.phase = .completed
        historicalScan.discoveredCount = 1
        historicalScan.processedCount = 1
        historicalScan.iCloudOnlyCount = 1
        let historicalCheckpoint = ScanCheckpoint(
            id: "statistics-cancellation-history",
            stage: .completed,
            processedAssetIDs: ["history-keep"],
            discoveredCount: 1,
            snapshot: historicalScan,
            updatedAt: date
        )
        let historicalDecision = decision("history-keep", .keep, date: date)
        try repository.save(checkpoint: historicalCheckpoint)
        try repository.save(decision: historicalDecision)
        let reader = StatisticsScanBoundaryReader(
            firstBoundary: .cancellation,
            recoveryDescriptors: [descriptor("history-keep", availability: .iCloudOnly)]
        )
        let model = AppModel(
            library: reader,
            repository: repository,
            initialScan: historicalScan
        )
        model.authorization = .authorized
        model.hasLoadedAuthorization = true
        await model.statistics.load()
        let historicalProjection = try #require(model.statistics.projection)
        #expect(historicalProjection.newItemCount == 0)
        #expect(historicalProjection.processedItemCount == 1)
        #expect(historicalProjection.hasEstimatedAvailability)
        #expect(repository.statisticsSnapshotReadCount == 1)

        model.rescan()
        await reader.waitUntilCancellationReadIsSuspended()
        await waitUntilScanIsActive(model)
        model.cancelScan()
        await waitForScanPhase(.cancelled, in: model)

        #expect(model.scan.phase == .cancelled)
        #expect(await reader.cancellationThrowCount() == 1)
        let cancelledCheckpoint = try #require(try repository.latestCheckpoint())
        #expect(cancelledCheckpoint.stage == .cancelled)
        #expect(cancelledCheckpoint.id != historicalCheckpoint.id)
        await settleTerminalScanTask()
        #expect(model.statistics.projection == historicalProjection)
        #expect(repository.statisticsSnapshotReadCount == 1)
        #expect(try repository.decisions() == [historicalDecision])

        model.resumeScan()
        await waitForScanPhase(.completed, in: model)
        await waitForStatisticsReadCount(2, in: repository)

        let resumedCheckpoint = try #require(try repository.latestCheckpoint())
        #expect(model.scan.phase == .completed)
        #expect(await reader.descriptorReadCount() == 2)
        #expect(resumedCheckpoint.stage == .completed)
        #expect(resumedCheckpoint.id == cancelledCheckpoint.id)
        #expect(model.statistics.projection == historicalProjection)
        #expect(repository.statisticsSnapshotReadCount == 2)
        #expect(try repository.decisions() == [historicalDecision])
    }

    // Production breaks caught: a reader error never crosses ScanCoordinator's
    // failed boundary, failed work reloads over history, or retry resumes it.
    @MainActor
    @Test("Real reader failure preserves Statistics until restart completes")
    func realReaderFailurePreservesStatisticsUntilRestartCompletes() async throws {
        let storage = try SwiftDataTaskRepository(inMemory: true)
        let repository = StatisticsFailingRepository(storage: storage)
        let date = Date(timeIntervalSince1970: 3_400)
        var historicalScan = LibraryScanSnapshot.idle
        historicalScan.phase = .completed
        historicalScan.discoveredCount = 1
        historicalScan.processedCount = 1
        historicalScan.iCloudOnlyCount = 1
        let historicalCheckpoint = ScanCheckpoint(
            id: "statistics-failure-history",
            stage: .completed,
            processedAssetIDs: ["history-keep"],
            discoveredCount: 1,
            snapshot: historicalScan,
            updatedAt: date
        )
        let historicalDecision = decision("history-keep", .keep, date: date)
        try repository.save(checkpoint: historicalCheckpoint)
        try repository.save(decision: historicalDecision)
        let reader = StatisticsScanBoundaryReader(
            firstBoundary: .failure,
            recoveryDescriptors: [descriptor("history-keep", availability: .iCloudOnly)]
        )
        let model = AppModel(
            library: reader,
            repository: repository,
            initialScan: historicalScan
        )
        model.authorization = .authorized
        model.hasLoadedAuthorization = true
        await model.statistics.load()
        let historicalProjection = try #require(model.statistics.projection)
        #expect(historicalProjection.newItemCount == 0)
        #expect(historicalProjection.processedItemCount == 1)
        #expect(historicalProjection.hasEstimatedAvailability)
        #expect(repository.statisticsSnapshotReadCount == 1)

        model.rescan()
        await waitForScanPhase(.failed, in: model)

        #expect(model.scan.phase == .failed)
        #expect(model.scan.errorMessage?.contains("当前可访问范围") == true)
        #expect(await reader.failureThrowCount() == 1)
        let failedCheckpoint = try #require(try repository.latestCheckpoint())
        #expect(failedCheckpoint.stage == .failed)
        #expect(failedCheckpoint.id != historicalCheckpoint.id)
        await settleTerminalScanTask()
        #expect(model.statistics.projection == historicalProjection)
        #expect(repository.statisticsSnapshotReadCount == 1)
        #expect(try repository.decisions() == [historicalDecision])

        model.restartScan()
        await waitForScanPhase(.completed, in: model)
        await waitForStatisticsReadCount(2, in: repository)

        let restartedCheckpoint = try #require(try repository.latestCheckpoint())
        #expect(model.scan.phase == .completed)
        #expect(await reader.descriptorReadCount() == 2)
        #expect(restartedCheckpoint.stage == .completed)
        #expect(restartedCheckpoint.id != failedCheckpoint.id)
        #expect(model.statistics.projection == historicalProjection)
        #expect(repository.statisticsSnapshotReadCount == 2)
        #expect(try repository.decisions() == [historicalDecision])
    }

    @MainActor
    private func settleScan(_ model: AppModel) async {
        for _ in 0..<100 {
            if model.scan.phase == .completed || model.scan.phase == .failed || model.scan.phase == .cancelled {
                return
            }
            await Task.yield()
        }
    }

    @MainActor
    private func waitUntilScanIsActive(_ model: AppModel) async {
        for _ in 0..<10_000 {
            if model.scan.isScanning { return }
            await Task.yield()
        }
    }

    @MainActor
    private func waitForScanPhase(
        _ phase: LibraryScanSnapshot.Phase,
        in model: AppModel
    ) async {
        for _ in 0..<10_000 {
            if model.scan.phase == phase { return }
            await Task.yield()
        }
    }

    @MainActor
    private func waitForStatisticsReadCount(
        _ expected: Int,
        in repository: StatisticsFailingRepository
    ) async {
        for _ in 0..<10_000 {
            if repository.statisticsSnapshotReadCount >= expected { return }
            await Task.yield()
        }
    }

    private func settleTerminalScanTask() async {
        for _ in 0..<100 { await Task.yield() }
    }

    private func decision(
        _ assetID: String,
        _ kind: PhotoDecisionKind,
        bytes: Int64 = 0,
        date: Date
    ) -> PhotoDecision {
        PhotoDecision(assetID: assetID, kind: kind, estimatedBytes: bytes, createdAt: date)
    }

    private func task(id: String, status: CleanupTaskStatus, date: Date) -> CleanupTask {
        CleanupTask(
            id: id,
            type: .weekly,
            title: id,
            reason: id,
            assetIDs: [id],
            estimatedBytes: 0,
            estimatedMinutes: 1,
            risk: .low,
            confidence: 1,
            status: status,
            createdAt: date,
            updatedAt: date
        )
    }

    private func transaction(
        _ assetID: String,
        operation: MutationOperation,
        state: MutationItemState,
        date: Date
    ) -> MutationTransaction {
        MutationTransaction(
            id: "\(operation.rawValue)-\(assetID)-\(state.rawValue)",
            operation: operation,
            items: [MutationItem(assetID: assetID, state: state)],
            createdAt: date
        )
    }

    private func descriptor(
        _ id: String,
        availability: AssetAvailability = .local
    ) -> PhotoAssetDescriptor {
        PhotoAssetDescriptor(
            id: id,
            mediaType: .photo,
            creationDate: .now,
            pixelWidth: 1,
            pixelHeight: 1,
            duration: 0,
            estimatedBytes: 1,
            isFavorite: false,
            isEdited: false,
            isScreenshot: false,
            burstIdentifier: nil,
            availability: availability
        )
    }
}

@MainActor
private final class StatisticsFailingRepository: TaskRepository {
    let storage: SwiftDataTaskRepository
    var failReads = false
    var failClear = false
    private(set) var clearCallCount = 0
    private(set) var didReadStatisticsSnapshot = false
    private(set) var statisticsSnapshotReadCount = 0

    init(storage: SwiftDataTaskRepository) { self.storage = storage }

    func save(checkpoint: ScanCheckpoint) throws { try storage.save(checkpoint: checkpoint) }
    func latestCheckpoint() throws -> ScanCheckpoint? { try read { try storage.latestCheckpoint() } }
    func latestCompletedCheckpoint() throws -> ScanCheckpoint? { try read { try storage.latestCompletedCheckpoint() } }
    func initialCompletedCheckpoint() throws -> RepositoryLookup<ScanCheckpoint> { try read { try storage.initialCompletedCheckpoint() } }
    func save(task: CleanupTask) throws { try storage.save(task: task) }
    func save(tasks: [CleanupTask]) throws { try storage.save(tasks: tasks) }
    func tasks() throws -> [CleanupTask] { try read { try storage.tasks() } }
    func applySingleDecision(_ decision: PhotoDecision, undo: DecisionUndoEntry, task: CleanupTask?) throws { try storage.applySingleDecision(decision, undo: undo, task: task) }
    func save(decision: PhotoDecision) throws { try storage.save(decision: decision) }
    func save(decisions: [PhotoDecision]) throws { try storage.save(decisions: decisions) }
    func completeComparison(taskID: String, decisions: [PhotoDecision]) throws { try storage.completeComparison(taskID: taskID, decisions: decisions) }
    func completeArchive(transaction: MutationTransaction, decision: PhotoDecision, recentAlbumIDs: [String]) throws { try storage.completeArchive(transaction: transaction, decision: decision, recentAlbumIDs: recentAlbumIDs) }
    func removeDecision(for assetID: String) throws { try storage.removeDecision(for: assetID) }
    func removeDecisions(for assetIDs: Set<String>) throws { try storage.removeDecisions(for: assetIDs) }
    func decision(for assetID: String) throws -> PhotoDecision? { try read { try storage.decision(for: assetID) } }
    func decisions() throws -> [PhotoDecision] { try read { try storage.decisions() } }
    func save(undo: DecisionUndoEntry) throws { try storage.save(undo: undo) }
    func latestUndo() throws -> DecisionUndoEntry? { try read { try storage.latestUndo() } }
    func removeUndo(id: UUID) throws { try storage.removeUndo(id: id) }
    func save(transaction: MutationTransaction) throws { try storage.save(transaction: transaction) }
    func transactions() throws -> [MutationTransaction] { try read { try storage.transactions() } }
    func transaction(id: String) throws -> RepositoryLookup<MutationTransaction> { try read { try storage.transaction(id: id) } }
    func save(settings: WorkflowSettings) throws { try storage.save(settings: settings) }
    func settings() throws -> WorkflowSettings { try read { try storage.settings() } }
    func save(summary: CleanupSummary) throws { try storage.save(summary: summary) }
    func summaries() throws -> [CleanupSummary] {
        let summaries = try read { try storage.summaries() }
        didReadStatisticsSnapshot = true
        statisticsSnapshotReadCount += 1
        return summaries
    }
    func summary(id: UUID) throws -> RepositoryLookup<CleanupSummary> { try read { try storage.summary(id: id) } }
    func reconcile(availableAssetIDs: Set<String>) throws { try storage.reconcile(availableAssetIDs: availableAssetIDs) }
    func clearHistory() throws {
        clearCallCount += 1
        if failClear { throw StatisticsTestError.forced }
        try storage.clearHistory()
    }

    private func read<T>(_ body: () throws -> T) throws -> T {
        if failReads { throw StatisticsTestError.forced }
        return try body()
    }
}

private actor StatisticsScanBoundaryReader: PhotoLibraryReading {
    enum FirstBoundary: Sendable {
        case cancellation
        case failure
    }

    private let firstBoundary: FirstBoundary
    private let recoveryDescriptors: [PhotoAssetDescriptor]
    private var descriptorReads = 0
    private var cancellationThrows = 0
    private var failureThrows = 0
    private var cancellationContinuation: CheckedContinuation<[PhotoAssetDescriptor], Error>?

    init(
        firstBoundary: FirstBoundary,
        recoveryDescriptors: [PhotoAssetDescriptor]
    ) {
        self.firstBoundary = firstBoundary
        self.recoveryDescriptors = recoveryDescriptors
    }

    func authorizationStatus() -> PhotoAuthorization { .authorized }
    func requestAuthorization() -> PhotoAuthorization { .authorized }

    func accessibleAssetDescriptors() async throws -> [PhotoAssetDescriptor] {
        descriptorReads += 1
        guard descriptorReads == 1 else { return recoveryDescriptors }

        switch firstBoundary {
        case .cancellation:
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    cancellationContinuation = continuation
                }
            } onCancel: {
                Task { await self.cancelSuspendedRead() }
            }
        case .failure:
            failureThrows += 1
            throw PhotoLibraryReadError.scopeUnavailable
        }
    }

    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> {
        AsyncStream { $0.finish() }
    }

    func waitUntilCancellationReadIsSuspended() async {
        while cancellationContinuation == nil { await Task.yield() }
    }

    func descriptorReadCount() -> Int { descriptorReads }
    func cancellationThrowCount() -> Int { cancellationThrows }
    func failureThrowCount() -> Int { failureThrows }

    private func cancelSuspendedRead() {
        guard let continuation = cancellationContinuation else { return }
        cancellationContinuation = nil
        cancellationThrows += 1
        continuation.resume(throwing: CancellationError())
    }
}

private enum StatisticsTestError: LocalizedError {
    case forced
    var errorDescription: String? { "统计记录读取失败" }
}

private actor StatisticsInventoryMutator: PhotoLibraryMutating {
    struct Inventory: Equatable, Sendable {
        let assetIDs: Set<String>
        let albums: [String: Set<String>]
    }

    let backendMode = MutationBackendMode.simulated
    private var assetIDs: Set<String>
    private var albums: [String: Set<String>]
    private var calls = 0

    init(assetIDs: Set<String>, albums: [String: Set<String>]) {
        self.assetIDs = assetIDs
        self.albums = albums
    }

    func availableAssetIDs(for requestedIDs: [String]) -> Set<String> {
        assetIDs.intersection(requestedIDs)
    }

    func listAlbums() -> [PhotoAlbumDescriptor] {
        albums.keys.sorted().map { id in
            PhotoAlbumDescriptor(id: id, title: id, assetCount: albums[id, default: []].count)
        }
    }

    func createAlbum(named title: String) -> PhotoAlbumDescriptor? {
        calls += 1
        return nil
    }

    func archivedAssetIDs(for requestedIDs: [String], inAlbumID albumID: String) -> Set<String> {
        albums[albumID, default: []].intersection(requestedIDs)
    }

    func addAssets(withIDs assetIDs: [String], toAlbumID albumID: String) -> PhotoMutationBatch {
        calls += 1
        return PhotoMutationBatch(operation: .archive, items: [], targetAlbumID: albumID)
    }

    func deleteAssets(withIDs assetIDs: [String]) -> PhotoMutationBatch {
        calls += 1
        return PhotoMutationBatch(operation: .delete, items: [], targetAlbumID: nil)
    }

    func inventory() -> Inventory { Inventory(assetIDs: assetIDs, albums: albums) }
    func mutationCallCount() -> Int { calls }
}

private actor StatisticsSuspendingBackendMutator: PhotoLibraryMutating {
    private var shouldSuspendBackendRead = true
    private var isBackendReadSuspended = false
    private var backendReadContinuation: CheckedContinuation<Void, Never>?

    var backendMode: MutationBackendMode {
        get async {
            if shouldSuspendBackendRead {
                shouldSuspendBackendRead = false
                isBackendReadSuspended = true
                await withCheckedContinuation { backendReadContinuation = $0 }
            }
            return .simulated
        }
    }

    func waitUntilBackendReadIsSuspended() async {
        while !isBackendReadSuspended { await Task.yield() }
    }

    func resumeBackendRead() {
        backendReadContinuation?.resume()
        backendReadContinuation = nil
    }

    func availableAssetIDs(for requestedIDs: [String]) -> Set<String> { Set(requestedIDs) }
    func listAlbums() -> [PhotoAlbumDescriptor] { [] }
    func createAlbum(named title: String) -> PhotoAlbumDescriptor? { nil }
    func archivedAssetIDs(for requestedIDs: [String], inAlbumID albumID: String) -> Set<String> { [] }
    func addAssets(withIDs assetIDs: [String], toAlbumID albumID: String) -> PhotoMutationBatch {
        PhotoMutationBatch(operation: .archive, items: [], targetAlbumID: albumID)
    }
    func deleteAssets(withIDs assetIDs: [String]) -> PhotoMutationBatch {
        PhotoMutationBatch(operation: .delete, items: [], targetAlbumID: nil)
    }
}

private actor StatisticsCountingReader: PhotoLibraryReading {
    private var reads = 0

    func authorizationStatus() -> PhotoAuthorization { .authorized }
    func requestAuthorization() -> PhotoAuthorization { .authorized }
    func accessibleAssetDescriptors() -> [PhotoAssetDescriptor] {
        reads += 1
        return [PhotoAssetDescriptor(
            id: "asset",
            mediaType: .photo,
            creationDate: .now,
            pixelWidth: 1,
            pixelHeight: 1,
            duration: 0,
            estimatedBytes: 1,
            isFavorite: false,
            isEdited: false,
            isScreenshot: false,
            burstIdentifier: nil,
            availability: .local
        )]
    }
    func libraryChanges() -> AsyncStream<PhotoLibraryChange> { AsyncStream { $0.finish() } }
    func thumbnail(for assetID: String, maxPixelSize: Int) -> PhotoThumbnail? { nil }
    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> { AsyncStream { $0.finish() } }
    func descriptorReadCount() -> Int { reads }
}

private actor StatisticsSuspendingReader: PhotoLibraryReading {
    private var didRequestDescriptors = false
    private var descriptorContinuation: CheckedContinuation<[PhotoAssetDescriptor], Error>?

    func authorizationStatus() -> PhotoAuthorization { .authorized }
    func requestAuthorization() -> PhotoAuthorization { .authorized }
    func accessibleAssetDescriptors() async throws -> [PhotoAssetDescriptor] {
        didRequestDescriptors = true
        return try await withCheckedThrowingContinuation { descriptorContinuation = $0 }
    }
    func waitUntilDescriptorReadIsSuspended() async {
        while !didRequestDescriptors { await Task.yield() }
    }
    func resumeDescriptorRead(with descriptors: [PhotoAssetDescriptor]) {
        descriptorContinuation?.resume(returning: descriptors)
        descriptorContinuation = nil
    }
    func libraryChanges() -> AsyncStream<PhotoLibraryChange> { AsyncStream { $0.finish() } }
    func thumbnail(for assetID: String, maxPixelSize: Int) -> PhotoThumbnail? { nil }
    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> { AsyncStream { $0.finish() } }
}
