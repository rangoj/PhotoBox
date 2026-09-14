import Foundation

nonisolated enum PhotoCollectionKind: String, Codable, Sendable {
    case album
    case favorites
}

nonisolated struct PhotoCollectionDescriptor: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let kind: PhotoCollectionKind
    let title: String
    let assetCount: Int
    let coverAssetID: String?
}
