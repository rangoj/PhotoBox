import Foundation
import Testing
@testable import PhotoBox

@Suite("Production task generation")
struct TaskGenerationTests {
    @Test("Inventory cache distinguishes an empty library from an unloaded one")
    func inventoryCachePreservesEmptyResult() async {
        let store = LibraryInventoryStore()
        #expect(await store.snapshot() == nil)
        await store.replace(with: [])
        #expect(await store.snapshot() == [])
    }

    @Test("Metadata candidates become stable cleanup tasks")
    func generatesStableTasksFromScanDescriptors() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let old = now.addingTimeInterval(-40 * 86_400)
        let descriptors = [
            PhotoAssetDescriptor.fixture(
                id: "old-screenshot",
                creationDate: old,
                isScreenshot: true,
                estimatedBytes: 2_000
            ),
            PhotoAssetDescriptor.fixture(
                id: "long-video",
                mediaType: .video,
                creationDate: now,
                duration: 90,
                estimatedBytes: 8_000
            ),
            PhotoAssetDescriptor.fixture(
                id: "burst-a",
                creationDate: now,
                burstIdentifier: "burst",
                estimatedBytes: 1_000
            ),
            PhotoAssetDescriptor.fixture(
                id: "burst-b",
                creationDate: now.addingTimeInterval(1),
                burstIdentifier: "burst",
                estimatedBytes: 1_100
            )
        ]

        let first = CleanupTaskGenerator().generate(
            descriptors: descriptors,
            screenshotAgeDays: 30,
            now: now
        )
        let second = CleanupTaskGenerator().generate(
            descriptors: descriptors,
            screenshotAgeDays: 30,
            now: now
        )

        #expect(first == second)
        #expect(first.map(\.type) == [.screenshots, .bursts, .largeVideos])
        #expect(first[0].assetIDs == ["old-screenshot"])
        #expect(first[1].assetIDs == ["burst-a", "burst-b"])
        #expect(first[2].estimatedBytes == 8_000)
    }

    @Test("Incremental screenshot discovery keeps one task identity")
    func incrementalScreenshotTaskIdentityIsStable() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let first = CleanupTaskGenerator().generate(
            descriptors: [
                .fixture(
                    id: "old-a",
                    creationDate: now.addingTimeInterval(-40 * 86_400),
                    isScreenshot: true,
                    estimatedBytes: 1_000
                )
            ],
            screenshotAgeDays: 30,
            now: now
        )
        let second = CleanupTaskGenerator().generate(
            descriptors: [
                .fixture(
                    id: "old-a",
                    creationDate: now.addingTimeInterval(-40 * 86_400),
                    isScreenshot: true,
                    estimatedBytes: 1_000
                ),
                .fixture(
                    id: "old-b",
                    creationDate: now.addingTimeInterval(-35 * 86_400),
                    isScreenshot: true,
                    estimatedBytes: 2_000
                )
            ],
            screenshotAgeDays: 30,
            now: now
        )

        #expect(first.first?.id == "scan:screenshots")
        #expect(second.first?.id == first.first?.id)
        #expect(second.first?.assetIDs == ["old-a", "old-b"])
    }

    @Test("Favorited expired screenshots stay out of the deletion task")
    func favoriteScreenshotIsProtectedFromGeneration() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let tasks = CleanupTaskGenerator().generate(
            descriptors: [
                .fixture(
                    id: "favorite-old",
                    creationDate: now.addingTimeInterval(-40 * 86_400),
                    isScreenshot: true,
                    estimatedBytes: 1_000,
                    isFavorite: true
                ),
                .fixture(
                    id: "old",
                    creationDate: now.addingTimeInterval(-40 * 86_400),
                    isScreenshot: true,
                    estimatedBytes: 1_000
                )
            ],
            screenshotAgeDays: 30,
            now: now
        )

        #expect(tasks.first?.assetIDs == ["old"])
    }

    @Test("Partial scans defer unstable candidate groups")
    func partialGenerationDefersGroups() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let tasks = CleanupTaskGenerator().generate(
            descriptors: [
                .fixture(
                    id: "old",
                    creationDate: now.addingTimeInterval(-40 * 86_400),
                    isScreenshot: true,
                    estimatedBytes: 1_000
                ),
                .fixture(id: "burst-a", creationDate: now, burstIdentifier: "burst"),
                .fixture(id: "burst-b", creationDate: now.addingTimeInterval(1), burstIdentifier: "burst")
            ],
            screenshotAgeDays: 30,
            includeGroups: false,
            now: now
        )

        #expect(tasks.map(\.type) == [.screenshots])
    }

    @Test("Screenshots are not duplicated in similarity groups")
    func screenshotsHaveSingleTaskOwnership() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let tasks = CleanupTaskGenerator().generate(
            descriptors: [
                .fixture(id: "shot", creationDate: now, isScreenshot: true),
                .fixture(id: "photo", creationDate: now.addingTimeInterval(1))
            ],
            screenshotAgeDays: 0,
            now: now.addingTimeInterval(86_400)
        )

        let occurrences = tasks.flatMap(\.assetIDs).filter { $0 == "shot" }.count
        #expect(occurrences == 1)
    }

    @Test("Incremental merge reopens a terminal task when new assets arrive")
    func mergeReopensTerminalTaskForNewAssets() {
        var existing = CleanupTask(
            id: "scan:screenshots", type: .screenshots, title: "截图",
            reason: "测试", assetIDs: ["old"], estimatedBytes: 1_000,
            estimatedMinutes: 1, risk: .low, confidence: 1,
            status: .completed, currentAssetIndex: 1
        )
        existing.skipCount = 2
        let generated = CleanupTask(
            id: "scan:screenshots", type: .screenshots, title: "截图",
            reason: "测试", assetIDs: ["new", "old"], estimatedBytes: 2_000,
            estimatedMinutes: 2, risk: .low, confidence: 1
        )

        let merged = AppModel.mergeGeneratedTask(generated, preserving: existing)

        #expect(merged.status == .queued)
        #expect(merged.currentAssetIndex == 0)
        #expect(merged.ownedAssetIDs.isEmpty)
        #expect(merged.skipCount == 2)
    }

    @Test("Incremental merge preserves the current asset position")
    func mergePreservesCurrentAssetPosition() {
        let existing = CleanupTask(
            id: "scan:screenshots", type: .screenshots, title: "截图",
            reason: "测试", assetIDs: ["a", "b"], estimatedBytes: 2_000,
            estimatedMinutes: 2, risk: .low, confidence: 1,
            status: .inProgress, ownedAssetIDs: ["b"],
            currentAssetIndex: 1
        )
        let generated = CleanupTask(
            id: "scan:screenshots", type: .screenshots, title: "截图",
            reason: "测试", assetIDs: ["a", "b", "c"], estimatedBytes: 3_000,
            estimatedMinutes: 3, risk: .low, confidence: 1
        )

        let merged = AppModel.mergeGeneratedTask(generated, preserving: existing)

        #expect(merged.status == .inProgress)
        #expect(merged.currentAssetIndex == 1)
        #expect(merged.ownedAssetIDs == ["b"])
    }

    @Test("Only a complete scan may invalidate missing scan tasks")
    func partialScanDoesNotInvalidateExistingTasks() {
        let existing = [
            CleanupTask(
                id: "scan:screenshots", type: .screenshots, title: "截图",
                reason: "测试", assetIDs: ["old"], estimatedBytes: 1_000,
                estimatedMinutes: 1, risk: .low, confidence: 1
            ),
            CleanupTask(
                id: "scan:similar:old", type: .similar, title: "相似",
                reason: "测试", assetIDs: ["old"], estimatedBytes: 1_000,
                estimatedMinutes: 1, risk: .medium, confidence: 0.5
            )
        ]

        #expect(AppModel.staleScanTaskIDs(
            existingTasks: existing,
            generatedTaskIDs: [],
            includeGroups: false
        ).isEmpty)
        #expect(AppModel.staleScanTaskIDs(
            existingTasks: existing,
            generatedTaskIDs: ["scan:screenshots"],
            includeGroups: true
        ) == ["scan:similar:old"])
    }
}

private extension PhotoAssetDescriptor {
    static func fixture(
        id: String,
        mediaType: PhotoMediaType = .photo,
        creationDate: Date,
        duration: TimeInterval = 0,
        isScreenshot: Bool = false,
        burstIdentifier: String? = nil,
        estimatedBytes: Int64 = 0,
        availability: AssetAvailability = .local,
        isFavorite: Bool = false,
        isEdited: Bool = false
    ) -> PhotoAssetDescriptor {
        PhotoAssetDescriptor(
            id: id,
            mediaType: mediaType,
            creationDate: creationDate,
            pixelWidth: 1_000,
            pixelHeight: 1_000,
            duration: duration,
            estimatedBytes: estimatedBytes,
            isFavorite: isFavorite,
            isEdited: isEdited,
            isScreenshot: isScreenshot,
            burstIdentifier: burstIdentifier,
            availability: availability
        )
    }
}
