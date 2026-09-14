import Foundation
import Observation

nonisolated enum WeeklyInboxSource: Int, CaseIterable, Codable, Hashable, Sendable {
    case unfinished
    case expiredScreenshot
    case newAsset
    case deferred

    var title: String {
        switch self {
        case .unfinished: "继续未完成的整理"
        case .expiredScreenshot: "检查过期截图"
        case .newAsset: "检查新照片"
        case .deferred: "重新考虑稍后决定"
        }
    }

    var systemImage: String {
        switch self {
        case .unfinished: "arrow.forward.circle"
        case .expiredScreenshot: "camera.viewfinder"
        case .newAsset: "photo.badge.plus"
        case .deferred: "clock.arrow.circlepath"
        }
    }
}

nonisolated struct WeeklyInboxItem: Identifiable, Equatable, Sendable {
    let id: String
    let source: WeeklyInboxSource
    let title: String
    let reason: String
    let assetIDs: [String]
    let estimatedMinutes: Int
    let completedUnitCount: Int
    let totalUnitCount: Int
    let task: CleanupTask?
    let decision: PhotoDecision?
}

nonisolated struct WeeklyInboxPlan: Equatable, Sendable {
    let items: [WeeklyInboxItem]
    let estimatedMinutes: Int
    let completedUnitCount: Int
    let totalUnitCount: Int
    let remainingTaskCount: Int

    var taskCount: Int { items.count }
    var isTrulyEmpty: Bool { items.isEmpty && remainingTaskCount == 0 }
    var progress: Double {
        guard totalUnitCount > 0 else { return 1 }
        return min(max(Double(completedUnitCount) / Double(totalUnitCount), 0), 1)
    }

    static let empty = WeeklyInboxPlan(
        items: [],
        estimatedMinutes: 0,
        completedUnitCount: 0,
        totalUnitCount: 0,
        remainingTaskCount: 0
    )
}

nonisolated struct WeeklyInboxGenerator: Sendable {
    let maximumMinutes: Int
    let deferralInterval: TimeInterval

    init(maximumMinutes: Int = 5, deferralInterval: TimeInterval = 7 * 86_400) {
        self.maximumMinutes = maximumMinutes
        self.deferralInterval = deferralInterval
    }

    func generate(
        descriptors: [PhotoAssetDescriptor],
        tasks: [CleanupTask],
        decisions: [PhotoDecision],
        previouslyAccessibleAssetIDs: Set<String>,
        screenshotRetentionDays: Int,
        meaningfulCleanupDate: Date?,
        now: Date
    ) -> WeeklyInboxPlan {
        let localDescriptors = descriptors
            .filter { $0.availability == .local }
            .reduce(into: [String: PhotoAssetDescriptor]()) { result, descriptor in
                result[descriptor.id] = descriptor
            }
        let decisionsByID = Dictionary(uniqueKeysWithValues: decisions.map { ($0.assetID, $0) })
        var claimedCandidateAssetIDs = Set<String>()
        var candidates: [WeeklyInboxItem] = []

        let activeTasks = tasks.filter(\.isQualifyingCleanupCandidate)
        var authoritativeOwnerByAssetID: [String: String] = [:]
        for task in TaskRanker().rank(activeTasks, now: now) {
            for assetID in task.ownedAssetIDs where authoritativeOwnerByAssetID[assetID] == nil {
                authoritativeOwnerByAssetID[assetID] = task.id
            }
        }
        let unfinished = TaskRanker().rank(activeTasks.filter { $0.type != .largeVideos }, now: now)
        for task in unfinished {
            let remaining = Array(task.assetIDs.dropFirst(min(task.currentAssetIndex, task.assetIDs.count)))
            let workIDs: [String]
            if task.status == .inProgress, !task.ownedAssetIDs.isEmpty {
                let owned = Set(task.ownedAssetIDs)
                guard owned == Set(remaining) else { continue }
                workIDs = remaining
            } else {
                workIDs = remaining
            }
            guard !workIDs.isEmpty,
                  workIDs.allSatisfy({ localDescriptors[$0] != nil }),
                  Set(workIDs).isDisjoint(with: claimedCandidateAssetIDs),
                  workIDs.allSatisfy({ assetID in
                      guard let ownerID = authoritativeOwnerByAssetID[assetID] else { return true }
                      return ownerID == task.id
                  }),
                  workIDs.allSatisfy({ assetID in
                      guard let decision = decisionsByID[assetID] else { return true }
                      return decision.taskID == task.id
                  }) else { continue }
            claimedCandidateAssetIDs.formUnion(workIDs)
            candidates.append(WeeklyInboxItem(
                id: "unfinished:\(task.id)",
                source: .unfinished,
                title: task.title,
                reason: task.reason,
                assetIDs: workIDs,
                estimatedMinutes: max(0, task.estimatedMinutes),
                completedUnitCount: min(task.currentAssetIndex, task.assetIDs.count),
                totalUnitCount: task.assetIDs.count,
                task: task,
                decision: nil
            ))
        }

        var reservedAssetIDs = Set(authoritativeOwnerByAssetID.keys)
        reservedAssetIDs.formUnion(claimedCandidateAssetIDs)

        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -max(0, screenshotRetentionDays),
            to: now
        ) ?? .distantPast
        let expired = localDescriptors.values
            .filter { descriptor in
                descriptor.isScreenshot
                    && descriptor.creationDate.map { $0 < cutoff } == true
                    && !descriptor.isFavorite
                    && !descriptor.isEdited
                    && decisionsByID[descriptor.id] == nil
                    && !reservedAssetIDs.contains(descriptor.id)
            }
            .sorted(by: descriptorOrder)
        for descriptor in expired {
            reservedAssetIDs.insert(descriptor.id)
            candidates.append(generatedItem(
                descriptor: descriptor,
                source: .expiredScreenshot,
                taskType: .screenshots,
                reason: "超过 \(screenshotRetentionDays) 天且仍可在本机访问",
                confidence: 1,
                now: now
            ))
        }

        let newAssets = localDescriptors.values
            .filter { descriptor in
                let createdAfterCleanup = meaningfulCleanupDate.map { date in
                    descriptor.creationDate.map { $0 > date } == true
                } ?? false
                return (!previouslyAccessibleAssetIDs.contains(descriptor.id) || createdAfterCleanup)
                    && decisionsByID[descriptor.id] == nil
                    && !reservedAssetIDs.contains(descriptor.id)
            }
            .sorted(by: descriptorOrder)
        for descriptor in newAssets {
            reservedAssetIDs.insert(descriptor.id)
            candidates.append(generatedItem(
                descriptor: descriptor,
                source: .newAsset,
                taskType: .weekly,
                reason: "上次整理后新增且尚未决定",
                confidence: 0.8,
                now: now
            ))
        }

        let dueDate = now.addingTimeInterval(-deferralInterval)
        let deferred = decisions
            .filter { decision in
                decision.kind == .decideLater
                    && decision.createdAt <= dueDate
                    && localDescriptors[decision.assetID] != nil
                    && !reservedAssetIDs.contains(decision.assetID)
            }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.assetID < $1.assetID
            }
        for decision in deferred {
            reservedAssetIDs.insert(decision.assetID)
            candidates.append(WeeklyInboxItem(
                id: "deferred:\(decision.assetID)",
                source: .deferred,
                title: WeeklyInboxSource.deferred.title,
                reason: "已到再次查看的时间，可继续稍后决定",
                assetIDs: [decision.assetID],
                estimatedMinutes: 1,
                completedUnitCount: 0,
                totalUnitCount: 1,
                task: nil,
                decision: decision
            ))
        }

        var selected: [WeeklyInboxItem] = []
        var selectedMinutes = 0
        for item in candidates {
            guard selectedMinutes + item.estimatedMinutes <= maximumMinutes else { continue }
            selected.append(item)
            selectedMinutes += item.estimatedMinutes
        }
        return WeeklyInboxPlan(
            items: selected,
            estimatedMinutes: selectedMinutes,
            completedUnitCount: selected.reduce(0) { $0 + $1.completedUnitCount },
            totalUnitCount: selected.reduce(0) { $0 + $1.totalUnitCount },
            remainingTaskCount: candidates.count - selected.count
        )
    }

    private func generatedItem(
        descriptor: PhotoAssetDescriptor,
        source: WeeklyInboxSource,
        taskType: CleanupTaskType,
        reason: String,
        confidence: Double,
        now: Date
    ) -> WeeklyInboxItem {
        let task = CleanupTask(
            id: "weekly:\(source.rawValue):\(descriptor.id)",
            type: taskType,
            title: source.title,
            reason: reason,
            assetIDs: [descriptor.id],
            estimatedBytes: max(0, descriptor.estimatedBytes),
            estimatedMinutes: 1,
            risk: .low,
            confidence: confidence,
            createdAt: now,
            updatedAt: now
        )
        return WeeklyInboxItem(
            id: task.id,
            source: source,
            title: task.title,
            reason: task.reason,
            assetIDs: task.assetIDs,
            estimatedMinutes: task.estimatedMinutes,
            completedUnitCount: 0,
            totalUnitCount: task.assetIDs.count,
            task: task,
            decision: nil
        )
    }

    private func descriptorOrder(_ first: PhotoAssetDescriptor, _ second: PhotoAssetDescriptor) -> Bool {
        let firstDate = first.creationDate ?? .distantPast
        let secondDate = second.creationDate ?? .distantPast
        if firstDate != secondDate { return firstDate < secondDate }
        return first.id < second.id
    }
}

@MainActor
@Observable
final class WeeklyInboxModel {
    private let repository: any TaskRepository
    private let library: any PhotoLibraryReading
    private let inventoryStore: LibraryInventoryStore?
    private var previouslyAccessibleAssetIDs: Set<String>?
    private let now: () -> Date

    @ObservationIgnored
    private var refreshGeneration = UUID()

    private(set) var plan: WeeklyInboxPlan?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    init(
        repository: any TaskRepository,
        library: any PhotoLibraryReading,
        inventoryStore: LibraryInventoryStore? = nil,
        previouslyAccessibleAssetIDs: Set<String>?,
        now: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        self.library = library
        self.inventoryStore = inventoryStore
        self.previouslyAccessibleAssetIDs = previouslyAccessibleAssetIDs
        self.now = now
    }

    func refresh(screenshotRetentionDays: Int) async {
        let generation = UUID()
        refreshGeneration = generation
        isLoading = true
        errorMessage = nil
        defer {
            if refreshGeneration == generation {
                isLoading = false
            }
        }
        guard let previouslyAccessibleAssetIDs else {
            plan = nil
            errorMessage = "首次整理记录不可用，无法安全生成本周任务。"
            return
        }
        do {
            let descriptors = try await loadDescriptors()
            guard refreshGeneration == generation, !Task.isCancelled else { return }
            let tasks = try repository.tasks()
            let decisions = try repository.decisions()
            let summaries = try repository.summaries()
            let transactions = try repository.transactions()
            guard refreshGeneration == generation, !Task.isCancelled else { return }
            let generatedPlan = WeeklyInboxGenerator().generate(
                descriptors: descriptors,
                tasks: tasks,
                decisions: decisions,
                previouslyAccessibleAssetIDs: previouslyAccessibleAssetIDs,
                screenshotRetentionDays: screenshotRetentionDays,
                meaningfulCleanupDate: Self.meaningfulCleanupDate(
                    summaries: summaries,
                    transactions: transactions
                ),
                now: now()
            )
            let generatedTasks = generatedPlan.items.compactMap { item in
                item.source == .unfinished ? nil : item.task
            }
            if !generatedTasks.isEmpty {
                try repository.save(tasks: generatedTasks)
            }
            guard refreshGeneration == generation, !Task.isCancelled else { return }
            plan = generatedPlan
        } catch {
            guard refreshGeneration == generation, !Task.isCancelled else { return }
            errorMessage = plan == nil
                ? "无法载入本周整理，请重试。"
                : "无法刷新本周整理，已保留上次结果。"
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

    func updatePreviouslyAccessibleAssetIDs(_ assetIDs: Set<String>?) {
        previouslyAccessibleAssetIDs = assetIDs
    }

    private static func meaningfulCleanupDate(
        summaries: [CleanupSummary],
        transactions: [MutationTransaction]
    ) -> Date? {
        let summaryDates = summaries.compactMap { summary -> Date? in
            let count = summary.keptCount + summary.archivedCount
                + summary.protectedCount + summary.deferredCount
            return count > 0 ? summary.createdAt : nil
        }
        let transactionDates = transactions.compactMap { transaction -> Date? in
            guard transaction.operation == .delete,
                  transaction.items.contains(where: {
                      [.submitted, .succeeded, .failed, .cancelled].contains($0.state)
                  }) else { return nil }
            return transaction.completedAt ?? transaction.submittedAt ?? transaction.createdAt
        }
        return (summaryDates + transactionDates).max()
    }
}
