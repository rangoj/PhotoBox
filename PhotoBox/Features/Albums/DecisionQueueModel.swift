import Foundation
import Observation

nonisolated struct DecisionQueueItem: Identifiable, Equatable, Sendable {
    let descriptor: PhotoAssetDescriptor
    let decision: PhotoDecision

    var id: String { decision.assetID }
}

nonisolated enum DecisionQueueLoadState: Equatable, Sendable {
    case loading
    case loaded
    case failed(String)
}

@MainActor
@Observable
final class DecisionQueueModel {
    private enum FailedAction {
        case deferAgain(String)
        case unprotect(String)
    }

    private let repository: any DecisionQueuePersisting
    private let library: any PhotoLibraryReading
    private let inventoryStore: LibraryInventoryStore?
    private let now: () -> Date
    private let onDecisionsChanged: (() -> Void)?
    private var descriptorsByID: [String: PhotoAssetDescriptor] = [:]
    private var decisions: [PhotoDecision] = []
    private var failedAction: FailedAction?
    private var actionErrorMessage: String?

    @ObservationIgnored
    private var loadGeneration = UUID()

    @ObservationIgnored
    private var initialLoadInProgress = false

    private(set) var loadState: DecisionQueueLoadState = .loading
    private(set) var decideLaterItems: [DecisionQueueItem] = []
    private(set) var protectedItems: [DecisionQueueItem] = []
    private(set) var hasLoadedSuccessfully = false
    private(set) var reconciliationMessage: String?

    init(
        repository: any DecisionQueuePersisting,
        library: any PhotoLibraryReading,
        inventoryStore: LibraryInventoryStore? = nil,
        now: @escaping () -> Date = Date.init,
        onDecisionsChanged: (() -> Void)? = nil
    ) {
        self.repository = repository
        self.library = library
        self.inventoryStore = inventoryStore
        self.now = now
        self.onDecisionsChanged = onDecisionsChanged
    }

    var decideLaterCount: Int { decideLaterItems.count }
    var protectedCount: Int { protectedItems.count }
    var isLoading: Bool { loadState == .loading }
    var canRetry: Bool { failedAction != nil }

    var errorMessage: String? {
        if let actionErrorMessage { return actionErrorMessage }
        if case .failed(let message) = loadState { return message }
        return nil
    }

    func loadIfNeeded() async {
        guard isLoading, !initialLoadInProgress else { return }
        initialLoadInProgress = true
        defer { initialLoadInProgress = false }
        await load()
    }

    func load() async {
        let generation = UUID()
        loadGeneration = generation
        let previousLoadState = loadState
        loadState = .loading
        actionErrorMessage = nil
        failedAction = nil
        reconciliationMessage = nil
        do {
            let loadedDescriptors = try await loadDescriptors()
            guard loadGeneration == generation else { return }
            guard !Task.isCancelled else {
                loadState = previousLoadState
                return
            }
            let loadedDescriptorsByID = loadedDescriptors.reduce(
                into: [String: PhotoAssetDescriptor]()
            ) { result, descriptor in
                guard descriptor.availability != .unavailable else { return }
                result[descriptor.id] = descriptor
            }
            var loadedDecisions = try repository.decisions()
            let staleAssetIDs = Set(loadedDecisions.compactMap { decision -> String? in
                guard decision.kind == .decideLater || decision.kind == .protect,
                      loadedDescriptorsByID[decision.assetID] == nil else { return nil }
                return decision.assetID
            })
            if !staleAssetIDs.isEmpty {
                do {
                    try repository.removeDecisions(for: staleAssetIDs)
                } catch {
                    loadState = .failed("无法更新失效的整理记录，请重试。")
                    return
                }
                loadedDecisions.removeAll { staleAssetIDs.contains($0.assetID) }
            }

            descriptorsByID = loadedDescriptorsByID
            decisions = loadedDecisions
            rebuildItems()
            hasLoadedSuccessfully = true
            loadState = .loaded
            if !staleAssetIDs.isEmpty {
                reconciliationMessage = "已移除 \(staleAssetIDs.count) 项无法访问的队列记录。"
                onDecisionsChanged?()
            }
        } catch {
            guard loadGeneration == generation else { return }
            guard !Task.isCancelled else {
                loadState = previousLoadState
                return
            }
            loadState = .failed("无法载入整理队列，请重试。")
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

    func deferAgain(assetID: String) {
        do {
            guard let current = try repository.decision(for: assetID),
                  current.kind == .decideLater else {
                try refreshFromRepository()
                return
            }
            let latestQueueTimestamp = try repository.decisions()
                .filter { $0.kind == .decideLater }
                .map(\.createdAt)
                .max() ?? current.createdAt
            let nextOrderedTimestamp = latestQueueTimestamp.addingTimeInterval(0.001)
            let refreshedAt = max(now(), nextOrderedTimestamp)
            let replacement = PhotoDecision(
                assetID: current.assetID,
                kind: .decideLater,
                estimatedBytes: current.estimatedBytes,
                taskID: current.taskID,
                createdAt: refreshedAt,
                isSubmitted: current.isSubmitted
            )
            try repository.save(decision: replacement)
            replaceCachedDecision(replacement)
            actionErrorMessage = nil
            failedAction = nil
            onDecisionsChanged?()
        } catch {
            actionErrorMessage = "无法保存决定，请重试。"
            failedAction = .deferAgain(assetID)
        }
    }

    func unprotect(assetID: String) {
        do {
            guard let current = try repository.decision(for: assetID),
                  current.kind == .protect else {
                try refreshFromRepository()
                return
            }
            try repository.removeDecision(for: assetID)
            decisions.removeAll { $0.assetID == assetID }
            rebuildItems()
            actionErrorMessage = nil
            failedAction = nil
            onDecisionsChanged?()
        } catch {
            actionErrorMessage = "无法取消保护，请重试。"
            failedAction = .unprotect(assetID)
        }
    }

    func retryLastAction() {
        switch failedAction {
        case .deferAgain(let assetID):
            deferAgain(assetID: assetID)
        case .unprotect(let assetID):
            unprotect(assetID: assetID)
        case nil:
            break
        }
    }

    private func replaceCachedDecision(_ replacement: PhotoDecision) {
        decisions.removeAll { $0.assetID == replacement.assetID }
        decisions.append(replacement)
        rebuildItems()
    }

    private func refreshFromRepository() throws {
        decisions = try repository.decisions()
        rebuildItems()
    }

    private func rebuildItems() {
        decideLaterItems = items(for: .decideLater)
        protectedItems = items(for: .protect)
    }

    private func items(for kind: PhotoDecisionKind) -> [DecisionQueueItem] {
        decisions.compactMap { decision in
            guard decision.kind == kind,
                  let descriptor = descriptorsByID[decision.assetID],
                  descriptor.id == decision.assetID else { return nil }
            return DecisionQueueItem(descriptor: descriptor, decision: decision)
        }
        .sorted { first, second in
            if first.decision.createdAt != second.decision.createdAt {
                return first.decision.createdAt < second.decision.createdAt
            }
            return first.id < second.id
        }
    }
}
