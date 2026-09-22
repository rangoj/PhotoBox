import Foundation

nonisolated struct DiagnosisSummary: Equatable, Sendable {
    let taskCount: Int
    let uniqueAssetCount: Int
    let currentPhotoStorageBytes: Int64?
    let estimatedReclaimableBytes: Int64

    init(tasks: [CleanupTask], currentPhotoStorageBytes: Int64? = nil) {
        let qualifyingTasks = tasks.filter { $0.isQualifyingCleanupCandidate && $0.type != .dateBatch }
        taskCount = qualifyingTasks.count
        uniqueAssetCount = Set(qualifyingTasks.flatMap(\.assetIDs)).count
        self.currentPhotoStorageBytes = currentPhotoStorageBytes
        estimatedReclaimableBytes = qualifyingTasks
            .filter { $0.type != .largeVideos }
            .reduce(0) { $0 + $1.estimatedBytes }
    }

    var isHealthy: Bool { taskCount == 0 }
}

nonisolated extension CleanupTask {
    var isQualifyingCleanupCandidate: Bool {
        status == .queued || status == .inProgress || status == .paused
    }
}

nonisolated struct TaskRanker: Sendable {
    func rank(_ tasks: [CleanupTask], now: Date = .now) -> [CleanupTask] {
        tasks.sorted { first, second in
            let firstScore = score(first, now: now)
            let secondScore = score(second, now: now)
            if firstScore != secondScore { return firstScore > secondScore }
            return first.id < second.id
        }
    }

    private func score(_ task: CleanupTask, now: Date) -> Double {
        let riskBase: Double = switch task.risk {
        case .low: 300
        case .medium: 200
        case .high: 100
        }
        let confidence = min(max(task.confidence, 0), 1) * 100
        let skipPenalty = Double(task.skipCount) * 50
        let recentSkipPenalty: Double
        if let lastSkippedAt = task.lastSkippedAt,
           now.timeIntervalSince(lastSkippedAt) < 7 * 86_400 {
            recentSkipPenalty = 25
        } else {
            recentSkipPenalty = 0
        }
        let timePenalty = Double(max(task.estimatedMinutes, 0)) * 2
        let spaceValue = task.estimatedBytes > 0
            ? min(20, log10(Double(task.estimatedBytes) + 1) * 2)
            : 0
        let ageDays = max(0, now.timeIntervalSince(task.createdAt) / 86_400)
        let freshness = max(0, 14 - ageDays) * 0.25
        return riskBase + confidence + spaceValue + freshness
            - skipPenalty - recentSkipPenalty - timePenalty
    }
}

@MainActor
final class TaskLifecycleController {
    private let repository: any TaskRepository

    init(repository: any TaskRepository) {
        self.repository = repository
    }

    func start(taskID: String, at date: Date = .now) throws -> CleanupTask {
        try claimAvailableAssets(taskID: taskID, at: date)
    }

    func resume(taskID: String, at date: Date = .now) throws -> CleanupTask {
        try claimAvailableAssets(taskID: taskID, at: date)
    }

    func pause(taskID: String, at date: Date = .now) throws -> CleanupTask {
        var task = try task(withID: taskID)
        task.status = .paused
        task.ownedAssetIDs = []
        task.updatedAt = date
        try repository.save(task: task)
        return task
    }

    func skip(taskID: String, at date: Date = .now) throws -> CleanupTask {
        var task = try task(withID: taskID)
        task.status = .skipped
        task.ownedAssetIDs = []
        task.skipCount += 1
        task.lastSkippedAt = date
        task.updatedAt = date
        try repository.save(task: task)
        return task
    }

    func complete(taskID: String, at date: Date = .now) throws -> CleanupTask {
        var task = try task(withID: taskID)
        task.status = .completed
        task.ownedAssetIDs = []
        task.updatedAt = date
        try repository.save(task: task)
        return task
    }

    func activeTasks() throws -> [CleanupTask] {
        try repository.tasks().filter { $0.status == .inProgress || $0.status == .paused }
    }

    private func claimAvailableAssets(taskID: String, at date: Date) throws -> CleanupTask {
        let tasks = try repository.tasks()
        guard var task = tasks.first(where: { $0.id == taskID }) else {
            throw TaskLifecycleError.taskNotFound(taskID)
        }
        let ownedByOthers = Set(tasks
            .filter { $0.id != taskID && $0.status == .inProgress }
            .flatMap(\.ownedAssetIDs))
        let decidedByOthers = Set(try repository.decisions()
            .filter { task.type == .dateBatch || ($0.taskID != taskID && !$0.isSubmitted) }
            .map(\.assetID))
        task.ownedAssetIDs = task.assetIDs.filter {
            !ownedByOthers.contains($0) && !decidedByOthers.contains($0)
        }
        task.status = task.ownedAssetIDs.isEmpty ? .queued : .inProgress
        task.updatedAt = date
        try repository.save(task: task)
        return task
    }

    private func task(withID id: String) throws -> CleanupTask {
        guard let task = try repository.tasks().first(where: { $0.id == id }) else {
            throw TaskLifecycleError.taskNotFound(id)
        }
        return task
    }
}

nonisolated enum TaskLifecycleError: Error, Equatable {
    case taskNotFound(String)
}

@MainActor
protocol ComparisonGroupDecisionApplying: AnyObject {
    func applyGroup(_ decisions: [PhotoDecision]) throws
    func completeGroup(_ decisions: [PhotoDecision], taskID: String) throws
}

nonisolated enum ComparisonGroupDecisionError: Error, Equatable {
    case duplicateAssetIDs
}

@MainActor
final class DecisionWorkflow: ComparisonGroupDecisionApplying {
    private let repository: any TaskRepository

    init(repository: any TaskRepository) {
        self.repository = repository
    }

    func apply(_ decision: PhotoDecision) throws {
        let previousDecision = try repository.decision(for: decision.assetID)
        let task = try decision.taskID.flatMap { taskID in
            try repository.tasks().first(where: { $0.id == taskID })
        }
        let undo = DecisionUndoEntry(
            assetID: decision.assetID,
            previousDecision: previousDecision,
            replacementDecision: decision,
            taskID: decision.taskID,
            previousTaskIndex: task?.currentAssetIndex,
            previousTaskStatus: task?.status,
            previousOwnedAssetIDs: task?.ownedAssetIDs
        )
        if var task {
            if task.type == .dateBatch {
                let isOwnPendingDecision = previousDecision?.taskID == task.id
                    && previousDecision?.isSubmitted == false
                guard task.assetIDs.contains(decision.assetID),
                      previousDecision?.isSubmitted != true,
                      previousDecision == nil || isOwnPendingDecision,
                      task.ownedAssetIDs.contains(decision.assetID) || isOwnPendingDecision else {
                    throw DecisionFlowError.noCurrentAsset
                }
            }
            task.ownedAssetIDs.removeAll { $0 == decision.assetID }
            let decided = Set(try repository.decisions().map(\.assetID)).union([decision.assetID])
            let taskIsComplete = task.assetIDs.allSatisfy { decided.contains($0) }
            let decisionIndex = task.assetIDs.firstIndex(of: decision.assetID) ?? task.currentAssetIndex
            if taskIsComplete {
                // Keep a valid cursor so a completed task can still revisit its last photo.
                task.currentAssetIndex = min(max(decisionIndex, 0), max(task.assetIDs.count - 1, 0))
                task.status = .completed
                task.ownedAssetIDs = []
            } else if task.type == .dateBatch {
                let eligibleIDs = Set(task.ownedAssetIDs)
                task.currentAssetIndex = nextUndecidedIndex(
                    after: decisionIndex,
                    assetIDs: task.assetIDs,
                    eligibleIDs: eligibleIDs,
                    decidedIDs: decided
                ) ?? decisionIndex
                if task.ownedAssetIDs.isEmpty { task.status = .paused }
            } else {
                task.currentAssetIndex = nextUndecidedIndex(
                    after: decisionIndex,
                    assetIDs: task.assetIDs,
                    eligibleIDs: nil,
                    decidedIDs: decided
                ) ?? decisionIndex
                task.status = .inProgress
            }
            task.updatedAt = decision.createdAt
            try repository.applySingleDecision(decision, undo: undo, task: task)
        } else {
            try repository.applySingleDecision(decision, undo: undo, task: nil)
        }
    }

    private func nextUndecidedIndex(
        after index: Int,
        assetIDs: [String],
        eligibleIDs: Set<String>?,
        decidedIDs: Set<String>
    ) -> Int? {
        guard !assetIDs.isEmpty else { return nil }
        for offset in 1...assetIDs.count {
            let candidate = (index + offset) % assetIDs.count
            let assetID = assetIDs[candidate]
            if (eligibleIDs == nil || eligibleIDs?.contains(assetID) == true),
               !decidedIDs.contains(assetID) {
                return candidate
            }
        }
        return nil
    }

    func applyGroup(_ decisions: [PhotoDecision]) throws {
        guard Set(decisions.map(\.assetID)).count == decisions.count else {
            throw ComparisonGroupDecisionError.duplicateAssetIDs
        }
        try repository.save(decisions: decisions)
    }

    func completeGroup(_ decisions: [PhotoDecision], taskID: String) throws {
        guard Set(decisions.map(\.assetID)).count == decisions.count else {
            throw ComparisonGroupDecisionError.duplicateAssetIDs
        }
        try repository.completeComparison(taskID: taskID, decisions: decisions)
    }

    func markSubmitted(assetID: String, at date: Date = .now) throws {
        guard let decision = try repository.decision(for: assetID) else { return }
        try repository.save(decision: PhotoDecision(
            assetID: decision.assetID,
            kind: decision.kind,
            estimatedBytes: decision.estimatedBytes,
            targetAlbumID: decision.targetAlbumID,
            taskID: decision.taskID,
            createdAt: date,
            isSubmitted: true
        ))
    }

    func undoLatest() throws -> DecisionUndoOutcome {
        guard let undo = try repository.latestUndo() else { return .nothingToUndo }
        if try repository.decision(for: undo.assetID)?.isSubmitted == true {
            return .requiresRecentlyDeleted
        }

        if let previousDecision = undo.previousDecision {
            try repository.save(decision: previousDecision)
        } else {
            try repository.removeDecision(for: undo.assetID)
        }
        if let taskID = undo.taskID,
           let previousTaskIndex = undo.previousTaskIndex,
           var task = try repository.tasks().first(where: { $0.id == taskID }) {
            task.currentAssetIndex = previousTaskIndex
            task.status = undo.previousTaskStatus ?? .inProgress
            let ownedByOthers = Set(try repository.tasks()
                .filter { $0.id != taskID && $0.status == .inProgress }
                .flatMap(\.ownedAssetIDs))
            task.ownedAssetIDs = (undo.previousOwnedAssetIDs
                ?? Array(task.assetIDs.dropFirst(previousTaskIndex)))
                .filter { !ownedByOthers.contains($0) }
            task.updatedAt = .now
            try repository.save(task: task)
        }
        try repository.removeUndo(id: undo.id)
        return .restored
    }

    func currentSummary(elapsedSeconds: TimeInterval) throws -> CleanupSummary {
        CleanupSummary(decisions: try repository.decisions(), elapsedSeconds: elapsedSeconds)
    }
}

extension DecisionWorkflow: SingleDecisionApplying {}
