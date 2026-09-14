import Foundation
import Testing
@testable import PhotoBox

@Suite("Cleanup home projection")
struct CleanupHomeProjectionTests {
    @Test("Months sort newest first, retain accessible photo media, and put undated last")
    func projectsTruthfulInventory() throws {
        let calendar = testCalendar(timeZone: "America/Los_Angeles")
        let descriptors = [
            descriptor("video", mediaType: .video, date: date(2026, 9, 5, calendar: calendar)),
            descriptor("photo", date: date(2026, 9, 3, calendar: calendar)),
            descriptor("cloud-live", mediaType: .livePhoto, date: date(2026, 9, 2, calendar: calendar), availability: .iCloudOnly),
            descriptor("unavailable-pano", mediaType: .panorama, date: date(2025, 12, 31, calendar: calendar), availability: .unavailable),
            descriptor("undated", date: nil)
        ]
        let decisions = [
            PhotoDecision(assetID: "photo", kind: .keep),
            PhotoDecision(assetID: "photo", kind: .protect, isSubmitted: true),
            PhotoDecision(assetID: "cloud-live", kind: .archive, isSubmitted: true)
        ]

        let projection = CleanupHomeProjection(
            descriptors: descriptors,
            decisions: decisions,
            calendar: calendar
        )

        #expect(projection.photos.map(\.id) == [
            "photo", "cloud-live", "unavailable-pano", "undated"
        ])
        #expect(projection.months.map(\.id) == ["2026-09", "2025-12", "undated"])

        let september = try #require(projection.months.first)
        #expect(september.year == 2026)
        #expect(september.month == 9)
        #expect(september.assetIDs == ["photo", "cloud-live"])
        #expect(september.previewAssetIDs == ["photo", "cloud-live"])
        #expect(september.processedCount == 2)
        #expect(september.isComplete)
        #expect(september.source == .month(year: 2026, month: 9))

        let undated = try #require(projection.months.last)
        #expect(undated.assetIDs == ["undated"])
        #expect(undated.source == .undated)
    }

    @Test("Natural-day scopes honor timezone, DST, history, and future exclusion")
    func scopesUseInjectedCalendar() {
        let calendar = testCalendar(timeZone: "America/Los_Angeles")
        let now = date(2026, 3, 9, hour: 12, calendar: calendar)
        let descriptors = [
            descriptor("recent-boundary", date: date(2026, 2, 8, hour: 0, calendar: calendar)),
            descriptor("too-old", date: date(2026, 2, 7, hour: 23, minute: 59, calendar: calendar)),
            descriptor("today", date: date(2026, 3, 9, hour: 9, calendar: calendar)),
            descriptor("future-today", date: date(2026, 3, 9, hour: 13, calendar: calendar)),
            descriptor("future-day", date: date(2026, 3, 10, calendar: calendar)),
            descriptor("on-this-day", date: date(2021, 3, 9, hour: 8, calendar: calendar)),
            descriptor("other-anniversary", date: date(2021, 3, 8, calendar: calendar)),
            descriptor("undated", date: nil)
        ]
        let projection = CleanupHomeProjection(
            descriptors: descriptors,
            decisions: [],
            calendar: calendar
        )

        #expect(Set(projection.photos(for: .recent, now: now, calendar: calendar).map(\.id)) == [
            "recent-boundary", "today"
        ])
        #expect(projection.photos(for: .onThisDay, now: now, calendar: calendar).map(\.id) == [
            "on-this-day"
        ])
        #expect(projection.photos(for: .month(year: 2026, month: 3), now: now, calendar: calendar).map(\.id) == [
            "future-day", "future-today", "today"
        ])
        #expect(projection.photos(for: .undated, now: now, calendar: calendar).map(\.id) == ["undated"])
        #expect(!projection.photos(for: .random, now: now, calendar: calendar).contains { $0.creationDate == nil })
    }

    @Test("Removing the current decision immediately reopens month progress")
    func undoReprojectsCurrentDecisions() throws {
        let calendar = testCalendar(timeZone: "Asia/Shanghai")
        let descriptors = [
            descriptor("first", date: date(2026, 1, 1, calendar: calendar)),
            descriptor("second", date: date(2026, 1, 2, calendar: calendar))
        ]
        let completed = CleanupHomeProjection(
            descriptors: descriptors,
            decisions: [
                PhotoDecision(assetID: "first", kind: .keep),
                PhotoDecision(assetID: "second", kind: .deleteCandidate, isSubmitted: true)
            ],
            calendar: calendar
        )
        let afterUndo = CleanupHomeProjection(
            descriptors: descriptors,
            decisions: [PhotoDecision(assetID: "first", kind: .keep)],
            calendar: calendar
        )

        #expect(try #require(completed.months.first).processedCount == 2)
        #expect(try #require(completed.months.first).isComplete)
        #expect(try #require(afterUndo.months.first).processedCount == 1)
        #expect(try !#require(afterUndo.months.first).isComplete)
    }
}

private func testCalendar(timeZone identifier: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: identifier)!
    return calendar
}

private func date(
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

private func descriptor(
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
