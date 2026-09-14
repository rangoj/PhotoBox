import Foundation
import Testing
@testable import PhotoBox

@Suite("Album library integration")
@MainActor
struct AlbumLibraryReadingTests {
    @Test("Legacy readers expose an empty catalog but do not fabricate collection contents")
    func legacyReaderDefaults() async throws {
        let library = UITestPhotoLibraryService(authorization: .authorized)
        #expect(try await library.albumCollections().isEmpty)
        await #expect(throws: PhotoLibraryReadError.collectionUnavailable) {
            _ = try await library.assets(inCollection: "missing")
        }
    }

    @Test("App composition uses the real reader with simulated writes and invalidates lost access")
    func appCompositionAndPermissionChange() async throws {
        let reader = AlbumIntegrationReader()
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let model = AppModel(
            library: reader, repository: repository,
            mutator: SimulatedPhotoLibraryMutator(),
            initialScan: .init(phase: .completed, discoveredCount: 0, processedCount: 0,
                localCount: 0, iCloudOnlyCount: 0, unavailableCount: 0,
                screenshotCount: 0, largeVideoCount: 0, userAlbumCount: 1)
        )
        model.authorization = .authorized
        model.hasLoadedAuthorization = true
        await model.albumHome.load()
        #expect(model.albumHome.albums.map(\.id) == ["real"])
        let content = try #require(model.makeAlbumContentModel(collectionID: "real"))
        await content.load()
        #expect(content.assets.map(\.id) == ["photo"])
        #expect(try repository.decisions().isEmpty)
        #expect(try repository.transactions().isEmpty)
        await reader.setAuthorization(.denied)
        await model.refreshAuthorization()
        #expect(model.albumHome.albums.isEmpty)
        #expect(model.makeAlbumContentModel(collectionID: "real") == nil)
    }

    @Test("Membership-only notifications and foreground activation refresh the album catalog")
    func collectionOnlyChangesRefreshHome() async throws {
        let reader = AlbumIntegrationReader()
        let model = AppModel(
            library: reader, repository: try SwiftDataTaskRepository(inMemory: true),
            mutator: SimulatedPhotoLibraryMutator(),
            initialScan: UITestPhotoLibraryService.snapshot(for: .completed)
        )
        model.authorization = .authorized
        model.hasLoadedAuthorization = true
        await model.albumHome.load()
        await reader.rename("After membership change")
        let deadline = Date().addingTimeInterval(5)
        while model.albumHome.albums.first?.title != "After membership change", Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.albumHome.albums.first?.title == "After membership change")
        await reader.rename("After foreground", emit: false)
        await model.refreshForAppActivation()
        #expect(model.albumHome.albums.first?.title == "After foreground")
        await reader.setAuthorization(.limited)
        await model.refreshForAppActivation()
        #expect(model.albumHome.isLimited)
        #expect(model.albumHome.albums.first?.title == "After foreground")
    }

    // Production break: a collection-only event reconciles persisted work against an unscanned empty inventory.
    @Test("Collection-only changes preserve decisions and task membership before the initial scan")
    func collectionOnlyChangesPreserveUnscannedWork() async throws {
        let reader = AlbumIntegrationReader()
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let decision = PhotoDecision(assetID: "photo", kind: .protect, estimatedBytes: 1_000)
        let task = CleanupTask(
            id: "existing-task", type: .screenshots, title: "Existing task", reason: "Saved work",
            assetIDs: ["photo", "other"], estimatedBytes: 2_000, estimatedMinutes: 1,
            risk: .low, confidence: 1, status: .inProgress, ownedAssetIDs: ["photo", "other"],
            currentAssetIndex: 1, createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        try repository.save(decision: decision)
        try repository.save(task: task)
        let model = AppModel(library: reader, repository: repository, mutator: SimulatedPhotoLibraryMutator(), initialScan: .idle)
        model.authorization = .authorized
        model.hasLoadedAuthorization = true
        #expect(model.libraryInventory.descriptors.isEmpty)
        #expect(!model.isHomeInventoryReady)
        let savedTasks = try repository.tasks()
        await model.albumHome.load()

        await reader.rename("First collection-only refresh")
        try #require(await waitForAlbumTitle("First collection-only refresh", model: model))
        // The second serial notification proves the first handler finished before persistence is inspected.
        await reader.rename("Second collection-only refresh")
        try #require(await waitForAlbumTitle("Second collection-only refresh", model: model))

        #expect(try repository.decisions() == [decision])
        #expect(try repository.tasks() == savedTasks)
        #expect(model.libraryInventory.descriptors.isEmpty)
        #expect(!model.isHomeInventoryReady)
    }

    private func waitForAlbumTitle(_ title: String, model: AppModel) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if model.albumHome.albums.first?.title == title { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

private actor AlbumIntegrationReader: PhotoLibraryReading {
    private var authorization = PhotoAuthorization.authorized
    private var title = "真实相册"
    private let changes = AsyncStream<PhotoLibraryChange>.makeStream()
    func setAuthorization(_ value: PhotoAuthorization) { authorization = value }
    func authorizationStatus() -> PhotoAuthorization { authorization }
    func requestAuthorization() -> PhotoAuthorization { authorization }
    func albumCollections() -> [PhotoCollectionDescriptor] {
        [.init(id: "real", kind: .album, title: title, assetCount: 1, coverAssetID: "photo")]
    }
    func libraryChanges() -> AsyncStream<PhotoLibraryChange> { changes.stream }
    func rename(_ title: String, emit: Bool = true) {
        self.title = title
        if emit { changes.continuation.yield(PhotoLibraryChange(addedAssetIDs: [], removedAssetIDs: [], scopeChanged: false)) }
    }
    func assets(inCollection id: String) -> [PhotoAssetDescriptor] {
        [.init(id: "photo", mediaType: .photo, creationDate: nil, pixelWidth: 100,
            pixelHeight: 100, duration: 0, estimatedBytes: 0, isFavorite: false,
            isEdited: false, isScreenshot: false, burstIdentifier: nil, availability: .local)]
    }
    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> {
        AsyncStream { $0.finish() }
    }
}
