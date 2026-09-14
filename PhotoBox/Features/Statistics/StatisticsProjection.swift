import Foundation

nonisolated struct StatisticsProjection: Equatable, Sendable {
    let newItemCount: Int
    let processedItemCount: Int
    let successfulArchiveCount: Int
    let protectionCount: Int
    let deferralCount: Int
    let reviewedDeletionCount: Int
    let estimatedReclaimableBytes: Int64
    let completedTaskCount: Int
    let totalTaskCount: Int
    let hasEstimatedAvailability: Bool
    let hasEstimatedReclaimableSpace: Bool
    let hasRecentlyDeletedEstimate: Bool

    var hasOrganizationActivity: Bool {
        processedItemCount > 0 || successfulArchiveCount > 0 || protectionCount > 0 || deferralCount > 0
    }

    static func project(
        checkpoint: ScanCheckpoint?,
        baselineAssetIDs: Set<String>? = nil,
        tasks: [CleanupTask],
        decisions: [PhotoDecision],
        transactions: [MutationTransaction],
        summaries: [CleanupSummary]
    ) -> StatisticsProjection {
        let currentDecisions = latestDecisionsByAssetID(decisions)
        let successfulArchiveIDs = succeededAssetIDs(
            in: latestTransactionsByID(transactions),
            operation: .archive
        )
        let successfulDeleteIDs = succeededAssetIDs(
            in: latestTransactionsByID(transactions),
            operation: .delete
        )
        let tasksByID = latestTasksByID(tasks)
        let scannedIDs = Set(checkpoint?.processedAssetIDs ?? [])
        let newlyDiscoveredIDs: Set<String>
        if let baselineAssetIDs {
            newlyDiscoveredIDs = scannedIDs.subtracting(baselineAssetIDs)
        } else {
            newlyDiscoveredIDs = scannedIDs.subtracting(Set(currentDecisions.keys))
        }
        let keepIDs = Set(currentDecisions.values.filter { $0.kind == .keep }.map(\.assetID))
        let protectedIDs = Set(currentDecisions.values.filter { $0.kind == .protect }.map(\.assetID))
        let deferredIDs = Set(currentDecisions.values.filter { $0.kind == .decideLater }.map(\.assetID))
        let processedIDs = keepIDs
            .union(protectedIDs)
            .union(deferredIDs)
            .union(successfulArchiveIDs)
            .union(successfulDeleteIDs)
        let estimatedBytes = successfulDeleteIDs.reduce(Int64.zero) { total, assetID in
            total + (currentDecisions[assetID]?.estimatedBytes ?? 0)
        }
        let summaryTotals = summariesByID(summaries).values.reduce(into: SummaryTotals()) { totals, summary in
            totals.kept += summary.keptCount
            totals.deleted += summary.deleteCandidateCount
            totals.archived += summary.archivedCount
            totals.protected += summary.protectedCount
            totals.deferred += summary.deferredCount
            totals.estimatedBytes += summary.estimatedReclaimableBytes
        }
        let detailedProcessedCount = processedIDs.count
        // Summaries are snapshots of decision work. Once detailed decisions or
        // transactions exist, they are the authoritative source and summaries
        // must not be combined with them.
        let usesSummaryOnlyMetrics = currentDecisions.isEmpty && transactions.isEmpty
        let processedItemCount = usesSummaryOnlyMetrics ? summaryTotals.processedCount : detailedProcessedCount
        let protectionCount = usesSummaryOnlyMetrics ? summaryTotals.protected : protectedIDs.count
        let deferralCount = usesSummaryOnlyMetrics ? summaryTotals.deferred : deferredIDs.count
        let reclaimableBytes = usesSummaryOnlyMetrics ? summaryTotals.estimatedBytes : estimatedBytes

        return StatisticsProjection(
            newItemCount: newlyDiscoveredIDs.count,
            processedItemCount: processedItemCount,
            successfulArchiveCount: successfulArchiveIDs.count,
            protectionCount: protectionCount,
            deferralCount: deferralCount,
            reviewedDeletionCount: successfulDeleteIDs.count,
            estimatedReclaimableBytes: reclaimableBytes,
            completedTaskCount: tasksByID.values.count { $0.status == .completed },
            totalTaskCount: tasksByID.count,
            hasEstimatedAvailability: (checkpoint?.snapshot.iCloudOnlyCount ?? 0) > 0,
            hasEstimatedReclaimableSpace: reclaimableBytes > 0,
            hasRecentlyDeletedEstimate: !successfulDeleteIDs.isEmpty
        )
    }

    private struct SummaryTotals {
        var kept = 0
        var deleted = 0
        var archived = 0
        var protected = 0
        var deferred = 0
        var estimatedBytes: Int64 = 0

        var processedCount: Int { kept + deleted + archived + protected + deferred }
    }

    private static func summariesByID(_ summaries: [CleanupSummary]) -> [UUID: CleanupSummary] {
        summaries.reduce(into: [:]) { result, summary in
            guard let current = result[summary.id], current.createdAt > summary.createdAt else {
                result[summary.id] = summary
                return
            }
        }
    }

    private static func latestTasksByID(_ tasks: [CleanupTask]) -> [String: CleanupTask] {
        tasks.reduce(into: [:]) { result, task in
            guard let current = result[task.id], current.updatedAt > task.updatedAt else {
                result[task.id] = task
                return
            }
        }
    }

    private static func latestTransactionsByID(
        _ transactions: [MutationTransaction]
    ) -> [MutationTransaction] {
        transactions.reduce(into: [:]) { result, transaction in
            guard let current = result[transaction.id], current.createdAt > transaction.createdAt else {
                result[transaction.id] = transaction
                return
            }
        }
        .values
        .sorted { $0.id < $1.id }
    }

    private static func latestDecisionsByAssetID(_ decisions: [PhotoDecision]) -> [String: PhotoDecision] {
        decisions.reduce(into: [:]) { result, decision in
            guard let current = result[decision.assetID], current.createdAt > decision.createdAt else {
                result[decision.assetID] = decision
                return
            }
        }
    }

    private static func succeededAssetIDs(
        in transactions: [MutationTransaction],
        operation: MutationOperation
    ) -> Set<String> {
        Set(transactions
            .filter { $0.operation == operation }
            .flatMap(\.items)
            .filter { $0.state == .succeeded }
            .map(\.assetID))
    }
}
