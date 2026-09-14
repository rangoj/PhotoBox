import Foundation

nonisolated struct LibraryScanSnapshot: Codable, Equatable, Sendable {
    nonisolated enum Phase: String, Codable, Equatable, Sendable {
        case idle
        case discovering
        case checkingLocalAvailability
        case cancelled
        case completed
        case failed
    }

    var phase: Phase
    var discoveredCount: Int
    var processedCount: Int
    var localCount: Int
    var iCloudOnlyCount: Int
    var unavailableCount: Int
    var screenshotCount: Int
    var largeVideoCount: Int
    var userAlbumCount: Int
    var errorMessage: String?

    nonisolated static let idle = LibraryScanSnapshot(
        phase: .idle,
        discoveredCount: 0,
        processedCount: 0,
        localCount: 0,
        iCloudOnlyCount: 0,
        unavailableCount: 0,
        screenshotCount: 0,
        largeVideoCount: 0,
        userAlbumCount: 0,
        errorMessage: nil
    )

    nonisolated static var starting: LibraryScanSnapshot {
        var snapshot = idle
        snapshot.phase = .discovering
        return snapshot
    }

    nonisolated var progress: Double {
        guard discoveredCount > 0 else { return phase == .completed ? 1 : 0 }
        return min(Double(processedCount) / Double(discoveredCount), 1)
    }

    nonisolated var isScanning: Bool {
        phase == .discovering || phase == .checkingLocalAvailability
    }
}
