import Foundation

nonisolated struct PhotoLibraryChange: Equatable, Sendable {
    let addedAssetIDs: [String]
    let removedAssetIDs: [String]
    let scopeChanged: Bool
}

nonisolated struct LibraryInventory: Equatable, Sendable {
    private(set) var descriptors: [PhotoAssetDescriptor]

    init(descriptors: [PhotoAssetDescriptor] = []) {
        self.descriptors = descriptors
    }

    mutating func merge(
        _ change: PhotoLibraryChange,
        addedDescriptors: [PhotoAssetDescriptor]
    ) {
        let removedIDs = Set(change.removedAssetIDs)
        let addedIDs = Set(change.addedAssetIDs)
        descriptors.removeAll { removedIDs.contains($0.id) || addedIDs.contains($0.id) }

        let additionsByID = Dictionary(
            uniqueKeysWithValues: addedDescriptors.map { ($0.id, $0) }
        )
        descriptors.append(contentsOf: change.addedAssetIDs.compactMap { additionsByID[$0] })
    }
}

actor LibraryInventoryStore {
    private var inventory: LibraryInventory?

    func replace(with descriptors: [PhotoAssetDescriptor]) {
        inventory = LibraryInventory(descriptors: descriptors)
    }

    func merge(
        _ change: PhotoLibraryChange,
        addedDescriptors: [PhotoAssetDescriptor]
    ) {
        var current = inventory ?? LibraryInventory()
        current.merge(change, addedDescriptors: addedDescriptors)
        inventory = current
    }

    func snapshot() -> [PhotoAssetDescriptor]? {
        inventory?.descriptors
    }

    func clear() {
        inventory = nil
    }
}
