import Foundation
import UserNotifications

nonisolated enum LocalNotificationAuthorization: String, Codable, Equatable, Sendable {
    case notDetermined
    case denied
    case restricted
    case authorized
    case provisional
    case ephemeral

    var permitsWeeklyReminder: Bool { self == .authorized }
}

nonisolated struct WeeklyNotificationRequest: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
    let weekday: Int

    static func weekly(weekday: Int) -> WeeklyNotificationRequest {
        WeeklyNotificationRequest(
            identifier: "photobox.weekly.cleanup",
            title: "每周照片整理",
            body: "打开 PhotoBox，花几分钟整理本周照片。",
            weekday: weekday
        )
    }
}

nonisolated protocol LocalNotificationServing: Sendable {
    func authorizationStatus() async -> LocalNotificationAuthorization
    func requestAuthorization() async throws -> LocalNotificationAuthorization
    func replaceWeeklyReminder(weekday: Int) async throws
    func removeWeeklyReminder() async throws
}

nonisolated protocol UserNotificationCenterAccessing: Sendable {
    func authorizationStatus() async -> LocalNotificationAuthorization
    func requestAuthorization() async throws -> LocalNotificationAuthorization
    func add(_ request: WeeklyNotificationRequest) async throws
    func removePendingRequests(withIdentifiers identifiers: [String]) async
}

actor LiveLocalNotificationService: LocalNotificationServing {
    private static let weeklyRequestIdentifier = "photobox.weekly.cleanup"
    private let center: any UserNotificationCenterAccessing

    init(center: (any UserNotificationCenterAccessing)? = nil) {
        self.center = center ?? UserNotificationCenterAdapter()
    }

    func authorizationStatus() async -> LocalNotificationAuthorization {
        await center.authorizationStatus()
    }

    func requestAuthorization() async throws -> LocalNotificationAuthorization {
        try await center.requestAuthorization()
    }

    func replaceWeeklyReminder(weekday: Int) async throws {
        guard (1...7).contains(weekday) else {
            throw LocalNotificationServiceError.invalidWeekday(weekday)
        }
        try await center.add(.weekly(weekday: weekday))
    }

    func removeWeeklyReminder() async {
        await center.removePendingRequests(withIdentifiers: [Self.weeklyRequestIdentifier])
    }
}

nonisolated enum LocalNotificationServiceError: Error, Equatable, Sendable {
    case invalidWeekday(Int)
}

actor UserNotificationCenterAdapter: UserNotificationCenterAccessing {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func authorizationStatus() async -> LocalNotificationAuthorization {
        let settings = await center.notificationSettings()
        return LocalNotificationAuthorization(settings.authorizationStatus)
    }

    func requestAuthorization() async throws -> LocalNotificationAuthorization {
        _ = try await center.requestAuthorization(options: [.alert, .sound])
        return await authorizationStatus()
    }

    func add(_ request: WeeklyNotificationRequest) async throws {
        try await center.add(Self.makeRequest(from: request))
    }

    nonisolated static func makeRequest(
        from request: WeeklyNotificationRequest
    ) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: DateComponents(hour: 19, weekday: request.weekday),
            repeats: true
        )
        return UNNotificationRequest(
            identifier: request.identifier,
            content: content,
            trigger: trigger
        )
    }

    func removePendingRequests(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}

private extension LocalNotificationAuthorization {
    nonisolated init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .authorized: self = .authorized
        case .provisional: self = .provisional
        case .ephemeral: self = .ephemeral
        @unknown default: self = .restricted
        }
    }
}

nonisolated struct LocalNotificationRecording: Equatable, Sendable {
    var authorizationStatusReadCount = 0
    var authorizationRequestCount = 0
    var scheduledRequests: [WeeklyNotificationRequest] = []
    var scheduledWeekdays: [Int] = []
    var removalCount = 0
}

nonisolated enum RecordingLocalNotificationPostSnapshotMutation: Sendable {
    case requestAuthorization
    case schedule(weekday: Int)
}

actor RecordingLocalNotificationService: LocalNotificationServing {
    private var authorization: LocalNotificationAuthorization
    private let requestedAuthorization: LocalNotificationAuthorization
    private var state = LocalNotificationRecording()
    private let requestAuthorizationFails: Bool
    private let schedulingFails: Bool
    private var remainingRemovalFailures: Int
    private let postSnapshotMutation: RecordingLocalNotificationPostSnapshotMutation?
    private var didApplyPostSnapshotMutation = false
    private var hasReturnedRecordingSnapshot = false

    init(
        authorization: LocalNotificationAuthorization,
        requestedAuthorization: LocalNotificationAuthorization? = nil,
        requestAuthorizationFails: Bool = false,
        schedulingFails: Bool = false,
        removalFails: Bool = false,
        pendingWeekday: Int? = nil,
        removalFailureCount: Int = 0,
        postSnapshotMutation: RecordingLocalNotificationPostSnapshotMutation? = nil
    ) {
        self.authorization = authorization
        self.requestedAuthorization = requestedAuthorization ?? authorization
        self.requestAuthorizationFails = requestAuthorizationFails
        self.schedulingFails = schedulingFails
        self.remainingRemovalFailures = removalFails ? .max : removalFailureCount
        self.postSnapshotMutation = postSnapshotMutation
        if let pendingWeekday {
            state.scheduledRequests = [.weekly(weekday: pendingWeekday)]
        }
    }

    func authorizationStatus() -> LocalNotificationAuthorization {
        state.authorizationStatusReadCount += 1
        return authorization
    }

    func requestAuthorization() throws -> LocalNotificationAuthorization {
        state.authorizationRequestCount += 1
        if requestAuthorizationFails { throw RecordingLocalNotificationError.authorizationRequest }
        authorization = requestedAuthorization
        return authorization
    }

    func replaceWeeklyReminder(weekday: Int) throws {
        if schedulingFails { throw RecordingLocalNotificationError.scheduling }
        state.scheduledWeekdays.append(weekday)
        state.scheduledRequests = [.weekly(weekday: weekday)]
    }

    func removeWeeklyReminder() throws {
        if remainingRemovalFailures > 0 {
            remainingRemovalFailures -= 1
            throw RecordingLocalNotificationError.removal
        }
        state.removalCount += 1
        state.scheduledRequests.removeAll()
    }

    func recording() -> LocalNotificationRecording {
        let snapshot = state
        defer { hasReturnedRecordingSnapshot = true }
        guard !didApplyPostSnapshotMutation,
              hasReturnedRecordingSnapshot,
              state.authorizationStatusReadCount > 0,
              let postSnapshotMutation else { return snapshot }
        didApplyPostSnapshotMutation = true
        switch postSnapshotMutation {
        case .requestAuthorization:
            state.authorizationRequestCount += 1
            authorization = requestedAuthorization
        case .schedule(let weekday):
            state.scheduledWeekdays.append(weekday)
            state.scheduledRequests = [.weekly(weekday: weekday)]
        }
        return snapshot
    }
}

nonisolated enum RecordingLocalNotificationError: Error, Equatable, Sendable {
    case authorizationRequest
    case scheduling
    case removal
}

nonisolated enum LocalNotificationComposition {
    static func live() -> any LocalNotificationServing {
        LiveLocalNotificationService()
    }
}
