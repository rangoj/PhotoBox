import Foundation
import Observation

@MainActor
@Observable
final class StatisticsModel {
    enum State: Equatable {
        case loading
        case noHistory
        case partial
        case ready
        case failure(String)

        var isFailure: Bool {
            if case .failure = self { return true }
            return false
        }
    }

    private let repository: (any TaskRepository)?

    @ObservationIgnored
    private var loadGeneration = UUID()

    private(set) var state: State = .loading
    private(set) var projection: StatisticsProjection?
    private(set) var isClearingHistory = false
    private(set) var clearFailureMessage: String?

    init(repository: (any TaskRepository)?) {
        self.repository = repository
    }

    func load() async {
        let generation = UUID()
        loadGeneration = generation
        if projection == nil {
            state = .loading
        }
        await Task.yield()

        guard let repository else {
            guard loadGeneration == generation else { return }
            state = .failure("无法打开本地整理记录")
            return
        }

        do {
            let checkpoint = try repository.latestCheckpoint()
            let tasks = try repository.tasks()
            let decisions = try repository.decisions()
            let transactions = try repository.transactions()
            let summaries = try repository.summaries()
            let baseline: Set<String>?
            switch try repository.initialCompletedCheckpoint() {
            case .found(let checkpoint): baseline = Set(checkpoint.processedAssetIDs)
            case .missing: baseline = nil
            case .corrupt: throw StatisticsModelError.corruptInitialCheckpoint
            }
            await Task.yield()
            guard loadGeneration == generation else { return }

            let isEmpty = checkpoint == nil
                && tasks.isEmpty
                && decisions.isEmpty
                && transactions.isEmpty
                && summaries.isEmpty
            projection = isEmpty ? nil : StatisticsProjection.project(
                checkpoint: checkpoint,
                baselineAssetIDs: baseline,
                tasks: tasks,
                decisions: decisions,
                transactions: transactions,
                summaries: summaries
            )
            state = isEmpty ? .noHistory : (checkpoint == nil && summaries.isEmpty ? .partial : .ready)
            clearFailureMessage = nil
        } catch {
            guard loadGeneration == generation else { return }
            state = .failure(error.localizedDescription)
        }
    }

    func clearHistory() -> Bool {
        guard !isClearingHistory, let repository else { return false }
        isClearingHistory = true
        defer { isClearingHistory = false }
        do {
            try repository.clearHistory()
            loadGeneration = UUID()
            projection = nil
            state = .noHistory
            clearFailureMessage = nil
            return true
        } catch {
            clearFailureMessage = error.localizedDescription
            return false
        }
    }

    func dismissClearFailure() {
        clearFailureMessage = nil
    }
}

private enum StatisticsModelError: LocalizedError {
    case corruptInitialCheckpoint

    var errorDescription: String? { "初始扫描记录已损坏" }
}
