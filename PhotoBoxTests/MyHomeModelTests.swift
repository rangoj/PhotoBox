import Foundation
import Testing
@testable import PhotoBox

@MainActor
struct MyHomeModelTests {
    @Test("Only distinct successful live deletions count as real deletions")
    func confirmedDeletionsOnly() {
        let snapshot = MyHomeSnapshot(tasks: [], decisions: [
            PhotoDecision(assetID: "candidate", kind: .deleteCandidate)
        ], summaries: [], transactions: [
            deletion("live", ids: ["a", "a"], backend: .live),
            deletion("retry", ids: ["a"], backend: .live),
            deletion("simulation", ids: ["b"], backend: .simulated),
            deletion("legacy", ids: ["c"], backend: nil),
            MutationTransaction(id: "failed", operation: .delete,
                items: [.init(assetID: "d", state: .failed)], completedAt: .now, backendMode: .live)
        ])
        let projection = MyHomeProjection(snapshot: snapshot)
        #expect(projection.deletedCount == 1)
        #expect(projection.history.contains { $0.detail.contains("模拟删除") })
        #expect(projection.history.contains { $0.detail.contains("模式未知") })
    }

    @Test("History keeps candidates distinct and orders days using the injected calendar")
    func historyDatesAndCandidateLabels() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        let beforeMidnight = calendar.date(from: DateComponents(year: 2026, month: 9, day: 14))!
            .addingTimeInterval(-1)
        let afterMidnight = beforeMidnight.addingTimeInterval(2)
        let summary = CleanupSummary(decisions: [
            PhotoDecision(assetID: "candidate", kind: .deleteCandidate)
        ], elapsedSeconds: nil, createdAt: beforeMidnight)
        let transaction = MutationTransaction(id: "next", operation: .delete,
            items: [.init(assetID: "a", state: .succeeded)],
            createdAt: afterMidnight, completedAt: afterMidnight, backendMode: .live)
        let projection = MyHomeProjection(snapshot: .init(tasks: [], decisions: [],
            summaries: [summary], transactions: [transaction]))
        #expect(projection.history.first?.id == "transaction-next")
        #expect(projection.history.last?.detail.contains("待删除 1 张") == true)
        #expect(projection.history.last?.detail.contains("已删除") == false)
        #expect(projection.days(calendar: calendar).first?.date == calendar.startOfDay(for: afterMidnight))
        #expect(projection.days(calendar: calendar).count == 2)
    }

    @Test("Processed total retains the existing projection without double-counting summaries")
    func processedSemantics() {
        let decisions = [PhotoDecision(assetID: "keep", kind: .keep)]
        let snapshot = MyHomeSnapshot(tasks: [], decisions: decisions,
            summaries: [CleanupSummary(decisions: decisions, elapsedSeconds: nil)], transactions: [])
        #expect(MyHomeProjection(snapshot: snapshot).processedCount == 1)
    }

    @Test("Read failure hides totals, retry recovers and clearing history reloads zero")
    func readFailureRetryAndClear() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        try repository.save(decision: .init(assetID: "keep", kind: .keep))
        let readState = MyHomeReadState()
        let model = MyHomeModel(read: {
            if readState.shouldFail { throw CocoaError(.fileReadCorruptFile) }
            return try MyHomeSnapshot(repository: repository)
        })
        await model.load()
        #expect(model.projection == nil)
        #expect(model.errorMessage != nil)
        readState.shouldFail = false
        await model.load()
        #expect(model.projection?.processedCount == 1)
        #expect(model.errorMessage == nil)
        #expect(try repository.decisions().count == 1)
        readState.shouldFail = true
        await model.load()
        #expect(model.projection == nil)
        #expect(model.errorMessage != nil)
        readState.shouldFail = false
        await model.load()
        #expect(model.projection?.processedCount == 1)
        try repository.clearHistory()
        await model.load()
        #expect(model.projection?.processedCount == 0)
        #expect(model.projection?.deletedCount == 0)
        #expect(model.projection?.history.isEmpty == true)
    }

    private func deletion(_ id: String, ids: [String], backend: MutationBackendMode?) -> MutationTransaction {
        MutationTransaction(id: id, operation: .delete,
            items: ids.map { .init(assetID: $0, state: .succeeded) }, completedAt: .now, backendMode: backend)
    }
}

@MainActor
private final class MyHomeReadState {
    var shouldFail = true
}
