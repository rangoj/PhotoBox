import Foundation

nonisolated enum CleanupHomeSource: Hashable, Sendable {
    case onThisDay
    case recent
    case random
    case month(year: Int, month: Int)
    case undated
}

nonisolated struct CleanupHomeMonth: Identifiable, Equatable, Sendable {
    let id: String
    let year: Int?
    let month: Int?
    let assetIDs: [String]
    let previewAssetIDs: [String]
    let processedCount: Int
    let isComplete: Bool
    let source: CleanupHomeSource
}

nonisolated struct CleanupHomeProjection: Sendable {
    let months: [CleanupHomeMonth]
    let photos: [PhotoAssetDescriptor]

    init(
        descriptors: [PhotoAssetDescriptor],
        decisions: [PhotoDecision],
        calendar: Calendar = CleanupHomeProjection.defaultCalendar
    ) {
        var descriptorsByID: [String: PhotoAssetDescriptor] = [:]
        for descriptor in descriptors where descriptor.mediaType != .video {
            descriptorsByID[descriptor.id] = descriptor
        }

        let photos = descriptorsByID.values.sorted(by: Self.homeOrder)
        let processedIDs = Set(decisions.map(\.assetID))
        var datedGroups: [MonthKey: [PhotoAssetDescriptor]] = [:]
        var undated: [PhotoAssetDescriptor] = []

        for descriptor in photos {
            guard let creationDate = descriptor.creationDate else {
                undated.append(descriptor)
                continue
            }
            let components = calendar.dateComponents([.year, .month], from: creationDate)
            guard let year = components.year, let month = components.month else {
                undated.append(descriptor)
                continue
            }
            datedGroups[MonthKey(year: year, month: month), default: []].append(descriptor)
        }

        var months = datedGroups.keys.sorted(by: >).map { key in
            Self.month(
                id: String(format: "%04d-%02d", key.year, key.month),
                year: key.year,
                month: key.month,
                descriptors: datedGroups[key] ?? [],
                processedIDs: processedIDs,
                source: .month(year: key.year, month: key.month)
            )
        }
        if !undated.isEmpty {
            months.append(Self.month(
                id: "undated",
                year: nil,
                month: nil,
                descriptors: undated,
                processedIDs: processedIDs,
                source: .undated
            ))
        }

        self.photos = photos
        self.months = months
    }

    func photos(
        for source: CleanupHomeSource,
        now: Date = .now,
        calendar: Calendar = CleanupHomeProjection.defaultCalendar
    ) -> [PhotoAssetDescriptor] {
        switch source {
        case .onThisDay:
            let today = calendar.dateComponents([.month, .day], from: now)
            let startOfToday = calendar.startOfDay(for: now)
            return photos.filter { descriptor in
                guard let creationDate = descriptor.creationDate,
                      creationDate < startOfToday else { return false }
                let components = calendar.dateComponents([.month, .day], from: creationDate)
                return components.month == today.month && components.day == today.day
            }
        case .recent:
            let today = calendar.startOfDay(for: now)
            guard let lowerBound = calendar.date(byAdding: .day, value: -29, to: today) else {
                return []
            }
            return photos.filter { descriptor in
                guard let creationDate = descriptor.creationDate else { return false }
                return creationDate >= lowerBound && creationDate <= now
            }
        case .random:
            return photos.filter { $0.creationDate != nil }
        case let .month(year, month):
            return photos.filter { descriptor in
                guard let creationDate = descriptor.creationDate else { return false }
                let components = calendar.dateComponents([.year, .month], from: creationDate)
                return components.year == year && components.month == month
            }
        case .undated:
            return photos.filter { $0.creationDate == nil }
        }
    }

    static var defaultCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    private static func month(
        id: String,
        year: Int?,
        month: Int?,
        descriptors: [PhotoAssetDescriptor],
        processedIDs: Set<String>,
        source: CleanupHomeSource
    ) -> CleanupHomeMonth {
        let assetIDs = descriptors.map(\.id)
        let processedCount = assetIDs.count { processedIDs.contains($0) }
        return CleanupHomeMonth(
            id: id,
            year: year,
            month: month,
            assetIDs: assetIDs,
            previewAssetIDs: Array(assetIDs.prefix(4)),
            processedCount: processedCount,
            isComplete: processedCount == assetIDs.count,
            source: source
        )
    }

    private static func homeOrder(
        _ first: PhotoAssetDescriptor,
        _ second: PhotoAssetDescriptor
    ) -> Bool {
        switch (first.creationDate, second.creationDate) {
        case let (firstDate?, secondDate?) where firstDate != secondDate:
            return firstDate > secondDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return first.id < second.id
        }
    }
}

private nonisolated struct MonthKey: Hashable, Comparable {
    let year: Int
    let month: Int

    static func < (lhs: MonthKey, rhs: MonthKey) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }
}
