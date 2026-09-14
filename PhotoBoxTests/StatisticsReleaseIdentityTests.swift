#if !DEBUG
import Foundation
import SwiftData
import Testing
@testable import PhotoBox

@Suite("Statistics Release composition")
struct StatisticsReleaseIdentityTests {
    // Production break: compiling the Debug-only clear replacement into Release
    // discards an injected live mutator after its first backend-mode read.
    @MainActor
    @Test("Release history clear preserves the injected live mutator")
    func releaseHistoryClearPreservesInjectedLiveMutator() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let mutator = ReleaseIdentityMutator()
        let model = AppModel(
            library: ReleaseIdentityReader(),
            repository: repository,
            mutator: mutator,
            initialScan: .idle
        )

        #expect(await model.clearStatisticsHistory())
        await model.refreshMutationMode()

        #expect(model.mutationBackendMode == .live)
        #expect(await mutator.backendModeReadCount() == 3)
    }
}

private actor ReleaseIdentityReader: PhotoLibraryReading {
    func authorizationStatus() -> PhotoAuthorization { .authorized }
    func requestAuthorization() -> PhotoAuthorization { .authorized }
    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> {
        AsyncStream { $0.finish() }
    }
}

private actor ReleaseIdentityMutator: PhotoLibraryMutating {
    private var backendReads = 0

    var backendMode: MutationBackendMode {
        get async {
            backendReads += 1
            return .live
        }
    }

    func backendModeReadCount() -> Int { backendReads }
    func availableAssetIDs(for requestedIDs: [String]) -> Set<String> { Set(requestedIDs) }
    func listAlbums() -> [PhotoAlbumDescriptor] { [] }
    func createAlbum(named title: String) -> PhotoAlbumDescriptor? { nil }
    func archivedAssetIDs(for requestedIDs: [String], inAlbumID albumID: String) -> Set<String> { [] }
    func addAssets(withIDs assetIDs: [String], toAlbumID albumID: String) -> PhotoMutationBatch {
        PhotoMutationBatch(operation: .archive, items: [], targetAlbumID: albumID)
    }
    func deleteAssets(withIDs assetIDs: [String]) -> PhotoMutationBatch {
        PhotoMutationBatch(operation: .delete, items: [], targetAlbumID: nil)
    }
}
#endif
