import Foundation

nonisolated struct DateBatchPlan: Equatable, Sendable {
    let task: CleanupTask?
    let newTasks: [CleanupTask]
    let notice: String?
}

nonisolated enum DateBatchPlanner {
    static func plan(
        source: CleanupHomeSource,
        descriptors: [PhotoAssetDescriptor],
        tasks: [CleanupTask],
        decisions: [PhotoDecision],
        now: Date = .now,
        calendar: Calendar = CleanupHomeProjection.defaultCalendar,
        randomIndex: (Int) -> Int = { Int.random(in: 0..<$0) }
    ) -> DateBatchPlan {
        let sourcePhotos = CleanupHomeProjection(
            descriptors: descriptors,
            decisions: decisions,
            calendar: calendar
        ).photos(for: source, now: now, calendar: calendar)
        guard !sourcePhotos.isEmpty else {
            return DateBatchPlan(task: nil, newTasks: [], notice: "此集合中没有照片。")
        }

        let decisionsByAssetID = Set(decisions.map(\.assetID))
        let sourceByID = Dictionary(uniqueKeysWithValues: sourcePhotos.map { ($0.id, $0) })
        let resumable = resumableTasks(
            from: tasks,
            sourceByID: sourceByID,
            decidedAssetIDs: decisionsByAssetID
        )
        if let task = chooseExisting(
            resumable,
            sourceByID: sourceByID,
            source: source,
            calendar: calendar,
            randomIndex: randomIndex
        ) {
            return DateBatchPlan(task: task, newTasks: [], notice: nil)
        }

        let undecidedPhotos = sourcePhotos.filter { !decisionsByAssetID.contains($0.id) }
        guard !undecidedPhotos.isEmpty else {
            return DateBatchPlan(task: nil, newTasks: [], notice: "此集合已整理完成。")
        }

        let localPhotos = undecidedPhotos.filter { $0.availability == .local }
        guard !localPhotos.isEmpty else {
            return DateBatchPlan(
                task: nil,
                newTasks: [],
                notice: "此集合暂无可整理的本地照片。"
            )
        }

        let reservedIDs = Set(tasks.filter { $0.type == .dateBatch }.flatMap(\.assetIDs))
        let ownedIDs = Set(tasks
            .filter { $0.status == .inProgress }
            .flatMap(\.ownedAssetIDs))
        let eligiblePhotos = localPhotos.filter {
            !reservedIDs.contains($0.id) && !ownedIDs.contains($0.id)
        }
        guard !eligiblePhotos.isEmpty else {
            return DateBatchPlan(
                task: nil,
                newTasks: [],
                notice: "此集合中的照片正在其他任务中整理。"
            )
        }

        let dayGroups = groupedByDay(eligiblePhotos, calendar: calendar)
        let orderedDays = dayGroups.keys.sorted()
        let selectedDay: DateBatchDay
        if source == .random {
            selectedDay = orderedDays[boundedRandomIndex(orderedDays.count, using: randomIndex)]
        } else {
            selectedDay = orderedDays[orderedDays.count - 1]
        }

        let orderedPhotos = (dayGroups[selectedDay] ?? []).sorted(by: chronologicalOrder)
        let batches = selectedDay.isUndated
            ? orderedPhotos.map { [$0] }
            : balancedBatches(orderedPhotos)
        let newTasks = makeTasks(
            batches: batches,
            day: selectedDay,
            existingTasks: tasks,
            now: now
        )
        let selectedTask: CleanupTask?
        if source == .random {
            selectedTask = newTasks[boundedRandomIndex(newTasks.count, using: randomIndex)]
        } else {
            selectedTask = newTasks.first
        }
        return DateBatchPlan(task: selectedTask, newTasks: newTasks, notice: nil)
    }

    private static func resumableTasks(
        from tasks: [CleanupTask],
        sourceByID: [String: PhotoAssetDescriptor],
        decidedAssetIDs: Set<String>
    ) -> [CleanupTask] {
        tasks.filter { task in
            guard task.type == .dateBatch,
                  task.status != .completed,
                  task.status != .invalid else { return false }
            let ownedByOtherTasks = Set(tasks
                .filter { $0.id != task.id && $0.status == .inProgress }
                .flatMap(\.ownedAssetIDs))
            return task.assetIDs.contains { assetID in
                    guard let descriptor = sourceByID[assetID] else { return false }
                    return descriptor.availability == .local
                        && !decidedAssetIDs.contains(assetID)
                        && !ownedByOtherTasks.contains(assetID)
                }
        }
    }

    private static func chooseExisting(
        _ tasks: [CleanupTask],
        sourceByID: [String: PhotoAssetDescriptor],
        source: CleanupHomeSource,
        calendar: Calendar,
        randomIndex: (Int) -> Int
    ) -> CleanupTask? {
        guard !tasks.isEmpty else { return nil }
        let ordered = tasks.sorted { first, second in
            let firstDay = day(for: first, sourceByID: sourceByID, calendar: calendar)
            let secondDay = day(for: second, sourceByID: sourceByID, calendar: calendar)
            let firstStarted = first.status == .inProgress || first.status == .paused
            let secondStarted = second.status == .inProgress || second.status == .paused
            if source != .random && firstStarted != secondStarted { return firstStarted }
            if firstDay != secondDay { return firstDay > secondDay }
            return first.id < second.id
        }
        guard source == .random else { return ordered.first }

        let byDay = Dictionary(grouping: ordered) {
            day(for: $0, sourceByID: sourceByID, calendar: calendar)
        }
        let days = byDay.keys.sorted()
        let selectedDay = days[boundedRandomIndex(days.count, using: randomIndex)]
        let dayTasks = byDay[selectedDay] ?? []
        return dayTasks[boundedRandomIndex(dayTasks.count, using: randomIndex)]
    }

    private static func day(
        for task: CleanupTask,
        sourceByID: [String: PhotoAssetDescriptor],
        calendar: Calendar
    ) -> DateBatchDay {
        for assetID in task.assetIDs {
            if let descriptor = sourceByID[assetID] {
                return DateBatchDay(date: descriptor.creationDate, calendar: calendar)
            }
        }
        return .undated
    }

    private static func groupedByDay(
        _ photos: [PhotoAssetDescriptor],
        calendar: Calendar
    ) -> [DateBatchDay: [PhotoAssetDescriptor]] {
        Dictionary(grouping: photos) {
            DateBatchDay(date: $0.creationDate, calendar: calendar)
        }
    }

    private static func balancedBatches(
        _ photos: [PhotoAssetDescriptor]
    ) -> [[PhotoAssetDescriptor]] {
        let batchCount = max(1, (photos.count + 49) / 50)
        let baseSize = photos.count / batchCount
        let largerBatchCount = photos.count % batchCount
        var batches: [[PhotoAssetDescriptor]] = []
        var lowerBound = 0

        for index in 0..<batchCount {
            let size = baseSize + (index < largerBatchCount ? 1 : 0)
            let upperBound = lowerBound + size
            batches.append(Array(photos[lowerBound..<upperBound]))
            lowerBound = upperBound
        }
        return batches
    }

    private static func makeTasks(
        batches: [[PhotoAssetDescriptor]],
        day: DateBatchDay,
        existingTasks: [CleanupTask],
        now: Date
    ) -> [CleanupTask] {
        var usedIDs = Set(existingTasks.map(\.id))
        var nextSuffix = 0
        return batches.map { batch in
            var id: String
            repeat {
                id = String(format: "home:%@:%03d", day.identifier, nextSuffix)
                nextSuffix += 1
            } while usedIDs.contains(id)
            usedIDs.insert(id)

            let assetIDs = batch.map(\.id)
            let estimatedBytes = batch.reduce(Int64.zero) {
                $0 + max(0, $1.estimatedBytes)
            }
            return CleanupTask(
                id: id,
                type: .dateBatch,
                title: day.title,
                reason: "按拍摄日期分批整理",
                assetIDs: assetIDs,
                estimatedBytes: estimatedBytes,
                estimatedMinutes: max(1, (assetIDs.count + 9) / 10),
                risk: .low,
                confidence: 1,
                createdAt: now,
                updatedAt: now
            )
        }
    }

    private static func chronologicalOrder(
        _ first: PhotoAssetDescriptor,
        _ second: PhotoAssetDescriptor
    ) -> Bool {
        switch (first.creationDate, second.creationDate) {
        case let (firstDate?, secondDate?) where firstDate != secondDate:
            return firstDate < secondDate
        default:
            return first.id < second.id
        }
    }

    private static func boundedRandomIndex(
        _ upperBound: Int,
        using randomIndex: (Int) -> Int
    ) -> Int {
        precondition(upperBound > 0)
        let candidate = randomIndex(upperBound)
        return ((candidate % upperBound) + upperBound) % upperBound
    }
}

private nonisolated struct DateBatchDay: Hashable, Comparable {
    let year: Int?
    let month: Int?
    let day: Int?

    static let undated = DateBatchDay(year: nil, month: nil, day: nil)

    init(date: Date?, calendar: Calendar) {
        guard let date else {
            self = .undated
            return
        }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        year = components.year
        month = components.month
        day = components.day
    }

    private init(year: Int?, month: Int?, day: Int?) {
        self.year = year
        self.month = month
        self.day = day
    }

    var isUndated: Bool { year == nil || month == nil || day == nil }

    var identifier: String {
        guard let year, let month, let day else { return "undated" }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    var title: String {
        guard let year, let month, let day else { return "整理未标注日期的照片" }
        return "整理 \(year)年\(month)月\(day)日照片"
    }

    static func < (lhs: DateBatchDay, rhs: DateBatchDay) -> Bool {
        switch (lhs.year, lhs.month, lhs.day, rhs.year, rhs.month, rhs.day) {
        case let (leftYear?, leftMonth?, leftDay?, rightYear?, rightMonth?, rightDay?):
            return (leftYear, leftMonth, leftDay) < (rightYear, rightMonth, rightDay)
        case (_?, _?, _?, nil, nil, nil):
            return true
        case (nil, nil, nil, _?, _?, _?):
            return false
        default:
            return lhs.identifier < rhs.identifier
        }
    }
}
