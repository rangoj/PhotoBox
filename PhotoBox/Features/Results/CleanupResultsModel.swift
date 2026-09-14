import Foundation
import Observation

nonisolated struct CleanupResultProjection: Equatable, Sendable {
    let source: CleanupResultSource
    let succeededDeleteCount: Int
    let unresolvedDeleteCount: Int
    let staleDeleteCount: Int
    let archiveSucceededCount: Int
    let protectCount: Int
    let decideLaterCount: Int
    let keepCount: Int
    let estimatedReclaimableBytes: Int64
    let elapsedSeconds: TimeInterval?
    let unresolvedIDs: [String]
    let hasDeletionResult: Bool

    var canRetry: Bool { hasDeletionResult && !unresolvedIDs.isEmpty }

    init(
        transaction: MutationTransaction,
        decisions: [PhotoDecision],
        transactions: [MutationTransaction]
    ) {
        source = .transaction(transaction.id)
        let succeededIDs = Set(transaction.items.filter { $0.state == .succeeded }.map(\.assetID))
        let transactionAssetIDs = Set(transaction.items.map(\.assetID))
        let sourceTaskIDs = Set(decisions.compactMap { decision in
            transactionAssetIDs.contains(decision.assetID) ? decision.taskID : nil
        })
        let scopedDecisions = decisions.filter { decision in
            sourceTaskIDs.contains(decision.taskID ?? "")
        }
        succeededDeleteCount = transaction.operation == .delete ? succeededIDs.count : 0
        unresolvedDeleteCount = transaction.operation == .delete
            ? transaction.items.count { [.failed, .cancelled, .pending].contains($0.state) }
            : 0
        staleDeleteCount = transaction.operation == .delete
            ? transaction.items.count { $0.state == .stale }
            : 0
        archiveSucceededCount = transactions
            .filter { $0.operation == .archive }
            .flatMap(\.items)
            .count { item in
                item.state == .succeeded
                    && scopedDecisions.contains { $0.assetID == item.assetID && $0.kind == .archive }
            }
        protectCount = scopedDecisions.count { $0.kind == .protect }
        decideLaterCount = scopedDecisions.count { $0.kind == .decideLater }
        keepCount = scopedDecisions.count { $0.kind == .keep }
        estimatedReclaimableBytes = scopedDecisions
            .filter { succeededIDs.contains($0.assetID) }
            .reduce(0) { $0 + $1.estimatedBytes }
        elapsedSeconds = transaction.completedAt.map { $0.timeIntervalSince(transaction.createdAt) }
        unresolvedIDs = transaction.operation == .delete
            ? transaction.items
                .filter { [.failed, .cancelled, .pending].contains($0.state) }
                .map(\.assetID)
                .sorted()
            : []
        hasDeletionResult = transaction.operation == .delete
    }

    init(summary: CleanupSummary) {
        source = .summary(summary.id)
        succeededDeleteCount = 0
        unresolvedDeleteCount = 0
        staleDeleteCount = 0
        archiveSucceededCount = summary.archivedCount
        protectCount = summary.protectedCount
        decideLaterCount = summary.deferredCount
        keepCount = summary.keptCount
        estimatedReclaimableBytes = 0
        elapsedSeconds = summary.elapsedSeconds
        unresolvedIDs = []
        hasDeletionResult = false
    }
}

nonisolated enum CleanupResultsLoadState: Equatable, Sendable {
    case loading
    case ready
    case missing
    case failed
}

@MainActor
@Observable
final class CleanupResultsModel {
    private let source: CleanupResultSource
    private let repository: any TaskRepository
    private var coordinator: MutationCoordinator
    private let retrySubmissionCountSignal: (@Sendable () async -> Int)?
    private let retrySubmissionSignal: (@Sendable () async -> [String])?

    private(set) var loadState: CleanupResultsLoadState = .loading
    private(set) var projection: CleanupResultProjection?
    private(set) var recoveryMessage: String?
    private(set) var isRetrying = false
    private(set) var recordedRetrySubmissionCount = 0
    private(set) var recordedRetryAssetIDs: [String] = []

    init(
        source: CleanupResultSource,
        repository: any TaskRepository,
        mutator: any PhotoLibraryMutating,
        retrySubmissionCountSignal: (@Sendable () async -> Int)? = nil,
        retrySubmissionSignal: (@Sendable () async -> [String])? = nil
    ) {
        self.source = source
        self.repository = repository
        coordinator = MutationCoordinator(repository: repository, mutator: mutator)
        self.retrySubmissionCountSignal = retrySubmissionCountSignal
        self.retrySubmissionSignal = retrySubmissionSignal
    }

    var canRetry: Bool { projection?.canRetry == true && !isRetrying }
    var hasRetrySubmissionCountSignal: Bool { retrySubmissionCountSignal != nil }

    func load() async {
        loadState = .loading
        do {
            switch source {
            case .transaction(let transactionID):
                switch try repository.transaction(id: transactionID) {
                case .found: break
                case .missing:
                    setMissingResult()
                    return
                case .corrupt:
                    setCorruptResult()
                    return
                }
                _ = try await coordinator.reconcileInterruptedDeleteTransaction(id: transactionID)
                let transaction: MutationTransaction
                switch try repository.transaction(id: transactionID) {
                case .found(let value): transaction = value
                case .missing:
                    setMissingResult()
                    return
                case .corrupt:
                    setCorruptResult()
                    return
                }
                projection = CleanupResultProjection(
                    transaction: transaction,
                    decisions: try repository.decisions(),
                    transactions: try repository.transactions()
                )
            case .summary(let summaryID):
                let summary: CleanupSummary
                switch try repository.summary(id: summaryID) {
                case .found(let value): summary = value
                case .missing:
                    setMissingResult()
                    return
                case .corrupt:
                    setCorruptResult()
                    return
                }
                projection = CleanupResultProjection(summary: summary)
            }
            recoveryMessage = nil
            loadState = .ready
            await refreshRetrySubmissionSignal()
        } catch {
            if case MutationCoordinatorError.backendMismatch = error {
                recoveryMessage = "这次整理记录的处理模式与当前设置不一致。请恢复原处理模式后重新载入，或返回任务列表。"
            } else if case MutationCoordinatorError.missingBackendIdentity = error {
                recoveryMessage = "这次整理记录缺少处理模式信息，无法安全恢复。请返回任务列表。"
            } else if projection != nil {
                recoveryMessage = "无法重新读取这次整理结果，已保留上次结果。请重试或返回任务列表。"
            } else {
                recoveryMessage = "无法读取这次整理结果。请重试或返回任务列表。"
            }
            loadState = projection == nil ? .failed : .ready
        }
    }

    func retry() async {
        guard case .transaction(let transactionID) = source,
              let projection, projection.canRetry, !isRetrying else { return }
        isRetrying = true
        recoveryMessage = nil
        defer { isRetrying = false }
        do {
            let transaction = try await coordinator.retry(
                transactionID: transactionID,
                assetIDs: projection.unresolvedIDs
            )
            self.projection = CleanupResultProjection(
                transaction: transaction,
                decisions: try repository.decisions(),
                transactions: try repository.transactions()
            )
            loadState = .ready
            await refreshRetrySubmissionSignal()
        } catch {
            await load()
            recoveryMessage = "无法重试未完成的删除请求。当前结果已保留，请重试或返回任务列表。"
        }
    }

    func replaceMutator(_ mutator: any PhotoLibraryMutating) {
        coordinator = MutationCoordinator(repository: repository, mutator: mutator)
    }

    func refreshRetrySubmissionSignal() async {
        if let retrySubmissionCountSignal {
            recordedRetrySubmissionCount = await retrySubmissionCountSignal()
        }
        if let retrySubmissionSignal {
            recordedRetryAssetIDs = await retrySubmissionSignal()
        }
    }

    private func setMissingResult() {
        projection = nil
        recoveryMessage = "找不到这次整理记录。请返回任务列表。"
        loadState = .missing
    }

    private func setCorruptResult() {
        recoveryMessage = "这次整理记录已损坏，无法安全显示。请返回任务列表。"
        loadState = projection == nil ? .failed : .ready
    }
}
