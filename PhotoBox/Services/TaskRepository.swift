import Foundation
import SwiftData

@MainActor
protocol DecisionQueuePersisting: AnyObject {
    func save(decision: PhotoDecision) throws
    func removeDecision(for assetID: String) throws
    func removeDecisions(for assetIDs: Set<String>) throws
    func decision(for assetID: String) throws -> PhotoDecision?
    func decisions() throws -> [PhotoDecision]
}

extension DecisionQueuePersisting {
    func removeDecisions(for assetIDs: Set<String>) throws {
        for assetID in assetIDs.sorted() {
            try removeDecision(for: assetID)
        }
    }
}

@MainActor
protocol TaskRepository: DecisionQueuePersisting {
    func save(checkpoint: ScanCheckpoint) throws
    func latestCheckpoint() throws -> ScanCheckpoint?
    func latestCompletedCheckpoint() throws -> ScanCheckpoint?
    func initialCompletedCheckpoint() throws -> RepositoryLookup<ScanCheckpoint>
    func save(task: CleanupTask) throws
    func save(tasks: [CleanupTask]) throws
    func tasks() throws -> [CleanupTask]
    func applySingleDecision(_ decision: PhotoDecision, undo: DecisionUndoEntry, task: CleanupTask?) throws
    func save(decisions: [PhotoDecision]) throws
    func completeComparison(taskID: String, decisions: [PhotoDecision]) throws
    func completeArchive(
        transaction: MutationTransaction,
        decision: PhotoDecision,
        recentAlbumIDs: [String]
    ) throws
    func save(undo: DecisionUndoEntry) throws
    func latestUndo() throws -> DecisionUndoEntry?
    func removeUndo(id: UUID) throws
    func save(transaction: MutationTransaction) throws
    func transactions() throws -> [MutationTransaction]
    func transaction(id: String) throws -> RepositoryLookup<MutationTransaction>
    func save(settings: WorkflowSettings) throws
    func settings() throws -> WorkflowSettings
    func save(summary: CleanupSummary) throws
    func summaries() throws -> [CleanupSummary]
    func summary(id: UUID) throws -> RepositoryLookup<CleanupSummary>
    func reconcile(availableAssetIDs: Set<String>) throws
    func clearHistory() throws
}

nonisolated enum RepositoryLookup<Value: Sendable>: Sendable {
    case found(Value)
    case missing
    case corrupt
}

nonisolated enum TaskRepositoryCorruptionError: LocalizedError, Equatable, Sendable {
    case checkpoint(String)
    case task(String)
    case decision(String)

    var errorDescription: String? {
        switch self {
        case .checkpoint: "本地扫描基线记录已损坏，无法安全生成每周整理。"
        case .task: "本地整理任务记录已损坏，无法安全生成每周整理。"
        case .decision: "本地照片决定记录已损坏，无法安全生成每周整理。"
        }
    }
}

nonisolated enum StatisticsRepositoryCorruptionError: LocalizedError, Equatable, Sendable {
    case summary(String)
    case transaction(String)

    var errorDescription: String? {
        switch self {
        case .summary: "本地整理汇总记录已损坏，无法安全显示统计。"
        case .transaction: "本地整理事务记录已损坏，无法安全显示统计。"
        }
    }
}

nonisolated enum TaskRepositoryBatchError: LocalizedError, Equatable, Sendable {
    case atomicPersistenceUnsupported

    var errorDescription: String? {
        "当前本地记录存储不支持原子任务写入，未保存本周整理。"
    }
}

extension TaskRepository {
    func save(tasks: [CleanupTask]) throws {
        guard tasks.isEmpty else { throw TaskRepositoryBatchError.atomicPersistenceUnsupported }
    }

    func latestCompletedCheckpoint() throws -> ScanCheckpoint? {
        guard let checkpoint = try latestCheckpoint(), checkpoint.stage == .completed else {
            return nil
        }
        return checkpoint
    }

    func initialCompletedCheckpoint() throws -> RepositoryLookup<ScanCheckpoint> {
        guard let checkpoint = try latestCompletedCheckpoint() else { return .missing }
        return .found(checkpoint)
    }

    func transaction(id: String) throws -> RepositoryLookup<MutationTransaction> {
        if let transaction = try transactions().first(where: { $0.id == id }) {
            return .found(transaction)
        }
        return .missing
    }

    func summary(id: UUID) throws -> RepositoryLookup<CleanupSummary> {
        if let summary = try summaries().first(where: { $0.id == id }) {
            return .found(summary)
        }
        return .missing
    }
}

@Model
final class PersistedScanCheckpoint {
    @Attribute(.unique) var identifier: String
    var payload: Data
    var updatedAt: Date

    init(_ checkpoint: ScanCheckpoint) throws {
        identifier = checkpoint.id
        payload = try JSONEncoder().encode(checkpoint)
        updatedAt = checkpoint.updatedAt
    }

    var value: ScanCheckpoint? { try? JSONDecoder().decode(ScanCheckpoint.self, from: payload) }

    func update(with checkpoint: ScanCheckpoint) throws {
        payload = try JSONEncoder().encode(checkpoint)
        updatedAt = checkpoint.updatedAt
    }
}

@Model
final class PersistedCleanupTask {
    @Attribute(.unique) var identifier: String
    var payload: Data
    var createdAt: Date

    init(_ task: CleanupTask) throws {
        identifier = task.id
        payload = try JSONEncoder().encode(task)
        createdAt = task.createdAt
    }

    var value: CleanupTask? { try? JSONDecoder().decode(CleanupTask.self, from: payload) }

    func update(with task: CleanupTask) throws {
        payload = try JSONEncoder().encode(task)
        createdAt = task.createdAt
    }
}

@Model
final class PersistedPhotoDecision {
    @Attribute(.unique) var assetID: String
    var kindRawValue: String
    var estimatedBytes: Int64
    var targetAlbumID: String?
    var taskID: String?
    var createdAt: Date
    var isSubmitted: Bool

    init(_ decision: PhotoDecision) {
        assetID = decision.assetID
        kindRawValue = decision.kind.rawValue
        estimatedBytes = decision.estimatedBytes
        targetAlbumID = decision.targetAlbumID
        taskID = decision.taskID
        createdAt = decision.createdAt
        isSubmitted = decision.isSubmitted
    }

    var value: PhotoDecision? {
        guard let kind = PhotoDecisionKind(rawValue: kindRawValue) else { return nil }
        return PhotoDecision(
            assetID: assetID,
            kind: kind,
            estimatedBytes: estimatedBytes,
            targetAlbumID: targetAlbumID,
            taskID: taskID,
            createdAt: createdAt,
            isSubmitted: isSubmitted
        )
    }

    func update(with decision: PhotoDecision) {
        kindRawValue = decision.kind.rawValue
        estimatedBytes = decision.estimatedBytes
        targetAlbumID = decision.targetAlbumID
        taskID = decision.taskID
        createdAt = decision.createdAt
        isSubmitted = decision.isSubmitted
    }
}

@Model
final class PersistedDecisionUndo {
    @Attribute(.unique) var identifier: String
    var payload: Data
    var createdAt: Date

    init(_ undo: DecisionUndoEntry) throws {
        identifier = undo.id.uuidString
        payload = try JSONEncoder().encode(undo)
        createdAt = undo.createdAt
    }

    var value: DecisionUndoEntry? {
        try? JSONDecoder().decode(DecisionUndoEntry.self, from: payload)
    }
}

@Model
final class PersistedCleanupSummary {
    @Attribute(.unique) var identifier: String
    var keptCount: Int
    var deleteCandidateCount: Int
    var archivedCount: Int
    var protectedCount: Int
    var deferredCount: Int
    var estimatedReclaimableBytes: Int64
    var elapsedSeconds: TimeInterval
    var createdAt: Date

    init(_ summary: CleanupSummary) {
        identifier = summary.id.uuidString
        keptCount = summary.keptCount
        deleteCandidateCount = summary.deleteCandidateCount
        archivedCount = summary.archivedCount
        protectedCount = summary.protectedCount
        deferredCount = summary.deferredCount
        estimatedReclaimableBytes = summary.estimatedReclaimableBytes
        elapsedSeconds = summary.elapsedSeconds ?? 0
        createdAt = summary.createdAt
    }

    var value: CleanupSummary? {
        guard let id = UUID(uuidString: identifier),
              keptCount >= 0,
              deleteCandidateCount >= 0,
              archivedCount >= 0,
              protectedCount >= 0,
              deferredCount >= 0,
              estimatedReclaimableBytes >= 0,
              elapsedSeconds >= 0,
              elapsedSeconds.isFinite else { return nil }
        return CleanupSummary(
            id: id,
            keptCount: keptCount,
            deleteCandidateCount: deleteCandidateCount,
            archivedCount: archivedCount,
            protectedCount: protectedCount,
            deferredCount: deferredCount,
            estimatedReclaimableBytes: estimatedReclaimableBytes,
            elapsedSeconds: elapsedSeconds == 0 ? nil : elapsedSeconds,
            createdAt: createdAt
        )
    }

    func update(with summary: CleanupSummary) {
        keptCount = summary.keptCount
        deleteCandidateCount = summary.deleteCandidateCount
        archivedCount = summary.archivedCount
        protectedCount = summary.protectedCount
        deferredCount = summary.deferredCount
        estimatedReclaimableBytes = summary.estimatedReclaimableBytes
        elapsedSeconds = summary.elapsedSeconds ?? 0
        createdAt = summary.createdAt
    }
}

@Model
final class PersistedMutationTransaction {
    @Attribute(.unique) var identifier: String
    var payload: Data
    var createdAt: Date

    init(_ transaction: MutationTransaction) throws {
        identifier = transaction.id
        payload = try JSONEncoder().encode(transaction)
        createdAt = transaction.createdAt
    }

    var value: MutationTransaction? {
        try? JSONDecoder().decode(MutationTransaction.self, from: payload)
    }

    func update(with transaction: MutationTransaction) throws {
        payload = try JSONEncoder().encode(transaction)
        createdAt = transaction.createdAt
    }
}

@Model
final class PersistedWorkflowSettings {
    @Attribute(.unique) var identifier: String
    var payload: Data

    init(_ settings: WorkflowSettings) throws {
        identifier = "current"
        payload = try JSONEncoder().encode(settings)
    }

    var value: WorkflowSettings? {
        try? JSONDecoder().decode(WorkflowSettings.self, from: payload)
    }

    func update(with settings: WorkflowSettings) throws {
        payload = try JSONEncoder().encode(settings)
    }
}

enum PhotoBoxSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            PersistedScanCheckpoint.self,
            PersistedCleanupTask.self,
            PersistedPhotoDecision.self,
            PersistedDecisionUndo.self,
            PersistedMutationTransaction.self,
            PersistedWorkflowSettings.self,
            PersistedCleanupSummary.self
        ]
    }
}

@MainActor
final class SwiftDataTaskRepository: TaskRepository {
    static let schemaVersion = "1.0.0"

    private let container: ModelContainer
    private let clearHistoryInterruption: () throws -> Void
    private var context: ModelContext { container.mainContext }

    init(
        inMemory: Bool = false,
        clearHistoryInterruption: @escaping () throws -> Void = {}
    ) throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        container = try ModelContainer(
            for: Schema(versionedSchema: PhotoBoxSchemaV1.self),
            configurations: [configuration]
        )
        self.clearHistoryInterruption = clearHistoryInterruption
    }

    init(
        container: ModelContainer,
        clearHistoryInterruption: @escaping () throws -> Void = {}
    ) {
        self.container = container
        self.clearHistoryInterruption = clearHistoryInterruption
    }

    func save(checkpoint: ScanCheckpoint) throws {
        if let existing = try persistedCheckpoint(for: checkpoint.id) {
            try existing.update(with: checkpoint)
        } else {
            context.insert(try PersistedScanCheckpoint(checkpoint))
        }
        try context.save()
    }

    func latestCheckpoint() throws -> ScanCheckpoint? {
        let descriptor = FetchDescriptor<PersistedScanCheckpoint>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        guard let record = try context.fetch(descriptor).first else { return nil }
        guard let checkpoint = record.value else {
            throw TaskRepositoryCorruptionError.checkpoint(record.identifier)
        }
        return checkpoint
    }

    func latestCompletedCheckpoint() throws -> ScanCheckpoint? {
        let descriptor = FetchDescriptor<PersistedScanCheckpoint>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        for record in try context.fetch(descriptor) {
            guard let checkpoint = record.value else {
                throw TaskRepositoryCorruptionError.checkpoint(record.identifier)
            }
            if checkpoint.stage == .completed { return checkpoint }
        }
        return nil
    }

    func initialCompletedCheckpoint() throws -> RepositoryLookup<ScanCheckpoint> {
        let descriptor = FetchDescriptor<PersistedScanCheckpoint>(
            sortBy: [SortDescriptor(\.updatedAt, order: .forward)]
        )
        for record in try context.fetch(descriptor) {
            guard let checkpoint = record.value else { return .corrupt }
            if checkpoint.stage == .completed { return .found(checkpoint) }
        }
        return .missing
    }

    func save(task: CleanupTask) throws {
        try save(tasks: [task])
    }

    func save(tasks: [CleanupTask]) throws {
        do {
            for task in tasks {
                if let existing = try persistedTask(for: task.id) {
                    try existing.update(with: task)
                } else {
                    context.insert(try PersistedCleanupTask(task))
                }
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func tasks() throws -> [CleanupTask] {
        let records = try context.fetch(FetchDescriptor<PersistedCleanupTask>())
        let values = try records.map { record in
            guard let value = record.value else {
                throw TaskRepositoryCorruptionError.task(record.identifier)
            }
            return value
        }
        return values.sorted { $0.createdAt < $1.createdAt }
    }

    func save(decision: PhotoDecision) throws {
        do {
            if let existing = try persistedDecision(for: decision.assetID) {
                existing.update(with: decision)
            } else {
                context.insert(PersistedPhotoDecision(decision))
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func applySingleDecision(_ decision: PhotoDecision, undo: DecisionUndoEntry, task: CleanupTask?) throws {
        do {
            try context.delete(model: PersistedDecisionUndo.self)
            context.insert(try PersistedDecisionUndo(undo))
            if let existing = try persistedDecision(for: decision.assetID) {
                existing.update(with: decision)
            } else {
                context.insert(PersistedPhotoDecision(decision))
            }
            if let task,
               let record = try persistedTask(for: task.id) {
                try record.update(with: task)
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func save(decisions: [PhotoDecision]) throws {
        do {
            for decision in decisions {
                if let existing = try persistedDecision(for: decision.assetID) {
                    existing.update(with: decision)
                } else {
                    context.insert(PersistedPhotoDecision(decision))
                }
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func completeComparison(taskID: String, decisions: [PhotoDecision]) throws {
        guard Set(decisions.map(\.assetID)).count == decisions.count else {
            throw ComparisonGroupDecisionError.duplicateAssetIDs
        }
        do {
            guard let record = try persistedTask(for: taskID), var task = record.value else {
                throw TaskLifecycleError.taskNotFound(taskID)
            }
            for decision in decisions {
                if let existing = try persistedDecision(for: decision.assetID) {
                    existing.update(with: decision)
                } else {
                    context.insert(PersistedPhotoDecision(decision))
                }
            }
            task.status = .completed
            task.ownedAssetIDs = []
            task.currentAssetIndex = task.assetIDs.count
            task.updatedAt = decisions.map(\.createdAt).max() ?? .now
            try record.update(with: task)
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func completeArchive(
        transaction: MutationTransaction,
        decision: PhotoDecision,
        recentAlbumIDs: [String]
    ) throws {
        guard transaction.operation == .archive,
              decision.kind == .archive,
              decision.isSubmitted,
              transaction.targetAlbumID == decision.targetAlbumID,
              transaction.items.contains(where: {
                  $0.assetID == decision.assetID && $0.state == .succeeded
              }) else {
            throw ArchiveCompletionError.invalidSuccess
        }

        do {
            if let existingTransaction = try persistedTransaction(for: transaction.id) {
                try existingTransaction.update(with: transaction)
            } else {
                context.insert(try PersistedMutationTransaction(transaction))
            }

            let existingDecision = try persistedDecision(for: decision.assetID)?.value
            let alreadyApplied = existingDecision?.kind == .archive
                && existingDecision?.targetAlbumID == decision.targetAlbumID
                && existingDecision?.taskID == decision.taskID
                && existingDecision?.isSubmitted == true

            if !alreadyApplied {
                if let taskID = decision.taskID {
                    guard let taskRecord = try persistedTask(for: taskID),
                          var task = taskRecord.value else {
                        throw ArchiveCompletionError.taskNotFound(taskID)
                    }
                    guard task.assetIDs.indices.contains(task.currentAssetIndex),
                          task.assetIDs[task.currentAssetIndex] == decision.assetID else {
                        throw ArchiveCompletionError.assetPositionChanged(decision.assetID)
                    }
                    task.ownedAssetIDs.removeAll { $0 == decision.assetID }
                    if task.type == .dateBatch {
                        let remainingIDs = Set(task.ownedAssetIDs)
                        task.currentAssetIndex = task.assetIDs.firstIndex(where: { remainingIDs.contains($0) })
                            ?? task.assetIDs.count
                        let decidedIDs = Set(try decisions().map(\.assetID)).union([decision.assetID])
                        if task.assetIDs.allSatisfy({ decidedIDs.contains($0) }) {
                            task.status = .completed
                            task.ownedAssetIDs = []
                        } else if task.ownedAssetIDs.isEmpty {
                            task.status = .paused
                        }
                    } else {
                        task.currentAssetIndex += 1
                        if task.currentAssetIndex == task.assetIDs.count {
                            task.status = .completed
                            task.ownedAssetIDs = []
                        }
                    }
                    task.updatedAt = decision.createdAt
                    try taskRecord.update(with: task)
                }

                try context.delete(model: PersistedDecisionUndo.self)
                if let existing = try persistedDecision(for: decision.assetID) {
                    existing.update(with: decision)
                } else {
                    context.insert(PersistedPhotoDecision(decision))
                }
                if let existingSettings = try context.fetch(FetchDescriptor<PersistedWorkflowSettings>()).first {
                    var currentSettings = existingSettings.value ?? .defaults
                    currentSettings.recentAlbumIDs = recentAlbumIDs
                    try existingSettings.update(with: currentSettings)
                } else {
                    var currentSettings = WorkflowSettings.defaults
                    currentSettings.recentAlbumIDs = recentAlbumIDs
                    context.insert(try PersistedWorkflowSettings(currentSettings))
                }
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func decision(for assetID: String) throws -> PhotoDecision? {
        try persistedDecision(for: assetID)?.value
    }

    func removeDecision(for assetID: String) throws {
        do {
            if let record = try persistedDecision(for: assetID) {
                context.delete(record)
                try context.save()
            }
        } catch {
            context.rollback()
            throw error
        }
    }

    func removeDecisions(for assetIDs: Set<String>) throws {
        guard !assetIDs.isEmpty else { return }
        do {
            for record in try context.fetch(FetchDescriptor<PersistedPhotoDecision>())
            where assetIDs.contains(record.assetID) {
                context.delete(record)
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func decisions() throws -> [PhotoDecision] {
        let records = try context.fetch(FetchDescriptor<PersistedPhotoDecision>())
        let values = try records.map { record in
            guard let value = record.value else {
                throw TaskRepositoryCorruptionError.decision(record.assetID)
            }
            return value
        }
        return values.sorted { $0.createdAt < $1.createdAt }
    }

    func save(undo: DecisionUndoEntry) throws {
        try context.delete(model: PersistedDecisionUndo.self)
        context.insert(try PersistedDecisionUndo(undo))
        try context.save()
    }

    func latestUndo() throws -> DecisionUndoEntry? {
        let descriptor = FetchDescriptor<PersistedDecisionUndo>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try context.fetch(descriptor).first?.value
    }

    func removeUndo(id: UUID) throws {
        let identifier = id.uuidString
        let descriptor = FetchDescriptor<PersistedDecisionUndo>(
            predicate: #Predicate { $0.identifier == identifier }
        )
        if let record = try context.fetch(descriptor).first {
            context.delete(record)
            try context.save()
        }
    }

    func save(summary: CleanupSummary) throws {
        do {
            let identifier = summary.id.uuidString
            let descriptor = FetchDescriptor<PersistedCleanupSummary>(
                predicate: #Predicate { $0.identifier == identifier }
            )
            let existing = try context.fetch(descriptor).first
            if let existing {
                existing.update(with: summary)
            } else {
                context.insert(PersistedCleanupSummary(summary))
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func summaries() throws -> [CleanupSummary] {
        let records = try context.fetch(FetchDescriptor<PersistedCleanupSummary>())
        return try records.map { record in
            guard let value = record.value else {
                throw StatisticsRepositoryCorruptionError.summary(record.identifier)
            }
            return value
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    func summary(id: UUID) throws -> RepositoryLookup<CleanupSummary> {
        let identifier = id.uuidString
        let descriptor = FetchDescriptor<PersistedCleanupSummary>(
            predicate: #Predicate { $0.identifier == identifier }
        )
        guard let record = try context.fetch(descriptor).first else { return .missing }
        guard let value = record.value else { return .corrupt }
        return .found(value)
    }

    func save(transaction: MutationTransaction) throws {
        if let existing = try persistedTransaction(for: transaction.id) {
            try existing.update(with: transaction)
        } else {
            context.insert(try PersistedMutationTransaction(transaction))
        }
        try context.save()
    }

    func transactions() throws -> [MutationTransaction] {
        let records = try context.fetch(FetchDescriptor<PersistedMutationTransaction>())
        return try records.map { record in
            guard let value = record.value else {
                throw StatisticsRepositoryCorruptionError.transaction(record.identifier)
            }
            return value
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    func transaction(id: String) throws -> RepositoryLookup<MutationTransaction> {
        guard let record = try persistedTransaction(for: id) else { return .missing }
        guard let value = record.value else { return .corrupt }
        return .found(value)
    }

    func save(settings: WorkflowSettings) throws {
        do {
            if let existing = try context.fetch(FetchDescriptor<PersistedWorkflowSettings>()).first {
                try existing.update(with: settings)
            } else {
                context.insert(try PersistedWorkflowSettings(settings))
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func settings() throws -> WorkflowSettings {
        try context.fetch(FetchDescriptor<PersistedWorkflowSettings>()).first?.value ?? .defaults
    }

    func reconcile(availableAssetIDs: Set<String>) throws {
        for record in try context.fetch(FetchDescriptor<PersistedPhotoDecision>())
        where !availableAssetIDs.contains(record.assetID) {
            context.delete(record)
        }

        for record in try context.fetch(FetchDescriptor<PersistedCleanupTask>()) {
            guard var task = record.value else { continue }
            if task.type == .dateBatch {
                task.ownedAssetIDs.removeAll { !availableAssetIDs.contains($0) }
                if task.status == .inProgress {
                    let remainingIDs = Set(task.ownedAssetIDs)
                    task.currentAssetIndex = task.assetIDs.firstIndex(where: { remainingIDs.contains($0) })
                        ?? task.assetIDs.count
                    if task.ownedAssetIDs.isEmpty { task.status = .paused }
                }
                try record.update(with: task)
                continue
            }
            task.assetIDs.removeAll { !availableAssetIDs.contains($0) }
            task.ownedAssetIDs.removeAll { !availableAssetIDs.contains($0) }
            if task.assetIDs.isEmpty {
                task.ownedAssetIDs = []
                task.currentAssetIndex = 0
                task.status = .invalid
            } else {
                task.currentAssetIndex = min(task.currentAssetIndex, task.assetIDs.count)
            }
            try record.update(with: task)
        }

        for record in try context.fetch(FetchDescriptor<PersistedMutationTransaction>()) {
            guard var transaction = record.value else { continue }
            for index in transaction.items.indices
            where !availableAssetIDs.contains(transaction.items[index].assetID)
                && transaction.items[index].state == .pending {
                transaction.items[index].state = .stale
            }
            try record.update(with: transaction)
        }
        try context.save()
    }

    func clearHistory() throws {
        do {
            try deleteAll(PersistedScanCheckpoint.self)
            try clearHistoryInterruption()
            try deleteAll(PersistedCleanupTask.self)
            try deleteAll(PersistedPhotoDecision.self)
            try deleteAll(PersistedDecisionUndo.self)
            try deleteAll(PersistedMutationTransaction.self)
            try deleteAll(PersistedWorkflowSettings.self)
            try deleteAll(PersistedCleanupSummary.self)
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    private func deleteAll<Model: PersistentModel>(_ model: Model.Type) throws {
        for record in try context.fetch(FetchDescriptor<Model>()) {
            context.delete(record)
        }
    }

    func serializedStateForTesting() throws -> Data {
        struct State: Codable {
            let checkpoints: [ScanCheckpoint]
            let tasks: [CleanupTask]
            let decisions: [PhotoDecision]
            let latestUndo: DecisionUndoEntry?
            let transactions: [MutationTransaction]
            let settings: WorkflowSettings
            let summaries: [CleanupSummary]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let checkpoints = try context.fetch(FetchDescriptor<PersistedScanCheckpoint>())
            .compactMap(\.value)
        return try encoder.encode(State(
            checkpoints: checkpoints,
            tasks: tasks(),
            decisions: decisions(),
            latestUndo: latestUndo(),
            transactions: transactions(),
            settings: settings(),
            summaries: summaries()
        ))
    }

    private func persistedDecision(for assetID: String) throws -> PersistedPhotoDecision? {
        let descriptor = FetchDescriptor<PersistedPhotoDecision>(
            predicate: #Predicate { $0.assetID == assetID }
        )
        return try context.fetch(descriptor).first
    }

    private func persistedCheckpoint(for id: String) throws -> PersistedScanCheckpoint? {
        let descriptor = FetchDescriptor<PersistedScanCheckpoint>(
            predicate: #Predicate { $0.identifier == id }
        )
        return try context.fetch(descriptor).first
    }

    private func persistedTask(for id: String) throws -> PersistedCleanupTask? {
        let descriptor = FetchDescriptor<PersistedCleanupTask>(
            predicate: #Predicate { $0.identifier == id }
        )
        return try context.fetch(descriptor).first
    }

    private func persistedTransaction(for id: String) throws -> PersistedMutationTransaction? {
        let descriptor = FetchDescriptor<PersistedMutationTransaction>(
            predicate: #Predicate { $0.identifier == id }
        )
        return try context.fetch(descriptor).first
    }
}

nonisolated enum ArchiveCompletionError: Error, Equatable {
    case invalidSuccess
    case taskNotFound(String)
    case assetPositionChanged(String)
}
