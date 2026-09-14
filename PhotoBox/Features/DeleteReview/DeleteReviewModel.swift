import Foundation
import Observation

nonisolated struct DeleteReviewCandidate: Identifiable, Equatable, Sendable {
    let descriptor: PhotoAssetDescriptor
    let decision: PhotoDecision
    let sourceTask: CleanupTask

    var id: String { descriptor.id }
    var estimatedBytes: Int64 { decision.estimatedBytes }
}

nonisolated enum DeleteReviewLoadState: Equatable, Sendable {
    case loading
    case ready
    case empty
    case failed(String)
}

@MainActor
@Observable
final class DeleteReviewModel {
    private let repository: any TaskRepository
    private let library: any PhotoLibraryReading
    private let inventoryStore: LibraryInventoryStore?
    private var mutator: any PhotoLibraryMutating
    private var coordinator: MutationCoordinator
    private let onSubmissionCompleted: (() -> Void)?
    private let onTransactionCompleted: ((MutationTransaction) -> Void)?
    private let submissionSignal: (@Sendable () async -> Int)?
    private let submissionReadSignal: (@Sendable () async -> Int)?

    @ObservationIgnored
    private var loadGeneration = UUID()

    @ObservationIgnored
    private var handedOffTransactionIDs: Set<String> = []

    private(set) var loadState: DeleteReviewLoadState = .loading
    private(set) var candidates: [DeleteReviewCandidate] = []
    private(set) var selectedCandidateIDs: Set<String> = []
    private(set) var protectedExclusionCount = 0
    private(set) var isSubmitting = false
    private(set) var submissionErrorMessage: String?
    private(set) var recordedSubmissionCount = 0
    private(set) var recordedSubmissionReadCount = 0
    private(set) var lastTransaction: MutationTransaction?
    private(set) var retryTransactionID: String?

    init(
        repository: any TaskRepository,
        library: any PhotoLibraryReading,
        inventoryStore: LibraryInventoryStore? = nil,
        mutator: any PhotoLibraryMutating,
        submissionSignal: (@Sendable () async -> Int)? = nil,
        submissionReadSignal: (@Sendable () async -> Int)? = nil,
        onSubmissionCompleted: (() -> Void)? = nil,
        onTransactionCompleted: ((MutationTransaction) -> Void)? = nil
    ) {
        self.repository = repository
        self.library = library
        self.inventoryStore = inventoryStore
        self.mutator = mutator
        coordinator = MutationCoordinator(repository: repository, mutator: mutator)
        self.submissionSignal = submissionSignal
        self.submissionReadSignal = submissionReadSignal
        self.onSubmissionCompleted = onSubmissionCompleted
        self.onTransactionCompleted = onTransactionCompleted
    }

    var selectedCandidates: [DeleteReviewCandidate] {
        candidates.filter { selectedCandidateIDs.contains($0.id) }
    }

    var estimatedReclaimableBytes: Int64 {
        selectedCandidates.reduce(0) { $0 + $1.estimatedBytes }
    }

    var canConfirm: Bool {
        loadState == .ready && !selectedCandidateIDs.isEmpty && !isSubmitting
    }

    var recoveryRequiresReload: Bool {
        retryTransactionID != nil && selectedCandidateIDs.isEmpty && !isSubmitting
    }

    var hasSubmissionSignal: Bool { submissionSignal != nil }

    func load() async {
        await load(preservingSelection: false)
    }

    func reloadRecovery() async {
        await load(preservingSelection: false)
    }

    private func load(preservingSelection: Bool) async {
        let generation = UUID()
        loadGeneration = generation
        loadState = .loading
        submissionErrorMessage = nil
        let previouslySelectedIDs = selectedCandidateIDs

        do {
            let reconciledTransaction = try await coordinator.reconcileInterruptedDeleteTransactions()
            guard isCurrentLoad(generation) else { return }
            handOffReconciledTransactionIfResolved(reconciledTransaction)
            let descriptors = try await loadDescriptors()
            guard isCurrentLoad(generation) else { return }
            let descriptorsByID = Dictionary(
                uniqueKeysWithValues: descriptors.compactMap { descriptor in
                    descriptor.availability == .unavailable ? nil : (descriptor.id, descriptor)
                }
            )
            let tasksByID = Dictionary(uniqueKeysWithValues: try repository.tasks().map { ($0.id, $0) })
            let decisions = try repository.decisions().filter { !$0.isSubmitted }
            let transactions = try repository.transactions()
            guard isCurrentLoad(generation) else { return }

            let resolvedIDs = Set(transactions.flatMap { transaction in
                guard transaction.operation == .delete else { return [String]() }
                return transaction.items.compactMap { item in
                    item.state == .succeeded || item.state == .stale ? item.assetID : nil
                }
            })
            let projectedCandidates = decisions.compactMap { decision -> DeleteReviewCandidate? in
                guard decision.kind == .deleteCandidate,
                      !resolvedIDs.contains(decision.assetID),
                      let descriptor = descriptorsByID[decision.assetID],
                      descriptor.id == decision.assetID,
                      let taskID = decision.taskID,
                      let sourceTask = tasksByID[taskID] else { return nil }
                return DeleteReviewCandidate(
                    descriptor: descriptor,
                    decision: decision,
                    sourceTask: sourceTask
                )
            }
            .sorted { first, second in
                if first.decision.createdAt != second.decision.createdAt {
                    return first.decision.createdAt < second.decision.createdAt
                }
                return first.id < second.id
            }

            let retryableStates: Set<MutationItemState> = [.failed, .cancelled, .pending]
            let recoverableTransaction = transactions.last { transaction in
                transaction.operation == .delete
                    && transaction.items.contains { item in
                        retryableStates.contains(item.state)
                    }
            }
            let recoverableIDs: Set<String>
            let recoveredCandidates: [DeleteReviewCandidate]
            if let recoverableTransaction {
                recoverableIDs = Set(recoverableTransaction.items.compactMap { item in
                    retryableStates.contains(item.state) ? item.assetID : nil
                })
                recoveredCandidates = projectedCandidates.filter { recoverableIDs.contains($0.id) }
            } else {
                recoverableIDs = []
                recoveredCandidates = projectedCandidates
            }

            candidates = recoveredCandidates
            selectedCandidateIDs = preservingSelection
                ? previouslySelectedIDs.intersection(Set(recoveredCandidates.map(\.id)))
                : Set(recoveredCandidates.map(\.id))
            lastTransaction = recoverableTransaction
            retryTransactionID = recoverableTransaction?.id
            protectedExclusionCount = decisions.count { decision in
                guard decision.kind == .protect,
                      let taskID = decision.taskID,
                      tasksByID[taskID] != nil,
                      let descriptor = descriptorsByID[decision.assetID],
                      descriptor.id == decision.assetID else { return false }
                return true
            }
            loadState = recoveredCandidates.isEmpty ? .empty : .ready
            if recoverableTransaction != nil, selectedCandidateIDs.isEmpty {
                submissionErrorMessage = recoveredCandidates.isEmpty
                    ? "存在未完成的删除请求，但相关照片当前不可访问。请返回任务列表后稍后重试。"
                    : "存在未完成的删除请求。请重新载入或返回任务列表。"
            }
        } catch {
            guard isCurrentLoad(generation) else { return }
            loadState = .failed("无法载入删除复核，请重试。")
            submissionErrorMessage = "无法载入删除复核，请重试。"
        }
    }

    private func loadDescriptors() async throws -> [PhotoAssetDescriptor] {
        if let cached = await inventoryStore?.snapshot() {
            return cached
        }
        let loaded = try await library.accessibleAssetDescriptors()
        await inventoryStore?.replace(with: loaded)
        return loaded
    }

    func retryLoad() async { await load() }

    func removeCandidate(id: String) {
        guard candidates.contains(where: { $0.id == id }), !isSubmitting else { return }
        selectedCandidateIDs.remove(id)
    }

    func cancelConfirmation() {
        guard retryTransactionID == nil else { return }
        submissionErrorMessage = nil
    }

    func replaceMutator(_ mutator: any PhotoLibraryMutating) {
        self.mutator = mutator
        coordinator = MutationCoordinator(repository: repository, mutator: mutator)
    }

    func refreshSubmissionSignal() async {
        guard let submissionSignal else { return }
        recordedSubmissionCount = await submissionSignal()
        if let submissionReadSignal {
            recordedSubmissionReadCount = await submissionReadSignal()
        }
    }

    func confirmDeletion() async {
        guard canConfirm, retryTransactionID == nil else { return }
        isSubmitting = true
        submissionErrorMessage = nil
        defer { isSubmitting = false }

        do {
            let transactions = try repository.transactions()
            if transactions.contains(where: {
                $0.operation == .delete && $0.items.contains(where: { $0.state == .submitted })
            }) {
                try await coordinator.reconcileInterruptedDeleteTransactions()
                await load(preservingSelection: true)
                return
            }
            let retryableStates: Set<MutationItemState> = [.failed, .cancelled, .pending]
            guard !transactions.contains(where: {
                $0.operation == .delete && $0.items.contains(where: { retryableStates.contains($0.state) })
            }) else {
                submissionErrorMessage = "存在未完成的删除请求，请重新载入或返回任务列表。"
                return
            }
            let currentDeleteIDs = Set(try repository.decisions().compactMap { decision -> String? in
                decision.kind == .deleteCandidate && !decision.isSubmitted ? decision.assetID : nil
            })
            let reviewedIDs = selectedCandidateIDs.filter { currentDeleteIDs.contains($0) }.sorted()
            guard !reviewedIDs.isEmpty else {
                submissionErrorMessage = "待删除照片已变化，请重新复核。"
                return
            }
            apply(transaction: try await coordinator.submit(operation: .delete, assetIDs: reviewedIDs))
        } catch {
            submissionErrorMessage = "无法提交删除请求，请重试或返回任务列表。"
        }
    }

    func retryDeletion() async {
        guard let retryTransactionID, !selectedCandidateIDs.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        submissionErrorMessage = nil
        defer { isSubmitting = false }
        do {
            apply(transaction: try await coordinator.retry(
                transactionID: retryTransactionID,
                assetIDs: selectedCandidateIDs.sorted()
            ))
        } catch {
            submissionErrorMessage = "无法重试删除请求，请重新确认或返回任务列表。"
        }
    }

    private func apply(transaction: MutationTransaction) {
        lastTransaction = transaction
        let resolvedIDs = Set(transaction.items.compactMap { item -> String? in
            item.state == .succeeded || item.state == .stale ? item.assetID : nil
        })
        candidates.removeAll { resolvedIDs.contains($0.id) }
        selectedCandidateIDs.subtract(resolvedIDs)
        let hasRetryableItems = transaction.items.contains {
            $0.state == .failed || $0.state == .cancelled || $0.state == .pending
        }
        retryTransactionID = hasRetryableItems ? transaction.id : nil
        loadState = selectedCandidateIDs.isEmpty ? .empty : .ready
        submissionErrorMessage = hasRetryableItems
            ? (selectedCandidateIDs.isEmpty
                ? "存在未完成的删除请求。请重新载入或返回任务列表。"
                : "无法完成删除请求，请重新确认后重试或返回任务列表。")
            : nil
        Task { await refreshSubmissionSignal() }
        onSubmissionCompleted?()
        onTransactionCompleted?(transaction)
    }

    private func handOffReconciledTransactionIfResolved(_ transaction: MutationTransaction?) {
        guard let transaction,
              !transaction.items.isEmpty,
              transaction.items.allSatisfy({ $0.state == .succeeded || $0.state == .stale }),
              handedOffTransactionIDs.insert(transaction.id).inserted else { return }
        lastTransaction = transaction
        onSubmissionCompleted?()
        onTransactionCompleted?(transaction)
    }

    private func isCurrentLoad(_ generation: UUID) -> Bool {
        !Task.isCancelled && loadGeneration == generation
    }
}
