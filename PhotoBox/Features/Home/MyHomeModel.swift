import Foundation
import Observation

nonisolated struct MyHomeSnapshot: Sendable {
    let tasks: [CleanupTask]
    let decisions: [PhotoDecision]
    let summaries: [CleanupSummary]
    let transactions: [MutationTransaction]

    @MainActor
    init(repository: any TaskRepository) throws {
        tasks = try repository.tasks()
        decisions = try repository.decisions()
        summaries = try repository.summaries()
        transactions = try repository.transactions()
    }

    init(tasks: [CleanupTask], decisions: [PhotoDecision], summaries: [CleanupSummary], transactions: [MutationTransaction]) {
        self.tasks = tasks
        self.decisions = decisions
        self.summaries = summaries
        self.transactions = transactions
    }
}

nonisolated struct MyHistoryEntry: Identifiable, Equatable, Sendable {
    let id: String
    let date: Date
    let title: String
    let detail: String
}

nonisolated struct MyHistoryDay: Identifiable, Sendable {
    var id: Date { date }
    let date: Date
    let entries: [MyHistoryEntry]
}

nonisolated struct MyHomeProjection: Sendable {
    let processedCount: Int
    let deletedCount: Int
    let history: [MyHistoryEntry]

    init(snapshot: MyHomeSnapshot) {
        processedCount = StatisticsProjection.project(checkpoint: nil, tasks: snapshot.tasks,
            decisions: snapshot.decisions, transactions: snapshot.transactions,
            summaries: snapshot.summaries).processedItemCount
        let transactions = Dictionary(snapshot.transactions.map { ($0.id, $0) }, uniquingKeysWith: { first, second in
            (first.completedAt ?? first.createdAt) > (second.completedAt ?? second.createdAt) ? first : second
        }).values
        deletedCount = Set(transactions.filter { $0.operation == .delete && $0.backendMode == .live }
            .flatMap(\.items).filter { $0.state == .succeeded }.map(\.assetID)).count

        let summaries = Dictionary(snapshot.summaries.map { ($0.id, $0) }, uniquingKeysWith: { first, second in
            first.createdAt > second.createdAt ? first : second
        }).values
        let taskTitles = Dictionary(snapshot.tasks.map { (CleanupSummary.identifier(forTaskID: $0.id), $0.title) },
            uniquingKeysWith: { _, second in second })
        var entries = summaries.map { summary in
            let count = summary.keptCount + summary.archivedCount + summary.protectedCount
                + summary.deferredCount + summary.deleteCandidateCount
            let candidateDetail = summary.deleteCandidateCount > 0 ? " · 待删除 \(summary.deleteCandidateCount) 张" : ""
            return MyHistoryEntry(id: "summary-\(summary.id)", date: summary.createdAt,
                title: taskTitles[summary.id] ?? "整理照片", detail: "整理 \(count) 张\(candidateDetail)")
        }
        entries += transactions.compactMap { transaction -> MyHistoryEntry? in
            guard transaction.operation == .delete, let completedAt = transaction.completedAt else { return nil }
            let count = Set(transaction.items.filter { $0.state == .succeeded }.map(\.assetID)).count
            let label: String = switch transaction.backendMode {
            case .live: "已删除"
            case .simulated: "模拟删除"
            case nil: "删除记录（模式未知）"
            }
            let unresolved = transaction.items.count { [.failed, .cancelled, .pending, .submitted].contains($0.state) }
            let detail = "\(label) \(count) 张" + (unresolved > 0 ? " · 未完成 \(unresolved) 张" : "")
            return MyHistoryEntry(id: "transaction-\(transaction.id)", date: completedAt,
                title: "删除复核", detail: detail)
        }
        history = entries.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }

    func days(calendar: Calendar = .current) -> [MyHistoryDay] {
        Dictionary(grouping: history, by: { calendar.startOfDay(for: $0.date) })
            .map { MyHistoryDay(date: $0.key, entries: $0.value) }
            .sorted { $0.date > $1.date }
    }
}

@MainActor
@Observable
final class MyHomeModel {
    private let read: @MainActor () throws -> MyHomeSnapshot
    private var generation = 0
    private(set) var projection: MyHomeProjection?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    init(repository: (any TaskRepository)?) {
        read = {
            guard let repository else { throw CocoaError(.fileReadUnknown) }
            return try MyHomeSnapshot(repository: repository)
        }
    }

    init(read: @escaping @MainActor () throws -> MyHomeSnapshot) { self.read = read }

    func load() async {
        generation += 1
        let current = generation
        isLoading = true
        await Task.yield()
        guard current == generation else { return }
        defer { isLoading = false }
        guard !Task.isCancelled else { return }
        do {
            projection = MyHomeProjection(snapshot: try read())
            errorMessage = nil
        } catch {
            projection = nil
            errorMessage = "无法读取整理记录，请重试。"
        }
    }
}
