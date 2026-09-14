#if DEBUG
import Foundation
import UIKit

enum CleanupHomeUITestFixture {
    enum Mode: Equatable {
        case main
        case limited
        case empty
        case cloudOnly
        case failed
        case loading
        case smallKeep
        case smallDelete
    }

    static func mode(for arguments: [String]) -> Mode? {
        if arguments.contains("--ui-testing-home-small-keep") { return .smallKeep }
        if arguments.contains("--ui-testing-home-small-delete") { return .smallDelete }
        if arguments.contains("--ui-testing-home-limited") { return .limited }
        if arguments.contains("--ui-testing-home-empty") { return .empty }
        if arguments.contains("--ui-testing-home-cloud-only") { return .cloudOnly }
        if arguments.contains("--ui-testing-home-failed") { return .failed }
        if arguments.contains("--ui-testing-home-loading") { return .loading }
        if arguments.contains("--ui-testing-home") { return .main }
        return nil
    }

    @MainActor
    static func makeModel(mode: Mode) -> AppModel {
        let descriptors = descriptors(for: mode)
        let repository = try! SwiftDataTaskRepository(inMemory: true)
        let tasks = mode == .main || mode == .limited ? duplicateTasks : []
        if !tasks.isEmpty { try! repository.save(tasks: tasks) }
        let decisions = decisions(for: mode, descriptors: descriptors)
        if !decisions.isEmpty { try! repository.save(decisions: decisions) }

        let authorization: PhotoAuthorization = mode == .limited ? .limited : .authorized
        let initialInventory: LibraryInventory? = switch mode {
        case .failed, .loading:
            nil
        default:
            LibraryInventory(descriptors: descriptors)
        }
        let model = AppModel(
            library: CleanupHomeFixturePhotoLibrary(
                authorization: authorization,
                descriptors: retryDescriptors(for: mode, fallback: descriptors)
            ),
            repository: repository,
            mutator: SimulatedPhotoLibraryMutator(assetIDs: Set(descriptors.map(\.id))),
            initialScan: snapshot(for: mode, descriptors: descriptors),
            initialCleanupTasks: tasks,
            initialInventory: initialInventory,
            homeNow: now,
            homeCalendar: calendar
        )
        model.authorization = authorization
        model.hasLoadedAuthorization = true
        return model
    }

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    static let now = calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: 2026,
        month: 9,
        day: 14,
        hour: 12
    ))!

    private static let duplicateIDs = ["home-duplicate-1", "home-duplicate-2"]

    private static var duplicateTasks: [CleanupTask] {
        [
            CleanupTask(
                id: "home-similar-task",
                type: .similar,
                title: "检查相似照片",
                reason: "使用本地缩略图逐组确认",
                assetIDs: duplicateIDs,
                estimatedBytes: 4_000_000,
                estimatedMinutes: 1,
                risk: .medium,
                confidence: 0.9,
                createdAt: now,
                updatedAt: now
            )
        ]
    }

    private static func descriptors(for mode: Mode) -> [PhotoAssetDescriptor] {
        switch mode {
        case .main, .limited:
            return mainDescriptors
        case .empty, .loading:
            return []
        case .cloudOnly:
            return [descriptor(
                id: "home-cloud-only",
                date: date(year: 2026, month: 9, day: 13),
                availability: .iCloudOnly
            )]
        case .failed:
            return []
        case .smallKeep, .smallDelete:
            return [
                descriptor(id: "home-small-1", date: date(year: 2026, month: 9, day: 13, second: 1)),
                descriptor(id: "home-small-2", date: date(year: 2026, month: 9, day: 13, second: 2))
            ]
        }
    }

    private static func retryDescriptors(
        for mode: Mode,
        fallback: [PhotoAssetDescriptor]
    ) -> [PhotoAssetDescriptor] {
        guard mode == .failed else { return fallback }
        return [
            descriptor(id: "home-retry-1", date: date(year: 2026, month: 9, day: 12, second: 1)),
            descriptor(id: "home-retry-2", date: date(year: 2026, month: 9, day: 12, second: 2))
        ]
    }

    private static var mainDescriptors: [PhotoAssetDescriptor] {
        var result: [PhotoAssetDescriptor] = []
        result += dayDescriptors(prefix: "home-2026-08-05", count: 56, year: 2026, month: 8, day: 5)
        result += dayDescriptors(prefix: "home-2026-08-17", count: 62, year: 2026, month: 8, day: 17)

        var latestAugust = dayDescriptors(
            prefix: "home-2026-08-29",
            count: 118,
            year: 2026,
            month: 8,
            day: 29
        )
        latestAugust += duplicateIDs.enumerated().map { index, id in
            descriptor(id: id, date: date(year: 2026, month: 8, day: 29, second: 119 + index))
        }
        result += latestAugust
        result += dayDescriptors(prefix: "home-2026-07-12", count: 186, year: 2026, month: 7, day: 12)
        result += dayDescriptors(prefix: "home-2026-06-20", count: 312, year: 2026, month: 6, day: 20)
        result += dayDescriptors(prefix: "home-2025-09-14", count: 4, year: 2025, month: 9, day: 14)
        return result
    }

    private static func decisions(
        for mode: Mode,
        descriptors: [PhotoAssetDescriptor]
    ) -> [PhotoDecision] {
        guard mode == .main || mode == .limited else { return [] }
        let august = descriptors.filter {
            guard let date = $0.creationDate else { return false }
            let components = calendar.dateComponents([.year, .month], from: date)
            return components.year == 2026 && components.month == 8
        }
        let july = descriptors.filter {
            guard let date = $0.creationDate else { return false }
            let components = calendar.dateComponents([.year, .month], from: date)
            return components.year == 2026 && components.month == 7
        }
        return Array(august.prefix(40)).map {
            PhotoDecision(assetID: $0.id, kind: .keep, createdAt: now, isSubmitted: true)
        } + july.map {
            PhotoDecision(assetID: $0.id, kind: .keep, createdAt: now, isSubmitted: true)
        }
    }

    private static func snapshot(
        for mode: Mode,
        descriptors: [PhotoAssetDescriptor]
    ) -> LibraryScanSnapshot {
        var snapshot = LibraryScanSnapshot.idle
        snapshot.discoveredCount = descriptors.count
        snapshot.processedCount = descriptors.count
        snapshot.localCount = descriptors.count { $0.availability == .local }
        snapshot.iCloudOnlyCount = descriptors.count { $0.availability == .iCloudOnly }
        switch mode {
        case .failed:
            snapshot.phase = .failed
            snapshot.errorMessage = "测试扫描失败，请重试。"
        case .loading:
            snapshot.phase = .discovering
            snapshot.discoveredCount = 740
            snapshot.processedCount = 0
        default:
            snapshot.phase = .completed
        }
        return snapshot
    }

    private static func dayDescriptors(
        prefix: String,
        count: Int,
        year: Int,
        month: Int,
        day: Int
    ) -> [PhotoAssetDescriptor] {
        (0..<count).map { index in
            descriptor(
                id: String(format: "%@-%03d", prefix, index),
                date: date(year: year, month: month, day: day, second: index)
            )
        }
    }

    private static func descriptor(
        id: String,
        date: Date,
        availability: AssetAvailability = .local
    ) -> PhotoAssetDescriptor {
        let mediaType: PhotoMediaType
        let ordinal = id.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        if ordinal.isMultiple(of: 29) {
            mediaType = .panorama
        } else if ordinal.isMultiple(of: 17) {
            mediaType = .livePhoto
        } else {
            mediaType = .photo
        }
        return PhotoAssetDescriptor(
            id: id,
            mediaType: mediaType,
            creationDate: date,
            pixelWidth: 1_600,
            pixelHeight: 1_200,
            duration: 0,
            estimatedBytes: 2_000_000,
            isFavorite: false,
            isEdited: false,
            isScreenshot: false,
            burstIdentifier: nil,
            availability: availability
        )
    }

    private static func date(
        year: Int,
        month: Int,
        day: Int,
        second: Int = 0
    ) -> Date {
        let start = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: 10
        ))!
        return start.addingTimeInterval(TimeInterval(second))
    }
}

private actor CleanupHomeFixturePhotoLibrary: PhotoLibraryReading {
    let authorization: PhotoAuthorization
    let descriptors: [PhotoAssetDescriptor]

    init(authorization: PhotoAuthorization, descriptors: [PhotoAssetDescriptor]) {
        self.authorization = authorization
        self.descriptors = descriptors
    }

    func authorizationStatus() -> PhotoAuthorization { authorization }
    func requestAuthorization() -> PhotoAuthorization { authorization }
    func accessibleAssetDescriptors() -> [PhotoAssetDescriptor] { descriptors }

    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> {
        let descriptors = descriptors
        return AsyncStream { continuation in
            var snapshot = LibraryScanSnapshot.idle
            snapshot.phase = .completed
            snapshot.discoveredCount = descriptors.count
            snapshot.processedCount = descriptors.count
            snapshot.localCount = descriptors.count { $0.availability == .local }
            snapshot.iCloudOnlyCount = descriptors.count { $0.availability == .iCloudOnly }
            continuation.yield(snapshot)
            continuation.finish()
        }
    }

    func thumbnail(for assetID: String, maxPixelSize: Int) async -> PhotoThumbnail? {
        let names = ["HomeFixtureLake", "HomeFixtureField", "HomeFixtureSunset", "HomeFixtureCoffee"]
        let index = assetID.unicodeScalars.reduce(0) { $0 + Int($1.value) } % names.count
        return await MainActor.run {
            guard let image = UIImage(named: names[index]),
                  let data = image.jpegData(compressionQuality: 0.9) else { return nil }
            return PhotoThumbnail(
                assetID: assetID,
                data: data,
                pixelWidth: Int(image.size.width * image.scale),
                pixelHeight: Int(image.size.height * image.scale)
            )
        }
    }
}
#endif
