import Foundation

nonisolated enum CleanupResultSource: Codable, Hashable, Sendable {
    case transaction(String)
    case summary(UUID)
}

nonisolated enum AppRoute: Codable, Hashable, Sendable {
    case duplicates
    case taskDashboard
    case diagnosis
    case task(String)
    case comparison(String)
    case decision(String)
    case albumSelection(String)
    case collection(String)
    case deleteReview
    case result(CleanupResultSource)
    case weeklyInbox
    case decideLater
    case protectedPhotos
}
