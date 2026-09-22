import Foundation

nonisolated enum MutationBackendMode: String, Codable, Equatable, Sendable {
    case simulated
    case live
}

nonisolated enum MutationReconciliationMode: Sendable {
    case conservative
    case deterministicSimulation
}

nonisolated enum AppBuildConfiguration: Sendable {
    case debug
    case release
}

nonisolated enum MutationComposition {
    static func make(
        build: AppBuildConfiguration,
        isUITesting: Bool,
        debugRealMutationEnabled: Bool,
        simulatedAssetIDs: Set<String> = []
    ) -> any PhotoLibraryMutating {
        if isUITesting {
            return SimulatedPhotoLibraryMutator(assetIDs: simulatedAssetIDs)
        }
        switch build {
        case .debug:
            return debugRealMutationEnabled
                ? LivePhotoLibraryMutator()
                : SimulatedPhotoLibraryMutator(assetIDs: simulatedAssetIDs)
        case .release:
            return LivePhotoLibraryMutator()
        }
    }

    static func current(
        settings: WorkflowSettings,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        simulatedAssetIDs: Set<String> = []
    ) -> any PhotoLibraryMutating {
        #if DEBUG
        let build = AppBuildConfiguration.debug
        #else
        let build = AppBuildConfiguration.release
        #endif
        return make(
            build: build,
            isUITesting: arguments.contains { $0.hasPrefix("--ui-testing-") },
            debugRealMutationEnabled: settings.debugRealMutationEnabled,
            simulatedAssetIDs: simulatedAssetIDs
        )
    }

    static func modeLabel(for mode: MutationBackendMode) -> String {
        switch mode {
        case .simulated: "模拟模式（不会修改系统照片）"
        case .live: "真实 PhotoKit 模式"
        }
    }
}

nonisolated struct PhotoAlbumDescriptor: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let assetCount: Int
    let coverAssetID: String?

    init(id: String, title: String, assetCount: Int, coverAssetID: String? = nil) {
        self.id = id
        self.title = title
        self.assetCount = assetCount
        self.coverAssetID = coverAssetID
    }

    enum CodingKeys: String, CodingKey { case id, title, assetCount, coverAssetID }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        assetCount = try values.decode(Int.self, forKey: .assetCount)
        coverAssetID = try values.decodeIfPresent(String.self, forKey: .coverAssetID)
    }
}

nonisolated struct PhotoMutationBatch: Equatable, Sendable {
    let operation: MutationOperation
    let items: [MutationItem]
    let targetAlbumID: String?
}

nonisolated protocol PhotoLibraryMutating: Sendable {
    var backendMode: MutationBackendMode { get async }
    var reconciliationMode: MutationReconciliationMode { get async }
    func availableAssetIDs(for requestedIDs: [String]) async -> Set<String>
    func listAlbums() async -> [PhotoAlbumDescriptor]
    func createAlbum(named title: String) async -> PhotoAlbumDescriptor?
    func archivedAssetIDs(for requestedIDs: [String], inAlbumID albumID: String) async -> Set<String>
    func addAssets(withIDs assetIDs: [String], toAlbumID albumID: String) async -> PhotoMutationBatch
    func deleteAssets(withIDs assetIDs: [String]) async -> PhotoMutationBatch
}

nonisolated protocol PhotoFavoriteMutating: Sendable {
    func setFavorite(_ isFavorite: Bool, forAssetID assetID: String) async -> Bool
}

extension PhotoLibraryMutating {
    var reconciliationMode: MutationReconciliationMode { .conservative }
}

actor SimulatedPhotoLibraryMutator: PhotoLibraryMutating, PhotoFavoriteMutating {
    let backendMode = MutationBackendMode.simulated
    let reconciliationMode: MutationReconciliationMode
    private var assetIDs: Set<String>
    private var albums: [String: SimulatedAlbum]
    private var configuredOutcomes: [String: MutationItemState]
    private var albumIDsMissingOnArchive: Set<String>
    private let albumCreationFails: Bool
    private(set) var submittedAssetIDs: [String] = []
    private(set) var createAlbumRequests: [String] = []
    private var mutationCallCount = 0
    private var favoriteAssetIDs: Set<String> = []

    init(
        assetIDs: Set<String> = [],
        albums: [PhotoAlbumDescriptor] = [],
        configuredOutcomes: [String: MutationItemState] = [:],
        albumIDsMissingOnArchive: Set<String> = [],
        albumCreationFails: Bool = false,
        reconciliationMode: MutationReconciliationMode = .conservative
    ) {
        self.assetIDs = assetIDs
        self.albums = Dictionary(uniqueKeysWithValues: albums.map {
            ($0.id, SimulatedAlbum(id: $0.id, title: $0.title, assetIDs: []))
        })
        self.configuredOutcomes = configuredOutcomes
        self.albumIDsMissingOnArchive = albumIDsMissingOnArchive
        self.albumCreationFails = albumCreationFails
        self.reconciliationMode = reconciliationMode
    }

    func availableAssetIDs(for requestedIDs: [String]) -> Set<String> {
        assetIDs.intersection(requestedIDs)
    }

    func setOutcome(_ state: MutationItemState, for assetID: String) {
        configuredOutcomes[assetID] = state
    }

    func listAlbums() -> [PhotoAlbumDescriptor] {
        albums.values
            .map { PhotoAlbumDescriptor(id: $0.id, title: $0.title, assetCount: $0.assetIDs.count) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func createAlbum(named title: String) -> PhotoAlbumDescriptor? {
        mutationCallCount += 1
        createAlbumRequests.append(title)
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !albumCreationFails else { return nil }
        let album = SimulatedAlbum(id: UUID().uuidString, title: trimmed, assetIDs: [])
        albums[album.id] = album
        return PhotoAlbumDescriptor(id: album.id, title: album.title, assetCount: 0)
    }

    func archivedAssetIDs(for requestedIDs: [String], inAlbumID albumID: String) -> Set<String> {
        guard let album = albums[albumID] else { return [] }
        return album.assetIDs.intersection(requestedIDs)
    }

    func addAssets(
        withIDs requestedIDs: [String],
        toAlbumID albumID: String
    ) -> PhotoMutationBatch {
        mutationCallCount += 1
        submittedAssetIDs.append(contentsOf: requestedIDs)
        if albumIDsMissingOnArchive.remove(albumID) != nil {
            albums.removeValue(forKey: albumID)
        }
        guard var album = albums[albumID] else {
            return PhotoMutationBatch(
                operation: .archive,
                items: requestedIDs.map { MutationItem(assetID: $0, state: .failed) },
                targetAlbumID: albumID
            )
        }
        let items = outcomes(for: requestedIDs)
        album.assetIDs.formUnion(items.filter { $0.state == .succeeded }.map(\.assetID))
        albums[albumID] = album
        return PhotoMutationBatch(operation: .archive, items: items, targetAlbumID: albumID)
    }

    func deleteAssets(withIDs requestedIDs: [String]) -> PhotoMutationBatch {
        mutationCallCount += 1
        submittedAssetIDs.append(contentsOf: requestedIDs)
        let items = outcomes(for: requestedIDs)
        assetIDs.subtract(items.filter { $0.state == .succeeded }.map(\.assetID))
        return PhotoMutationBatch(operation: .delete, items: items, targetAlbumID: nil)
    }

    func setFavorite(_ isFavorite: Bool, forAssetID assetID: String) -> Bool {
        guard assetIDs.contains(assetID) else { return false }
        if isFavorite { favoriteAssetIDs.insert(assetID) } else { favoriteAssetIDs.remove(assetID) }
        return true
    }

    func inventoryFingerprint() -> String {
        let assets = assetIDs.sorted().joined(separator: ",")
        let albumContents = albums.values
            .sorted { $0.id < $1.id }
            .map { "\($0.id):\($0.title)[\($0.assetIDs.sorted().joined(separator: ","))]" }
            .joined(separator: ",")
        return "assets=\(assets)|albums=\(albumContents)|mutationCalls=\(mutationCallCount)"
    }

    private func outcomes(for requestedIDs: [String]) -> [MutationItem] {
        requestedIDs.map { assetID in
            MutationItem(
                assetID: assetID,
                state: configuredOutcomes[assetID] ?? (assetIDs.contains(assetID) ? .succeeded : .stale)
            )
        }
    }
}

@MainActor
final class MutationCoordinator {
    private let repository: any TaskRepository
    private let mutator: any PhotoLibraryMutating

    init(repository: any TaskRepository, mutator: any PhotoLibraryMutating) {
        self.repository = repository
        self.mutator = mutator
    }

    func submit(
        operation: MutationOperation,
        assetIDs: [String],
        targetAlbumID: String? = nil
    ) async throws -> MutationTransaction {
        guard operation != .createAlbum else {
            throw MutationCoordinatorError.invalidAlbumCreation
        }
        let requestedIDs = unique(assetIDs)
        let backendMode = await mutator.backendMode
        let availableIDs = await mutator.availableAssetIDs(for: requestedIDs)
        var transaction = MutationTransaction(
            id: UUID().uuidString,
            operation: operation,
            items: requestedIDs.map {
                MutationItem(assetID: $0, state: availableIDs.contains($0) ? .pending : .stale)
            },
            targetAlbumID: targetAlbumID,
            backendMode: backendMode
        )
        try repository.save(transaction: transaction)
        return try await executePendingItems(in: &transaction)
    }

    func submitArchive(
        decision: PhotoDecision,
        recentAlbumIDs: [String]
    ) async throws -> MutationTransaction {
        guard decision.kind == .archive,
              decision.isSubmitted,
              let albumID = decision.targetAlbumID else {
            throw MutationCoordinatorError.invalidArchiveDecision
        }
        let interruptedArchives = try repository.transactions().filter {
            $0.operation == .archive
                && $0.targetAlbumID == albumID
                && $0.items.contains(where: {
                    $0.assetID == decision.assetID && $0.state == .submitted
                })
        }
        if let incomplete = interruptedArchives.last(where: {
            $0.archiveDecision?.assetID != decision.assetID
                || $0.archiveDecision?.targetAlbumID != albumID
                || $0.recentAlbumIDs == nil
                || $0.backendMode == nil
        }) {
            throw MutationCoordinatorError.incompleteLegacyArchiveRecovery(incomplete.id)
        }
        if var interrupted = interruptedArchives.last {
            try validateBackend(interrupted, actual: await mutator.backendMode)
            return try await reconcileArchive(in: &interrupted)
        }
        let backendMode = await mutator.backendMode
        let availableIDs = await mutator.availableAssetIDs(for: [decision.assetID])
        var transaction = MutationTransaction(
            id: UUID().uuidString,
            operation: .archive,
            items: [MutationItem(
                assetID: decision.assetID,
                state: availableIDs.contains(decision.assetID) ? .pending : .stale
            )],
            targetAlbumID: albumID,
            archiveDecision: decision,
            recentAlbumIDs: recentAlbumIDs,
            backendMode: backendMode
        )
        try repository.save(transaction: transaction)
        return try await executePendingItems(in: &transaction)
    }

    /// Adds album membership without completing a decision or advancing its
    /// task. The submitted journal remains recoverable until settings are saved.
    func submitArchiveTarget(
        assetID: String,
        targetAlbumID: String,
        recentAlbumIDs: [String]
    ) async throws -> MutationTransaction {
        let interruptedArchives = try repository.transactions().filter {
            $0.operation == .archive
                && $0.targetAlbumID == targetAlbumID
                && $0.archiveDecision == nil
                && $0.items.contains(where: {
                    $0.assetID == assetID && $0.state == .submitted
                })
        }
        if var interrupted = interruptedArchives.last {
            try validateBackend(interrupted, actual: await mutator.backendMode)
            return try await reconcileArchive(in: &interrupted)
        }

        let backendMode = await mutator.backendMode
        let availableIDs = await mutator.availableAssetIDs(for: [assetID])
        var transaction = MutationTransaction(
            id: UUID().uuidString,
            operation: .archive,
            items: [MutationItem(
                assetID: assetID,
                state: availableIDs.contains(assetID) ? .pending : .stale
            )],
            targetAlbumID: targetAlbumID,
            recentAlbumIDs: recentAlbumIDs,
            backendMode: backendMode
        )
        try repository.save(transaction: transaction)
        return try await executePendingItems(in: &transaction)
    }

    func createAlbum(named title: String, forAssetID assetID: String) async throws -> PhotoAlbumDescriptor? {
        let transactions = try repository.transactions()
        if var existing = transactions.last(where: {
            $0.operation == .createAlbum
                && $0.albumTitle == title
                && $0.items.contains(where: { $0.assetID == assetID })
        }) {
            try validateBackend(existing, actual: await mutator.backendMode)
            let albums = await mutator.listAlbums()
            if existing.items.contains(where: { $0.state == .succeeded }),
               let albumID = existing.targetAlbumID,
               let album = albums.first(where: { $0.id == albumID }) {
                return album
            }
            if existing.items.contains(where: { $0.state == .submitted }) {
                let recovered = try reconcileSubmittedAlbumCreation(
                    in: &existing,
                    albums: albums
                )
                if let recovered { return recovered }
                if existing.items.contains(where: { $0.state == .submitted }) {
                    return nil
                }
            }
            if existing.items.contains(where: { $0.state == .pending || $0.state == .failed }) {
                prepareAlbumCreation(&existing, albumIDsBeforeCreation: albums.map(\.id))
                try repository.save(transaction: existing)
                return try await executeAlbumCreation(in: &existing)
            }
        }

        let albums = await mutator.listAlbums()
        let backendMode = await mutator.backendMode
        var transaction = MutationTransaction(
            id: UUID().uuidString,
            operation: .createAlbum,
            items: [MutationItem(assetID: assetID, state: .pending)],
            albumTitle: title,
            albumIDsBeforeCreation: albums.map(\.id),
            backendMode: backendMode
        )
        try repository.save(transaction: transaction)
        return try await executeAlbumCreation(in: &transaction)
    }

    func retry(transactionID: String) async throws -> MutationTransaction {
        guard let transaction = try repository.transactions().first(where: { $0.id == transactionID }) else {
            throw MutationCoordinatorError.transactionNotFound(transactionID)
        }
        let retryableStates: Set<MutationItemState> = [.failed, .cancelled, .pending]
        return try await retry(
            transactionID: transaction.id,
            assetIDs: transaction.items
                .filter { retryableStates.contains($0.state) }
                .map(\.assetID)
        )
    }

    func retry(
        transactionID: String,
        assetIDs: [String]
    ) async throws -> MutationTransaction {
        guard var transaction = try repository.transactions().first(where: { $0.id == transactionID }) else {
            throw MutationCoordinatorError.transactionNotFound(transactionID)
        }
        guard transaction.operation != .createAlbum else {
            throw MutationCoordinatorError.invalidAlbumCreation
        }
        try validateBackend(transaction, actual: await mutator.backendMode)
        let retryableStates: Set<MutationItemState> = [.failed, .cancelled, .pending]
        let retryableIDs = Set(transaction.items
            .filter { retryableStates.contains($0.state) }
            .map(\.assetID))
        let requestedIDs = unique(assetIDs)
        guard Set(requestedIDs).isSubset(of: retryableIDs) else {
            throw MutationCoordinatorError.invalidRetrySelection(transactionID)
        }
        guard !requestedIDs.isEmpty else { return transaction }
        let availableIDs = await mutator.availableAssetIDs(for: requestedIDs)
        for index in transaction.items.indices
        where requestedIDs.contains(transaction.items[index].assetID)
            && retryableStates.contains(transaction.items[index].state) {
            transaction.items[index].state = availableIDs.contains(transaction.items[index].assetID)
                ? .pending
                : .stale
        }
        try repository.save(transaction: transaction)
        return try await executePendingItems(in: &transaction, selectedIDs: Set(requestedIDs))
    }

    func reconcileInterruptedTransactions() async throws {
        let actualBackend = await mutator.backendMode
        var firstBackendError: MutationCoordinatorError?
        for var transaction in try repository.transactions()
        where transaction.items.contains(where: { $0.state == .submitted }) {
            do {
                try validateBackend(transaction, actual: actualBackend)
            } catch let error as MutationCoordinatorError {
                firstBackendError = firstBackendError ?? error
                continue
            }
            switch transaction.operation {
            case .createAlbum:
                let albums = await mutator.listAlbums()
                _ = try reconcileSubmittedAlbumCreation(in: &transaction, albums: albums)
            case .archive:
                _ = try await reconcileArchive(in: &transaction)
            case .delete:
                try await reconcileSubmittedDelete(in: &transaction)
            }
        }
        if let firstBackendError {
            throw firstBackendError
        }
    }

    @discardableResult
    func reconcileInterruptedDeleteTransactions() async throws -> MutationTransaction? {
        let actualBackend = await mutator.backendMode
        var firstBackendError: MutationCoordinatorError?
        var reconciledTransaction: MutationTransaction?
        for var transaction in try repository.transactions() where transaction.operation == .delete {
            if transaction.items.contains(where: { $0.state == .submitted }) {
                do {
                    try validateBackend(transaction, actual: actualBackend)
                    try await reconcileSubmittedDelete(in: &transaction)
                    reconciledTransaction = transaction
                } catch let error as MutationCoordinatorError {
                    firstBackendError = firstBackendError ?? error
                }
            } else {
                if try markSuccessfulDecisionsSubmitted(transaction.items) {
                    reconciledTransaction = transaction
                }
            }
        }
        if let firstBackendError {
            throw firstBackendError
        }
        return reconciledTransaction
    }

    func reconcileInterruptedDeleteTransaction(id: String) async throws -> MutationTransaction {
        guard var transaction = try repository.transactions().first(where: { $0.id == id }) else {
            throw MutationCoordinatorError.transactionNotFound(id)
        }
        guard transaction.operation == .delete else { return transaction }
        if transaction.items.contains(where: { $0.state == .submitted }) {
            try validateBackend(transaction, actual: await mutator.backendMode)
            try await reconcileSubmittedDelete(in: &transaction)
        } else {
            _ = try markSuccessfulDecisionsSubmitted(transaction.items)
        }
        return transaction
    }

    private func executePendingItems(
        in transaction: inout MutationTransaction,
        selectedIDs: Set<String>? = nil
    ) async throws -> MutationTransaction {
        guard transaction.operation != .createAlbum else {
            throw MutationCoordinatorError.invalidAlbumCreation
        }
        let pendingIDs = transaction.items
            .filter { item in
                item.state == .pending && (selectedIDs == nil || selectedIDs!.contains(item.assetID))
            }
            .map(\.assetID)
        guard !pendingIDs.isEmpty else {
            transaction.completedAt = .now
            try repository.save(transaction: transaction)
            return transaction
        }

        for index in transaction.items.indices
        where transaction.items[index].state == .pending
            && (selectedIDs == nil || selectedIDs!.contains(transaction.items[index].assetID)) {
            transaction.items[index].state = .submitted
        }
        transaction.submittedAt = .now
        transaction.completedAt = nil
        try repository.save(transaction: transaction)

        let result: PhotoMutationBatch
        switch transaction.operation {
        case .createAlbum:
            throw MutationCoordinatorError.invalidAlbumCreation
        case .delete:
            result = await mutator.deleteAssets(withIDs: pendingIDs)
        case .archive:
            guard let albumID = transaction.targetAlbumID else {
                result = PhotoMutationBatch(
                    operation: .archive,
                    items: pendingIDs.map { MutationItem(assetID: $0, state: .failed) },
                    targetAlbumID: nil
                )
                break
            }
            result = await mutator.addAssets(withIDs: pendingIDs, toAlbumID: albumID)
        }

        let resultsByID = Dictionary(uniqueKeysWithValues: result.items.map { ($0.assetID, $0) })
        for index in transaction.items.indices
        where transaction.items[index].state == .submitted {
            guard let resultItem = resultsByID[transaction.items[index].assetID] else { continue }
            transaction.items[index] = resultItem
        }
        transaction.completedAt = .now
        if let archiveDecision = transaction.archiveDecision,
           transaction.items.contains(where: {
               $0.assetID == archiveDecision.assetID && $0.state == .succeeded
           }) {
            try repository.completeArchive(
                transaction: transaction,
                decision: archiveDecision,
                recentAlbumIDs: transaction.recentAlbumIDs ?? []
            )
        } else {
            try finalizeMembershipSettings(for: transaction)
            try repository.save(transaction: transaction)
            if transaction.operation == .delete {
                try markSuccessfulDecisionsSubmitted(transaction.items)
            }
        }
        return transaction
    }

    private func reconcileArchive(in transaction: inout MutationTransaction) async throws -> MutationTransaction {
        let submittedIDs = transaction.items
            .filter { $0.state == .submitted }
            .map(\.assetID)
        let archivedIDs: Set<String>
        if let albumID = transaction.targetAlbumID {
            archivedIDs = await mutator.archivedAssetIDs(
                for: submittedIDs,
                inAlbumID: albumID
            )
        } else {
            archivedIDs = []
        }
        for index in transaction.items.indices where transaction.items[index].state == .submitted {
            transaction.items[index].state = archivedIDs.contains(transaction.items[index].assetID)
                ? .succeeded
                : .failed
        }
        transaction.completedAt = .now
        if let decision = transaction.archiveDecision,
           transaction.items.contains(where: {
               $0.assetID == decision.assetID && $0.state == .succeeded
           }) {
            try repository.completeArchive(
                transaction: transaction,
                decision: decision,
                recentAlbumIDs: transaction.recentAlbumIDs ?? []
            )
        } else {
            try finalizeMembershipSettings(for: transaction)
            try repository.save(transaction: transaction)
        }
        return transaction
    }

    private func finalizeMembershipSettings(for transaction: MutationTransaction) throws {
        guard transaction.operation == .archive,
              transaction.archiveDecision == nil,
              let recentAlbumIDs = transaction.recentAlbumIDs,
              transaction.items.contains(where: { $0.state == .succeeded }) else { return }
        // Save settings before the terminal journal state. If either save fails,
        // recovery checks membership and repeats only this local finalization.
        var settings = try repository.settings()
        settings.recentAlbumIDs = recentAlbumIDs
        try repository.save(settings: settings)
    }

    private func reconcileSubmittedDelete(in transaction: inout MutationTransaction) async throws {
        let submittedIDs = transaction.items
            .filter { $0.state == .submitted }
            .map(\.assetID)
        guard !submittedIDs.isEmpty else { return }
        let availableIDs = await mutator.availableAssetIDs(for: submittedIDs)
        let reconciliationMode = await mutator.reconciliationMode
        // Simulated deletion has no remaining identifiers to fetch. Live
        // PhotoKit results remain ambiguous when permission scope changed.
        guard !availableIDs.isEmpty else {
            if transaction.backendMode == .simulated,
               reconciliationMode == .deterministicSimulation {
                for index in transaction.items.indices where transaction.items[index].state == .submitted {
                    transaction.items[index].state = .succeeded
                }
                transaction.completedAt = .now
                try repository.save(transaction: transaction)
                try markSuccessfulDecisionsSubmitted(transaction.items)
                return
            }
            for index in transaction.items.indices where transaction.items[index].state == .submitted {
                transaction.items[index].state = .failed
                transaction.items[index].errorCode = "reconciliation-unavailable"
            }
            transaction.completedAt = .now
            try repository.save(transaction: transaction)
            return
        }
        for index in transaction.items.indices where transaction.items[index].state == .submitted {
            transaction.items[index].state = availableIDs.contains(transaction.items[index].assetID)
                ? .failed
                : .succeeded
        }
        transaction.completedAt = .now
        try repository.save(transaction: transaction)
        try markSuccessfulDecisionsSubmitted(transaction.items)
    }

    private func executeAlbumCreation(
        in transaction: inout MutationTransaction
    ) async throws -> PhotoAlbumDescriptor? {
        guard let title = transaction.albumTitle else {
            throw MutationCoordinatorError.invalidAlbumCreation
        }
        transaction.items = transaction.items.map {
            MutationItem(assetID: $0.assetID, state: .submitted)
        }
        transaction.submittedAt = .now
        transaction.completedAt = nil
        try repository.save(transaction: transaction)

        if let album = await mutator.createAlbum(named: title) {
            completeAlbumCreation(&transaction, album: album)
            try repository.save(transaction: transaction)
            return album
        }

        let albums = await mutator.listAlbums()
        if let recovered = try reconcileSubmittedAlbumCreation(in: &transaction, albums: albums) {
            return recovered
        }
        return nil
    }

    private func reconcileSubmittedAlbumCreation(
        in transaction: inout MutationTransaction,
        albums: [PhotoAlbumDescriptor]
    ) throws -> PhotoAlbumDescriptor? {
        guard let title = transaction.albumTitle else {
            throw MutationCoordinatorError.invalidAlbumCreation
        }
        let priorIDs = Set(transaction.albumIDsBeforeCreation ?? [])
        let candidates = albums.filter { !priorIDs.contains($0.id) && $0.title == title }
        if candidates.count == 1, let album = candidates.first {
            completeAlbumCreation(&transaction, album: album)
            try repository.save(transaction: transaction)
            return album
        }
        return nil
    }

    private func prepareAlbumCreation(
        _ transaction: inout MutationTransaction,
        albumIDsBeforeCreation: [String]
    ) {
        transaction.items = transaction.items.map {
            MutationItem(assetID: $0.assetID, state: .pending)
        }
        transaction.targetAlbumID = nil
        transaction.albumIDsBeforeCreation = albumIDsBeforeCreation
        transaction.submittedAt = nil
        transaction.completedAt = nil
    }

    private func completeAlbumCreation(
        _ transaction: inout MutationTransaction,
        album: PhotoAlbumDescriptor
    ) {
        transaction.items = transaction.items.map {
            MutationItem(assetID: $0.assetID, state: .succeeded)
        }
        transaction.targetAlbumID = album.id
        transaction.completedAt = .now
    }

    @discardableResult
    private func markSuccessfulDecisionsSubmitted(_ items: [MutationItem]) throws -> Bool {
        var didSubmitDecision = false
        for item in items where item.state == .succeeded {
            guard let decision = try repository.decision(for: item.assetID),
                  !decision.isSubmitted else { continue }
            try repository.save(decision: PhotoDecision(
                assetID: decision.assetID,
                kind: decision.kind,
                estimatedBytes: decision.estimatedBytes,
                targetAlbumID: decision.targetAlbumID,
                taskID: decision.taskID,
                createdAt: decision.createdAt,
                isSubmitted: true
            ))
            didSubmitDecision = true
        }
        return didSubmitDecision
    }

    private func validateBackend(
        _ transaction: MutationTransaction,
        actual: MutationBackendMode
    ) throws {
        guard let expected = transaction.backendMode else {
            throw MutationCoordinatorError.missingBackendIdentity(transaction.id)
        }
        guard expected == actual else {
            throw MutationCoordinatorError.backendMismatch(
                transactionID: transaction.id,
                expected: expected,
                actual: actual
            )
        }
    }

    private func unique(_ assetIDs: [String]) -> [String] {
        var seen: Set<String> = []
        return assetIDs.filter { seen.insert($0).inserted }
    }
}

nonisolated enum MutationCoordinatorError: Error, Equatable {
    case transactionNotFound(String)
    case invalidRetrySelection(String)
    case invalidArchiveDecision
    case invalidAlbumCreation
    case missingBackendIdentity(String)
    case incompleteLegacyArchiveRecovery(String)
    case backendMismatch(
        transactionID: String,
        expected: MutationBackendMode,
        actual: MutationBackendMode
    )
}

private nonisolated struct SimulatedAlbum: Sendable {
    let id: String
    let title: String
    var assetIDs: Set<String>
}
