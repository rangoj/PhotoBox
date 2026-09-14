import Foundation
import Testing
@testable import PhotoBox

@MainActor
struct AlbumHomeModelTests {
    // Production break: title deduplication collapses distinct albums or recent IDs outrank favorites.
    @Test("Albums preserve identity and fill quick access after recent albums")
    func projectionPreservesIdentityAndFillsRecentFallback() async {
        let reader = AlbumModelReader(collections: [
            album("b", "Same", count: 3), album("z", "Zebra"),
            album("a", "Same"), album("first", "Alpha"), favorites()
        ])
        let model = AlbumHomeModel(library: reader, mutator: SimulatedPhotoLibraryMutator(), recentAlbumIDs: {
            ["missing", "z", "z", "favorites"]
        })
        await model.load()
        #expect(model.albums.map(\.id) == ["first", "a", "b", "z"])
        #expect(model.quickAccess.map(\.id) == ["favorites", "z", "first", "a"])
        #expect(model.collection(id: "b")?.assetCount == 3)
        #expect(model.quickAccess.first?.assetCount == 0)
        #expect(model.hasLoaded)
        #expect(model.revision > 0)
    }

    // Production break: read failure becomes an empty successful library or retry leaves its error visible.
    @Test("Catalog failure remains distinguishable from an empty result and retries")
    func readFailureAndRetry() async {
        let reader = AlbumModelReader(collections: [favorites()])
        await reader.setReadFailure(true)
        let model = AlbumHomeModel(library: reader, mutator: SimulatedPhotoLibraryMutator())
        await model.load()
        #expect(model.errorMessage != nil)
        #expect(!model.hasLoaded)
        await reader.setReadFailure(false)
        await model.load()
        #expect(model.errorMessage == nil)
        #expect(model.hasLoaded)
        #expect(model.albums.isEmpty)
        #expect(model.quickAccess.map(\.id) == ["favorites"])
    }

    // Production break: authorization is bypassed before directory reads or creation.
    @Test("Denied scope blocks reads and album creation")
    func deniedScopeBlocksReadsAndCreation() async {
        let reader = AlbumModelReader(collections: [album("hidden", "Hidden")], authorization: .denied)
        let mutator = SimulatedPhotoLibraryMutator()
        let model = AlbumHomeModel(library: reader, mutator: mutator)
        await model.load()
        model.beginCreation()
        model.creationName = "Private"
        await model.createAlbum()
        #expect(model.albums.isEmpty)
        #expect(model.errorMessage != nil)
        #expect(model.creationError != nil)
        #expect(await reader.directoryRequests == 0)
        #expect(await mutator.createAlbumRequests.isEmpty)
    }

    // Production break: creation is reused from create-and-archive or untrimmed/empty names are submitted.
    @Test("Creating an empty album trims the name and performs no photo mutations")
    func creationOnlyAndValidation() async {
        let reader = AlbumModelReader(collections: [favorites()])
        let mutator = SimulatedPhotoLibraryMutator(assetIDs: ["photo"])
        let model = AlbumHomeModel(library: reader, mutator: mutator)
        model.beginCreation()
        model.creationName = " \n "
        await model.createAlbum()
        #expect(model.creationError != nil)
        #expect(await mutator.createAlbumRequests.isEmpty)
        model.creationName = "  Weekend \n"
        await model.createAlbum()
        #expect(await mutator.createAlbumRequests == ["Weekend"])
        #expect(await mutator.submittedAssetIDs.isEmpty)
        #expect(model.albums.map(\.title) == ["Weekend"])
        #expect(model.albums.first?.assetCount == 0)
        #expect(!model.isPresentingCreation)
        #expect(model.notice?.contains("模拟") == true)
        #expect(model.albums.first.map { model.isSimulatedCollection(id: $0.id) } == true)
    }

    // Production break: membership browsing filters nonlocal or nonphoto media.
    @Test("Collection contents retain all accessible media and cloud placeholders")
    func contentPreservesAccessibleMedia() async {
        let reader = AlbumModelReader(collections: [album("media", "Media", count: 4)], members: [
            asset("photo", .photo), asset("live", .livePhoto),
            asset("panorama", .panorama), asset("video", .video, availability: .iCloudOnly)
        ])
        let model = AlbumContentModel(collection: album("media", "Media", count: 4), library: reader)
        await model.load()
        #expect(model.assets.map(\.id) == ["photo", "live", "panorama", "video"])
        #expect(model.assets.last?.duration == 42)
        #expect(model.assets.last?.availability == .iCloudOnly)
        #expect(await reader.memberRequests == ["media"])
        #expect(model.errorMessage == nil)
    }

    // Production break: a refresh ignores rename or membership-only changes.
    @Test("Refresh replaces renamed collections and changed memberships")
    func refreshUpdatesExistingIdentities() async {
        let reader = AlbumModelReader(collections: [album("same", "Before", count: 2)])
        let model = AlbumHomeModel(library: reader, mutator: SimulatedPhotoLibraryMutator())
        await model.load()
        let previousRevision = model.revision
        await reader.setCollections([album("same", "After", count: 5)])
        await model.load()
        #expect(model.albums.map(\.title) == ["After"])
        #expect(model.albums.first?.assetCount == 5)
        #expect(model.revision > previousRevision)
    }

    // Production break: invalidation leaves authorized snapshots visible or a stale request republishes them.
    @Test("Invalidation hides sensitive snapshots and suppresses a pending result")
    func invalidationSuppressesStaleResult() async throws {
        let reader = AlbumModelReader(collections: [album("old", "Old")])
        let model = AlbumHomeModel(library: reader, mutator: SimulatedPhotoLibraryMutator())
        await model.load()
        await reader.setHoldDirectory(true)
        let pending = Task { await model.load() }
        try #require(await reader.waitForDirectoryRequests(2, tasks: [pending]))
        model.invalidate()
        #expect(model.albums.isEmpty)
        #expect(model.quickAccess.isEmpty)
        #expect(!model.hasLoaded)
        await reader.resolveDirectory(2, collections: [album("stale", "Stale")])
        await pending.value
        #expect(model.albums.isEmpty)
        #expect(!model.isLoading)
    }

    // Production break: an older overlapping load wins or a canceled load publishes a response.
    @Test("Only the latest uncancelled directory load publishes")
    func latestLoadWinsAndCancellationDoesNotPublish() async throws {
        let reader = AlbumModelReader(collections: [])
        await reader.setHoldDirectory(true)
        let model = AlbumHomeModel(library: reader, mutator: SimulatedPhotoLibraryMutator())
        let first = Task { await model.load() }
        try #require(await reader.waitForDirectoryRequests(1, tasks: [first]))
        let second = Task { await model.load() }
        try #require(await reader.waitForDirectoryRequests(2, tasks: [first, second]))
        await reader.resolveDirectory(2, collections: [album("new", "New")])
        await second.value
        await reader.resolveDirectory(1, collections: [album("old", "Old")])
        await first.value
        #expect(model.albums.map(\.id) == ["new"])
        let third = Task { await model.load() }
        try #require(await reader.waitForDirectoryRequests(3, tasks: [third]))
        third.cancel()
        await reader.resolveDirectory(3, collections: [album("cancelled", "Cancelled")])
        await third.value
        #expect(model.albums.map(\.id) == ["new"])
        #expect(!model.isLoading)
    }

    // Production break: a full-access result survives a scope change while suspended.
    @Test("Scope changes during a load discard its old result and allow limited reload")
    func scopeChangeDuringRead() async throws {
        let reader = AlbumModelReader(collections: [])
        await reader.setHoldDirectory(true)
        let model = AlbumHomeModel(library: reader, mutator: SimulatedPhotoLibraryMutator())
        let pending = Task { await model.load() }
        try #require(await reader.waitForDirectoryRequests(1, tasks: [pending]))
        await reader.setAuthorization(.limited)
        await reader.resolveDirectory(1, collections: [album("private", "Private", count: 10)])
        await pending.value
        #expect(model.albums.isEmpty)
        #expect(model.errorMessage != nil)
        await reader.setHoldDirectory(false)
        await reader.setCollections([album("accessible", "Accessible", count: 1)])
        await model.load()
        #expect(model.isLimited)
        #expect(model.albums.map(\.id) == ["accessible"])
        #expect(model.errorMessage == nil)
    }

    // Production break: cancel submits a mutation or a second activation submits while the first is pending.
    @Test("Creation cancellation is inert and pending creation submits exactly once")
    func cancellationAndSingleSubmission() async throws {
        let reader = AlbumModelReader(collections: [])
        let mutator = AlbumModelMutator(holdCreation: true)
        let model = AlbumHomeModel(library: reader, mutator: mutator)
        model.beginCreation()
        model.creationName = "Cancelled"
        model.cancelCreation()
        #expect(!model.isPresentingCreation)
        #expect(await mutator.createRequests.isEmpty)
        model.beginCreation()
        model.creationName = "Once"
        let first = Task { await model.createAlbum() }
        try #require(await mutator.waitForCreation(task: first))
        model.cancelCreation()
        await model.createAlbum()
        #expect(model.isCreating)
        #expect(model.isPresentingCreation)
        #expect(await mutator.createRequests == ["Once"])
        await mutator.resolveCreation(PhotoAlbumDescriptor(id: "created", title: "Once", assetCount: 0))
        await first.value
        #expect(!model.isCreating)
        #expect(await mutator.archiveCalls == 0)
        #expect(await mutator.deleteCalls == 0)
        #expect(await mutator.listCalls == 0)
    }

    // Production break: a nil creation result automatically retries or can be resubmitted before successful recovery.
    @Test("Uncertain creation requires successful read recovery before explicit retry")
    func uncertainCreationRecoveryIsReadOnly() async {
        let reader = AlbumModelReader(collections: [])
        let mutator = AlbumModelMutator(result: nil)
        let model = AlbumHomeModel(library: reader, mutator: mutator)
        model.beginCreation()
        model.creationName = "Uncertain"
        await model.createAlbum()
        #expect(model.creationNeedsRefresh)
        #expect(model.creationError != nil)
        #expect(model.creationName == "Uncertain")
        await model.createAlbum()
        #expect(await mutator.createRequests == ["Uncertain"])
        await reader.setReadFailure(true)
        await model.recoverCreation()
        #expect(model.creationNeedsRefresh)
        await reader.setReadFailure(false)
        await model.recoverCreation()
        #expect(!model.creationNeedsRefresh)
        #expect(await mutator.createRequests == ["Uncertain"])
        await model.createAlbum()
        #expect(await mutator.createRequests == ["Uncertain", "Uncertain"])
    }

    // Production break: failed post-create read hides the successful empty album or retries the mutation.
    @Test("Successful creation survives refresh failure and recovery does not recreate")
    func createdAlbumSurvivesReadFailure() async {
        let reader = AlbumModelReader(collections: [])
        await reader.setReadFailure(true)
        let mutator = AlbumModelMutator(result: PhotoAlbumDescriptor(id: "created", title: "Created", assetCount: 0))
        let model = AlbumHomeModel(library: reader, mutator: mutator)
        model.beginCreation()
        model.creationName = "Created"
        await model.createAlbum()
        #expect(model.albums.map(\.id) == ["created"])
        #expect(model.errorMessage != nil)
        #expect(!model.isPresentingCreation)
        #expect(!model.isSimulatedCollection(id: "created"))
        await reader.setReadFailure(false)
        await reader.setCollections([album("created", "Renamed", count: 1)])
        await model.load()
        #expect(model.albums.map(\.title) == ["Renamed"])
        #expect(model.albums.first?.assetCount == 1)
        #expect(await mutator.createRequests == ["Created"])
    }

    // Production break: switching away from a simulation keeps nonexistent system collections visible.
    @Test("Mutator replacement removes simulation session collections")
    func simulatedCollectionsClearedOnBackendReplacement() async {
        let reader = AlbumModelReader(collections: [album("system", "System")])
        let model = AlbumHomeModel(library: reader, mutator: SimulatedPhotoLibraryMutator())
        model.beginCreation()
        model.creationName = "Simulation"
        await model.createAlbum()
        let simulatedID = model.albums.first { $0.title == "Simulation" }?.id
        #expect(simulatedID != nil)
        let oldRevision = model.revision
        model.replaceMutator(AlbumModelMutator())
        await model.load()
        #expect(model.albums.map(\.id) == ["system"])
        #expect(model.notice == nil)
        #expect(model.revision > oldRevision)
    }

    // Production break: collection read failure becomes empty success or denied access still enumerates members.
    @Test("Collection failures retry and permission loss clears contents")
    func contentFailureRetryAndPermissionLoss() async {
        let reader = AlbumModelReader(collections: [], members: [asset("visible", .photo)])
        let model = AlbumContentModel(collection: album("source", "Source"), library: reader)
        await reader.setReadFailure(true)
        await model.load()
        #expect(model.errorMessage != nil)
        await reader.setReadFailure(false)
        await model.load()
        #expect(model.assets.map(\.id) == ["visible"])
        #expect(model.errorMessage == nil)
        await reader.setAuthorization(.denied)
        await model.load()
        #expect(model.assets.isEmpty)
        #expect(model.errorMessage != nil)
        #expect(await reader.memberRequests == ["source", "source"])
    }

    // Production break: a simulated empty collection is sent to the real PhotoKit member reader.
    @Test("Simulation collection contents remain empty without a system read")
    func simulationContentsDoNotReadSystemCollection() async {
        let reader = AlbumModelReader(collections: [])
        let model = AlbumContentModel(collection: album("simulated", "Simulation"), library: reader, isSimulated: true)
        await model.load()
        #expect(model.assets.isEmpty)
        #expect(model.errorMessage == nil)
        #expect(await reader.memberRequests.isEmpty)
    }

    // Production break: a pending create publishes a stale collection after invalidation or unlocks duplicate submission early.
    @Test("Invalidation suppresses pending creation while retaining the submission lock")
    func pendingCreationInvalidation() async throws {
        let reader = AlbumModelReader(collections: [])
        let mutator = AlbumModelMutator(holdCreation: true)
        let model = AlbumHomeModel(library: reader, mutator: mutator)
        model.beginCreation()
        model.creationName = "Pending"
        let pending = Task { await model.createAlbum() }
        try #require(await mutator.waitForCreation(task: pending))
        model.invalidate()
        await model.createAlbum()
        #expect(model.isCreating)
        #expect(await mutator.createRequests == ["Pending"])
        await mutator.resolveCreation(PhotoAlbumDescriptor(id: "stale", title: "Pending", assetCount: 0))
        await pending.value
        #expect(model.albums.isEmpty)
        #expect(model.notice == nil)
        #expect(!model.isCreating)
        #expect(model.creationNeedsRefresh)
    }

    // Production break: an old backend completion injects a simulated album into the replacement backend.
    @Test("Backend replacement suppresses the previous pending creation result")
    func replacementSuppressesPendingCreation() async throws {
        let reader = AlbumModelReader(collections: [])
        let oldMutator = AlbumModelMutator(holdCreation: true)
        let model = AlbumHomeModel(library: reader, mutator: oldMutator)
        model.beginCreation()
        model.creationName = "Old backend"
        let pending = Task { await model.createAlbum() }
        try #require(await oldMutator.waitForCreation(task: pending))
        model.replaceMutator(SimulatedPhotoLibraryMutator())
        await oldMutator.resolveCreation(PhotoAlbumDescriptor(id: "old", title: "Old backend", assetCount: 0))
        await pending.value
        #expect(model.albums.isEmpty)
        #expect(model.notice == nil)
        #expect(!model.isCreating)
    }

    // Production break: a canceled or invalidated content request republishes out-of-scope members.
    @Test("Invalidated and canceled collection loads suppress pending members")
    func staleContentDoesNotPublish() async throws {
        let reader = AlbumModelReader(collections: [])
        await reader.setHoldMembers(true)
        let model = AlbumContentModel(collection: album("source", "Source"), library: reader)
        let invalidated = Task { await model.load() }
        try #require(await reader.waitForMemberRequests(1, tasks: [invalidated]))
        model.invalidate()
        await reader.resolveMembers(1, members: [asset("stale", .photo)])
        await invalidated.value
        #expect(model.assets.isEmpty)
        #expect(!model.isLoading)
        let canceled = Task { await model.load() }
        try #require(await reader.waitForMemberRequests(2, tasks: [canceled]))
        canceled.cancel()
        await reader.resolveMembers(2, members: [asset("canceled", .photo)])
        await canceled.value
        #expect(model.assets.isEmpty)
        #expect(!model.isLoading)
    }

    // Production break: scope changes after member enumeration still publish the full-access response.
    @Test("Permission reduction during member loading discards the old result")
    func contentScopeChangeDoesNotPublish() async throws {
        let reader = AlbumModelReader(collections: [])
        await reader.setHoldMembers(true)
        let model = AlbumContentModel(collection: album("source", "Source"), library: reader)
        let pending = Task { await model.load() }
        try #require(await reader.waitForMemberRequests(1, tasks: [pending]))
        await reader.setAuthorization(.limited)
        await reader.resolveMembers(1, members: [asset("private", .photo)])
        await pending.value
        #expect(model.assets.isEmpty)
        #expect(model.errorMessage != nil)
    }

    // Production break: an inaccessible/deleted collection is represented as a successfully empty album.
    @Test("Missing collection remains an error until a successful retry")
    func missingCollectionRecovery() async {
        let reader = AlbumModelReader(collections: [], members: [asset("member", .photo)])
        await reader.setMissingCollection(true)
        let model = AlbumContentModel(collection: album("missing", "Missing"), library: reader)
        await model.load()
        #expect(model.assets.isEmpty)
        #expect(model.errorMessage == PhotoLibraryReadError.collectionUnavailable.message)
        await reader.setMissingCollection(false)
        await model.load()
        #expect(model.assets.map(\.id) == ["member"])
        #expect(model.errorMessage == nil)
    }

    private func album(_ id: String, _ title: String, count: Int = 0) -> PhotoCollectionDescriptor {
        PhotoCollectionDescriptor(id: id, kind: .album, title: title, assetCount: count, coverAssetID: nil)
    }

    private func favorites() -> PhotoCollectionDescriptor {
        PhotoCollectionDescriptor(id: "favorites", kind: .favorites, title: "Favorites", assetCount: 0, coverAssetID: nil)
    }

    private func asset(_ id: String, _ type: PhotoMediaType, availability: AssetAvailability = .local) -> PhotoAssetDescriptor {
        PhotoAssetDescriptor(id: id, mediaType: type, creationDate: nil, pixelWidth: 1200, pixelHeight: 900,
                             duration: type == .video ? 42 : 0, estimatedBytes: 1000, isFavorite: false,
                             isEdited: false, isScreenshot: false, burstIdentifier: nil, availability: availability)
    }
}

private actor AlbumModelReader: PhotoLibraryReading {
    var collections: [PhotoCollectionDescriptor]
    var members: [PhotoAssetDescriptor]
    var authorization: PhotoAuthorization
    var readFailure = false
    var holdDirectory = false
    var directoryContinuations: [Int: CheckedContinuation<[PhotoCollectionDescriptor], Never>] = [:]
    var holdMembers = false
    var missingCollection = false
    var memberContinuations: [Int: CheckedContinuation<[PhotoAssetDescriptor], Never>] = [:]
    private(set) var directoryRequests = 0
    private(set) var memberRequests: [String] = []

    init(collections: [PhotoCollectionDescriptor], members: [PhotoAssetDescriptor] = [], authorization: PhotoAuthorization = .authorized) {
        self.collections = collections
        self.members = members
        self.authorization = authorization
    }

    func authorizationStatus() -> PhotoAuthorization { authorization }
    func requestAuthorization() -> PhotoAuthorization { authorization }
    func albumCollections() async throws -> [PhotoCollectionDescriptor] {
        directoryRequests += 1
        if readFailure { throw AlbumModelTestError.readFailed }
        if holdDirectory {
            let request = directoryRequests
            return await withCheckedContinuation { directoryContinuations[request] = $0 }
        }
        return collections
    }
    func assets(inCollection id: String) async throws -> [PhotoAssetDescriptor] {
        memberRequests.append(id)
        if readFailure { throw AlbumModelTestError.readFailed }
        if missingCollection { throw PhotoLibraryReadError.collectionUnavailable }
        if holdMembers {
            let request = memberRequests.count
            return await withCheckedContinuation { memberContinuations[request] = $0 }
        }
        return members
    }
    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> { AsyncStream { $0.finish() } }
    func setReadFailure(_ value: Bool) { readFailure = value }
    func setCollections(_ value: [PhotoCollectionDescriptor]) { collections = value }
    func setAuthorization(_ value: PhotoAuthorization) { authorization = value }
    func setHoldDirectory(_ value: Bool) { holdDirectory = value }
    func setHoldMembers(_ value: Bool) { holdMembers = value }
    func setMissingCollection(_ value: Bool) { missingCollection = value }
    func waitForDirectoryRequests(_ count: Int, tasks: [Task<Void, Never>]) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if directoryContinuations[count] != nil { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        await finishPendingRequests(tasks: tasks)
        return false
    }
    func resolveDirectory(_ request: Int, collections: [PhotoCollectionDescriptor]) {
        directoryContinuations.removeValue(forKey: request)?.resume(returning: collections)
    }
    func waitForMemberRequests(_ count: Int, tasks: [Task<Void, Never>]) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if memberContinuations[count] != nil { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        await finishPendingRequests(tasks: tasks)
        return false
    }
    func resolveMembers(_ request: Int, members: [PhotoAssetDescriptor]) {
        memberContinuations.removeValue(forKey: request)?.resume(returning: members)
    }

    private func finishPendingRequests(tasks: [Task<Void, Never>]) async {
        for task in tasks { task.cancel() }
        holdDirectory = false
        holdMembers = false
        let pendingDirectories = directoryContinuations.values
        let pendingMembers = memberContinuations.values
        directoryContinuations = [:]
        memberContinuations = [:]
        for continuation in pendingDirectories { continuation.resume(returning: []) }
        for continuation in pendingMembers { continuation.resume(returning: []) }
        for task in tasks { await task.value }
    }
}

private enum AlbumModelTestError: Error { case readFailed }

private actor AlbumModelMutator: PhotoLibraryMutating {
    let backendMode = MutationBackendMode.live
    var holdCreation: Bool
    let result: PhotoAlbumDescriptor?
    var continuation: CheckedContinuation<PhotoAlbumDescriptor?, Never>?
    private(set) var createRequests: [String] = []
    private(set) var archiveCalls = 0
    private(set) var deleteCalls = 0
    private(set) var listCalls = 0

    init(holdCreation: Bool = false, result: PhotoAlbumDescriptor? = nil) {
        self.holdCreation = holdCreation
        self.result = result
    }

    func availableAssetIDs(for requestedIDs: [String]) -> Set<String> { Set(requestedIDs) }
    func listAlbums() -> [PhotoAlbumDescriptor] { listCalls += 1; return [] }
    func createAlbum(named title: String) async -> PhotoAlbumDescriptor? {
        createRequests.append(title)
        if holdCreation { return await withCheckedContinuation { continuation = $0 } }
        return result
    }
    func archivedAssetIDs(for requestedIDs: [String], inAlbumID albumID: String) -> Set<String> { [] }
    func addAssets(withIDs assetIDs: [String], toAlbumID albumID: String) -> PhotoMutationBatch {
        archiveCalls += 1
        return PhotoMutationBatch(operation: .archive, items: [], targetAlbumID: albumID)
    }
    func deleteAssets(withIDs assetIDs: [String]) -> PhotoMutationBatch {
        deleteCalls += 1
        return PhotoMutationBatch(operation: .delete, items: [], targetAlbumID: nil)
    }
    func waitForCreation(task: Task<Void, Never>) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if continuation != nil { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        holdCreation = false
        resolveCreation(nil)
        await task.value
        return false
    }
    func resolveCreation(_ album: PhotoAlbumDescriptor?) {
        continuation?.resume(returning: album)
        continuation = nil
    }
}
