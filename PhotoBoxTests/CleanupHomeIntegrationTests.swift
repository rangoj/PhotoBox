import Foundation
import Testing
@testable import PhotoBox

@Suite("Cleanup home integration")
@MainActor
struct CleanupHomeIntegrationTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private var now: Date { Date(timeIntervalSince1970: 1_789_387_200) }

    @Test("Normal launch keeps unfinished work without replacing the home route")
    func normalLaunchKeepsWorkOnHome() throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let task = CleanupTask(
            id: "unfinished", type: .screenshots, title: "未完成", reason: "",
            assetIDs: ["a", "b"], estimatedBytes: 0, estimatedMinutes: 1,
            risk: .low, confidence: 1, status: .inProgress,
            ownedAssetIDs: ["b"], currentAssetIndex: 1,
            createdAt: .now, updatedAt: .now
        )
        try repository.save(task: task)
        var settings = WorkflowSettings.defaults
        settings.weeklyModeEnabled = true
        try repository.save(settings: settings)
        let model = AppModel(
            library: UITestPhotoLibraryService(authorization: .authorized),
            repository: repository
        )
        #expect(model.activeRoute == nil)
        #expect(model.taskNavigationPath.isEmpty)
        #expect(model.cleanupTasks.first?.currentAssetIndex == 1)
        #expect(model.cleanupTasks.first?.ownedAssetIDs == ["b"])
    }

    @Test("Home resumes one persisted batch across entrances and counts submitted decisions")
    func resumesBatchAndCountsAllDecisions() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let descriptors = [photo("a"), photo("b"), photo("archived")]
        try repository.save(decision: PhotoDecision(
            assetID: "archived", kind: .archive, isSubmitted: true
        ))
        let model = makeModel(repository: repository, descriptors: descriptors)
        model.startHomeCollection(.recent)
        let task = try #require(model.cleanupTasks.first { $0.type == .dateBatch })
        #expect(task.assetIDs == ["a", "b"])
        #expect(model.homeProjection.months.first?.processedCount == 1)
        await model.prepareSingleDecision(taskID: task.id)
        try #require(model.decisionFlow).decide(.keep)
        #expect(model.homeProjection.months.first?.processedCount == 2)
        model.taskNavigationPath = []

        let restored = makeModel(repository: repository, descriptors: descriptors)
        let components = calendar.dateComponents([.year, .month], from: now)
        restored.startHomeCollection(.month(year: components.year!, month: components.month!))
        #expect(try repository.tasks().filter { $0.type == .dateBatch }.count == 1)
        #expect(restored.taskNavigationPath == [.task(task.id)])
        await restored.prepareSingleDecision(taskID: task.id)
        #expect(restored.decisionFlow?.currentDescriptor?.id == "b")
        try #require(restored.decisionFlow).undo()
        #expect(restored.homeProjection.months.first?.processedCount == 1)
    }

    @Test("A date batch finishing with candidates reaches existing review")
    func completedBatchOpensReview() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let model = makeModel(repository: repository, descriptors: [photo("a")])
        model.startHomeCollection(.recent)
        let task = try #require(model.cleanupTasks.first { $0.type == .dateBatch })
        await model.prepareSingleDecision(taskID: task.id)
        try #require(model.decisionFlow).decide(.deleteCandidate)
        #expect(model.taskNavigationPath.last == .deleteReview)
        #expect(try repository.transactions().isEmpty)
    }

    @Test("Cloud-only home entries show counts without creating work")
    func cloudOnlyDoesNotCreateTask() throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let model = makeModel(repository: repository, descriptors: [photo("cloud", availability: .iCloudOnly)])
        model.startHomeCollection(.recent)
        #expect(model.homeProjection.months.first?.assetIDs.count == 1)
        #expect(model.homeNotice != nil)
        #expect(model.taskNavigationPath.isEmpty)
        #expect(try repository.tasks().isEmpty)
    }

    @Test("Missing batch members do not overwrite decisions or shift the saved membership")
    func unavailableMembersAreSkipped() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let descriptors = [photo("a"), photo("b"), photo("c")]
        let first = makeModel(repository: repository, descriptors: descriptors)
        first.startHomeCollection(.recent)
        let task = try #require(first.cleanupTasks.first { $0.type == .dateBatch })
        first.taskNavigationPath = []
        let restored = makeModel(repository: repository, descriptors: [photo("b"), photo("c")])
        restored.startHomeCollection(.recent)
        await restored.prepareSingleDecision(taskID: task.id)
        #expect(restored.decisionFlow?.currentDescriptor?.id == "b")
        try #require(restored.decisionFlow).decide(.keep)
        #expect(restored.decisionFlow?.currentDescriptor?.id == "c")
        #expect(try repository.tasks().first?.assetIDs == ["a", "b", "c"])
        #expect(try repository.decision(for: "a") == nil)
        #expect(try repository.decision(for: "b")?.kind == .keep)
    }

    @Test("A skipped middle member does not block a subsequent album archive")
    func archiveCursorRemainsAlignedAfterSkippedMember() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let first = makeModel(repository: repository, descriptors: [photo("a"), photo("b"), photo("c")])
        first.startHomeCollection(.recent)
        let task = try #require(first.cleanupTasks.first { $0.type == .dateBatch })
        first.taskNavigationPath = []
        let restored = makeModel(repository: repository, descriptors: [photo("a"), photo("c")])
        restored.startHomeCollection(.recent)
        await restored.prepareSingleDecision(taskID: task.id)
        try #require(restored.decisionFlow).decide(.keep)
        #expect(restored.decisionFlow?.currentDescriptor?.id == "c")
        #expect(try repository.tasks().first?.currentAssetIndex == 2)
        let decision = PhotoDecision(assetID: "c", kind: .archive, targetAlbumID: "album", taskID: task.id, isSubmitted: true)
        let transaction = MutationTransaction(
            id: "home-archive", operation: .archive, items: [MutationItem(assetID: "c", state: .succeeded)], targetAlbumID: "album"
        )
        try repository.completeArchive(transaction: transaction, decision: decision, recentAlbumIDs: ["album"])
        #expect(try repository.tasks().first?.assetIDs == ["a", "b", "c"])
        #expect(try repository.tasks().first?.status == .paused)
    }

    @Test("Date sessions do not inflate diagnosis space or task estimates")
    func datesDoNotInventDiagnosisSavings() throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let model = makeModel(repository: repository, descriptors: [photo("a")])
        model.startHomeCollection(.recent)
        let summary = DiagnosisSummary(tasks: model.cleanupTasks)
        #expect(summary.taskCount == 0)
        #expect(summary.estimatedReclaimableBytes == 0)
    }

    @Test("Inventory reconciliation advances an active date batch before archiving")
    func reconciliationAlignsActiveCursor() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let model = makeModel(repository: repository, descriptors: [photo("a"), photo("b")])
        model.startHomeCollection(.recent)
        let task = try #require(model.cleanupTasks.first { $0.type == .dateBatch })
        await model.prepareSingleDecision(taskID: task.id)
        try repository.reconcile(availableAssetIDs: ["b"])
        let updated = try #require(try repository.tasks().first)
        model.decisionFlow?.updateEligibility(Set(updated.ownedAssetIDs))
        #expect(model.decisionFlow?.currentDescriptor?.id == "b")
        #expect(updated.currentAssetIndex == 1)
        let decision = PhotoDecision(assetID: "b", kind: .archive, targetAlbumID: "album", taskID: task.id, isSubmitted: true)
        let transaction = MutationTransaction(
            id: "home-reconcile-archive", operation: .archive,
            items: [MutationItem(assetID: "b", state: .succeeded)], targetAlbumID: "album"
        )
        try repository.completeArchive(transaction: transaction, decision: decision, recentAlbumIDs: ["album"])
        #expect(try repository.tasks().first?.status == .paused)
        #expect(try repository.tasks().first?.assetIDs == ["a", "b"])
    }

    private func photo(_ id: String, availability: AssetAvailability = .local) -> PhotoAssetDescriptor {
        PhotoAssetDescriptor(
            id: id, mediaType: .photo, creationDate: now, pixelWidth: 800,
            pixelHeight: 600, duration: 0, estimatedBytes: 100,
            isFavorite: false, isEdited: false, isScreenshot: false,
            burstIdentifier: nil, availability: availability
        )
    }

    private func makeModel(repository: any TaskRepository, descriptors: [PhotoAssetDescriptor]) -> AppModel {
        let model = AppModel(
            library: HomeIntegrationReader(descriptors: descriptors), repository: repository,
            initialScan: .init(phase: .completed, discoveredCount: descriptors.count,
                processedCount: descriptors.count, localCount: descriptors.count,
                iCloudOnlyCount: 0, unavailableCount: 0, screenshotCount: 0,
                largeVideoCount: 0, userAlbumCount: 0),
            initialInventory: LibraryInventory(descriptors: descriptors), homeNow: now, homeCalendar: calendar
        )
        model.authorization = .authorized
        model.hasLoadedAuthorization = true
        return model
    }
}

private actor HomeIntegrationReader: PhotoLibraryReading {
    let descriptors: [PhotoAssetDescriptor]
    init(descriptors: [PhotoAssetDescriptor]) { self.descriptors = descriptors }
    func authorizationStatus() -> PhotoAuthorization { .authorized }
    func requestAuthorization() -> PhotoAuthorization { .authorized }
    func accessibleAssetDescriptors() -> [PhotoAssetDescriptor] { descriptors }
    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> {
        AsyncStream { $0.finish() }
    }
}
