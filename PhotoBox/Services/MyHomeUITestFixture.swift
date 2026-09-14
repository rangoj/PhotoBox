#if DEBUG
import Foundation

enum MyHomeUITestFixture {
    @MainActor
    static func makeModel(arguments: [String]) -> AppModel {
        let repository = try! SwiftDataTaskRepository(inMemory: true)
        if !arguments.contains("--ui-testing-my-empty") {
            let date = Date(timeIntervalSince1970: 1_789_344_000)
            let decisions = (1...12).map {
                PhotoDecision(assetID: "my-keep-\($0)", kind: .keep, createdAt: date)
            }
            try! repository.save(decisions: decisions)
            try! repository.save(summary: CleanupSummary(decisions: decisions, elapsedSeconds: 60, createdAt: date))
            try! repository.save(transaction: MutationTransaction(id: "my-live", operation: .delete,
                items: [.init(assetID: "my-deleted", state: .succeeded)],
                createdAt: date, completedAt: date, backendMode: .live))
            try! repository.save(transaction: MutationTransaction(id: "my-simulated", operation: .delete,
                items: [.init(assetID: "my-simulated", state: .succeeded)],
                createdAt: date, completedAt: date, backendMode: .simulated))
        }
        let readState = MyHomeFixtureReadState()
        readState.failures = arguments.contains("--ui-testing-my-history-failure") ? 2
            : (arguments.contains("--ui-testing-my-failure") ? 1 : 0)
        let model = AppModel(library: UITestPhotoLibraryService(authorization: .authorized),
            repository: repository, mutator: SimulatedPhotoLibraryMutator(),
            initialScan: UITestPhotoLibraryService.snapshot(for: .completed), initialInventory: LibraryInventory(),
            myHomeReader: {
                if readState.failures > 0 {
                    readState.failures -= 1
                    throw CocoaError(.fileReadCorruptFile)
                }
                return try MyHomeSnapshot(repository: repository)
            })
        model.authorization = .authorized
        model.hasLoadedAuthorization = true
        return model
    }
}

@MainActor
private final class MyHomeFixtureReadState {
    var failures = 0
}
#endif
