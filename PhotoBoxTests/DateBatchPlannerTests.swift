import Foundation
import Testing
@testable import PhotoBox

@Suite("Date batch planner")
struct DateBatchPlannerTests {
    @Test("A 56-photo day becomes two immutable balanced batches")
    func splitsFiftySix() throws {
        let calendar = plannerCalendar()
        let now = plannerDate(2026, 9, 14, hour: 12, calendar: calendar)
        let descriptors = (0..<56).reversed().map { index in
            plannerDescriptor(
                String(format: "asset-%02d", index),
                date: plannerDate(2026, 9, 2, hour: index / 10, minute: index % 10, calendar: calendar)
            )
        }

        let plan = DateBatchPlanner.plan(
            source: .month(year: 2026, month: 9),
            descriptors: descriptors,
            tasks: [],
            decisions: [],
            now: now,
            calendar: calendar
        )

        #expect(plan.newTasks.map { $0.assetIDs.count } == [28, 28])
        #expect(plan.newTasks.allSatisfy { $0.type == .dateBatch })
        #expect(plan.newTasks.allSatisfy { $0.id.hasPrefix("home:2026-09-02:") })
        #expect(plan.newTasks.flatMap(\.assetIDs) == (0..<56).map { String(format: "asset-%02d", $0) })
        #expect(plan.task == plan.newTasks.first)
        #expect(plan.notice == nil)
    }

    @Test("A 120-photo day becomes three batches of forty")
    func splitsOneHundredTwenty() {
        let calendar = plannerCalendar()
        let now = plannerDate(2026, 9, 14, calendar: calendar)
        let descriptors = (0..<120).map { index in
            plannerDescriptor(
                String(format: "asset-%03d", index),
                date: plannerDate(2026, 8, 31, hour: index / 60, minute: index % 60, calendar: calendar)
            )
        }

        let plan = DateBatchPlanner.plan(
            source: .month(year: 2026, month: 8),
            descriptors: descriptors,
            tasks: [],
            decisions: [],
            now: now,
            calendar: calendar
        )

        #expect(plan.newTasks.map { $0.assetIDs.count } == [40, 40, 40])
        #expect(plan.newTasks.flatMap(\.assetIDs) == descriptors.map(\.id))
    }

    @Test("Undated photos are separate singleton batches")
    func undatedUsesSingletons() {
        let descriptors = [
            plannerDescriptor("b", date: nil),
            plannerDescriptor("a", date: nil),
            plannerDescriptor("dated", date: Date(timeIntervalSince1970: 1_000))
        ]

        let plan = DateBatchPlanner.plan(
            source: .undated,
            descriptors: descriptors,
            tasks: [],
            decisions: []
        )

        #expect(plan.newTasks.map(\.assetIDs) == [["a"], ["b"]])
        #expect(plan.task?.assetIDs == ["a"])
    }

    @Test("A saved batch resumes across entrances and keeps its persisted membership")
    func resumesAcrossSourcesAndInventoryChanges() throws {
        let calendar = plannerCalendar()
        let now = plannerDate(2026, 9, 14, hour: 12, calendar: calendar)
        let day = plannerDate(2026, 9, 10, calendar: calendar)
        let saved = plannerTask(
            id: "home:2026-09-10:000",
            assetIDs: ["removed", "saved-a", "saved-b"],
            status: .paused,
            currentAssetIndex: 1
        )
        let descriptors = [
            plannerDescriptor("saved-a", date: day),
            plannerDescriptor("saved-b", date: day),
            plannerDescriptor("new", date: day)
        ]

        let recentPlan = DateBatchPlanner.plan(
            source: .recent,
            descriptors: descriptors,
            tasks: [saved],
            decisions: [],
            now: now,
            calendar: calendar
        )

        #expect(recentPlan.task?.id == saved.id)
        #expect(recentPlan.task?.assetIDs == ["removed", "saved-a", "saved-b"])
        #expect(recentPlan.newTasks.isEmpty)

        let completedMembers = [
            PhotoDecision(assetID: "saved-a", kind: .keep, taskID: saved.id),
            PhotoDecision(assetID: "saved-b", kind: .archive, taskID: saved.id, isSubmitted: true)
        ]
        let monthPlan = DateBatchPlanner.plan(
            source: .month(year: 2026, month: 9),
            descriptors: descriptors,
            tasks: [saved],
            decisions: completedMembers,
            now: now,
            calendar: calendar
        )

        let addition = try #require(monthPlan.task)
        #expect(addition.assetIDs == ["new"])
        #expect(monthPlan.newTasks == [addition])
        #expect(!addition.assetIDs.contains("saved-a"))
        #expect(!addition.assetIDs.contains("saved-b"))
        #expect(addition.id != saved.id)
    }

    @Test("Terminal saved batches are never resumed or regenerated")
    func terminalTasksReserveMembers() {
        let calendar = plannerCalendar()
        let day = plannerDate(2026, 7, 7, calendar: calendar)
        let descriptors = [
            plannerDescriptor("completed-member", date: day),
            plannerDescriptor("invalid-member", date: day)
        ]
        let tasks = [
            plannerTask(id: "home:2026-07-07:000", assetIDs: ["completed-member"], status: .completed),
            plannerTask(id: "home:2026-07-07:001", assetIDs: ["invalid-member"], status: .invalid)
        ]

        let plan = DateBatchPlanner.plan(
            source: .month(year: 2026, month: 7),
            descriptors: descriptors,
            tasks: tasks,
            decisions: [],
            calendar: calendar
        )

        #expect(plan.task == nil)
        #expect(plan.newTasks.isEmpty)
        #expect(plan.notice != nil)
    }

    @Test("Only local undecided and unowned assets enter a new batch")
    func filtersCloudDecisionsAndOwnership() throws {
        let calendar = plannerCalendar()
        let day = plannerDate(2026, 6, 1, calendar: calendar)
        let descriptors = [
            plannerDescriptor("local", date: day),
            plannerDescriptor("decided", date: day),
            plannerDescriptor("owned", date: day),
            plannerDescriptor("cloud", date: day, availability: .iCloudOnly),
            plannerDescriptor("unavailable", date: day, availability: .unavailable),
            plannerDescriptor("video", mediaType: .video, date: day)
        ]
        let foreignTask = plannerTask(
            id: "foreign",
            type: .weekly,
            assetIDs: ["owned"],
            status: .inProgress,
            ownedAssetIDs: ["owned"]
        )

        let plan = DateBatchPlanner.plan(
            source: .month(year: 2026, month: 6),
            descriptors: descriptors,
            tasks: [foreignTask],
            decisions: [PhotoDecision(assetID: "decided", kind: .keep)],
            calendar: calendar
        )

        #expect(try #require(plan.task).assetIDs == ["local"])
    }

    @Test("Random chooses a day uniformly before choosing one balanced batch")
    func randomChoosesDayThenBatch() throws {
        let calendar = plannerCalendar()
        let firstDay = plannerDate(2026, 5, 1, calendar: calendar)
        let secondDay = plannerDate(2026, 5, 2, calendar: calendar)
        let descriptors = [plannerDescriptor("first-day", date: firstDay)] + (0..<56).map { index in
            plannerDescriptor(String(format: "second-%02d", index), date: secondDay.addingTimeInterval(TimeInterval(index)))
        }
        var requestedUpperBounds: [Int] = []
        let selections = [1, 1]

        let plan = DateBatchPlanner.plan(
            source: .random,
            descriptors: descriptors,
            tasks: [],
            decisions: [],
            now: plannerDate(2026, 9, 14, calendar: calendar),
            calendar: calendar,
            randomIndex: { upperBound in
                requestedUpperBounds.append(upperBound)
                return selections[requestedUpperBounds.count - 1]
            }
        )

        #expect(requestedUpperBounds == [2, 2])
        #expect(plan.newTasks.map { $0.assetIDs.count } == [28, 28])
        #expect(try #require(plan.task).assetIDs.first == "second-28")
    }

    @Test("Empty, completed, cloud-only, and occupied sources return a notice")
    func reportsUnavailableReasons() {
        let calendar = plannerCalendar()
        let day = plannerDate(2026, 4, 1, calendar: calendar)
        let local = plannerDescriptor("local", date: day)
        let cloud = plannerDescriptor("cloud", date: day, availability: .iCloudOnly)
        let occupiedTask = plannerTask(
            id: "other",
            type: .weekly,
            assetIDs: ["local"],
            status: .inProgress,
            ownedAssetIDs: ["local"]
        )

        let empty = DateBatchPlanner.plan(source: .month(year: 2026, month: 4), descriptors: [], tasks: [], decisions: [], calendar: calendar)
        let completed = DateBatchPlanner.plan(source: .month(year: 2026, month: 4), descriptors: [local], tasks: [], decisions: [PhotoDecision(assetID: "local", kind: .keep)], calendar: calendar)
        let cloudOnly = DateBatchPlanner.plan(source: .month(year: 2026, month: 4), descriptors: [cloud], tasks: [], decisions: [], calendar: calendar)
        let occupied = DateBatchPlanner.plan(source: .month(year: 2026, month: 4), descriptors: [local], tasks: [occupiedTask], decisions: [], calendar: calendar)

        #expect(empty.notice != nil)
        #expect(completed.notice != nil)
        #expect(cloudOnly.notice != nil)
        #expect(occupied.notice != nil)
        #expect(Set([empty.notice, completed.notice, cloudOnly.notice, occupied.notice].compactMap { $0 }).count == 4)
        #expect([empty, completed, cloudOnly, occupied].allSatisfy { $0.task == nil && $0.newTasks.isEmpty })
    }
}

private func plannerCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar
}

private func plannerDate(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    hour: Int = 0,
    minute: Int = 0,
    calendar: Calendar
) -> Date {
    calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: year,
        month: month,
        day: day,
        hour: hour,
        minute: minute
    ))!
}

private func plannerDescriptor(
    _ id: String,
    mediaType: PhotoMediaType = .photo,
    date: Date?,
    availability: AssetAvailability = .local
) -> PhotoAssetDescriptor {
    PhotoAssetDescriptor(
        id: id,
        mediaType: mediaType,
        creationDate: date,
        pixelWidth: 1_000,
        pixelHeight: 800,
        duration: mediaType == .video ? 10 : 0,
        estimatedBytes: 1_000,
        isFavorite: false,
        isEdited: false,
        isScreenshot: false,
        burstIdentifier: nil,
        availability: availability
    )
}

private func plannerTask(
    id: String,
    type: CleanupTaskType = .dateBatch,
    assetIDs: [String],
    status: CleanupTaskStatus,
    ownedAssetIDs: [String] = [],
    currentAssetIndex: Int = 0
) -> CleanupTask {
    CleanupTask(
        id: id,
        type: type,
        title: "整理照片",
        reason: "按日期整理",
        assetIDs: assetIDs,
        estimatedBytes: Int64(assetIDs.count * 1_000),
        estimatedMinutes: 1,
        risk: .low,
        confidence: 1,
        status: status,
        ownedAssetIDs: ownedAssetIDs,
        currentAssetIndex: currentAssetIndex
    )
}
