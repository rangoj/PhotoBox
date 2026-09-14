import Foundation
import Testing
import UserNotifications
@testable import PhotoBox

@Suite("Weekly reminder settings")
struct WeeklyReminderTests {
    // Production break: removing the meaningful-cleanup guard requests permission before PhotoBox has demonstrated value.
    @Test("Opt-in before meaningful cleanup is rejected without notification effects")
    @MainActor
    func optInBeforeMeaningfulCleanupIsRejected() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let notifications = RecordingLocalNotificationService(authorization: .authorized)
        let model = AppModel(
            library: ReminderTestPhotoLibrary(),
            repository: repository,
            notifications: notifications
        )

        await model.updateReminderEnabled(true)

        let recording = await notifications.recording()
        #expect(!model.reminderEnabled)
        #expect(model.reminderGuidance == "完成一次有实际决定的整理后，才可开启每周提醒。")
        #expect(recording.authorizationRequestCount == 0)
        #expect(recording.scheduledRequests.isEmpty)
    }

    // Production break: enabling after meaningful cleanup can skip authorization, persistence, or schedule private/duplicate content.
    @Test("Meaningful cleanup opt-in persists one generic weekly reminder after authorization")
    @MainActor
    func meaningfulCleanupOptInPersistsOneGenericReminder() async throws {
        let repository = try meaningfulReminderRepository()
        let notifications = RecordingLocalNotificationService(
            authorization: .notDetermined,
            requestedAuthorization: .authorized
        )
        let model = AppModel(
            library: ReminderTestPhotoLibrary(),
            repository: repository,
            notifications: notifications
        )

        await model.updateReminderEnabled(true)

        let recording = await notifications.recording()
        #expect(model.reminderEnabled)
        #expect(model.notificationAuthorization == .authorized)
        #expect(try repository.settings().reminderEnabled)
        #expect(recording.authorizationRequestCount == 1)
        #expect(recording.scheduledRequests == [WeeklyNotificationRequest(
            identifier: "photobox.weekly.cleanup",
            title: "每周照片整理",
            body: "打开 PhotoBox，花几分钟整理本周照片。",
            weekday: 7
        )])
        let serialized = recording.scheduledRequests
            .map { "\($0.title)|\($0.body)" }
            .joined(separator: "|")
        for forbidden in ["private-asset-17", "截图", "人物", "上海", "IMG_0001"] {
            #expect(!serialized.contains(forbidden))
        }
    }

    // Production break: appending instead of replacing, persisting the old weekday, or non-idempotent disablement leaves stale reminders.
    @Test("Repeated enablement and weekday changes are latest-wins before idempotent disablement")
    @MainActor
    func replacementAndDisablementAreLatestWins() async throws {
        let repository = try meaningfulReminderRepository()
        let notifications = RecordingLocalNotificationService(authorization: .authorized)
        let model = AppModel(
            library: ReminderTestPhotoLibrary(),
            repository: repository,
            notifications: notifications
        )

        await model.updateReminderEnabled(true)
        await model.updateReminderEnabled(true)
        await model.updateReminderWeekday(2)
        await model.updateReminderWeekday(5)

        var recording = await notifications.recording()
        #expect(recording.authorizationRequestCount == 0)
        #expect(recording.scheduledRequests.count == 1)
        #expect(recording.scheduledRequests.first?.identifier == "photobox.weekly.cleanup")
        #expect(recording.scheduledRequests.first?.weekday == 5)
        #expect(try repository.settings().reminderWeekday == 5)
        #expect(try repository.settings().reminderEnabled)

        await model.updateReminderEnabled(false)
        await model.updateReminderEnabled(false)

        recording = await notifications.recording()
        #expect(recording.scheduledRequests.isEmpty)
        #expect(recording.removalCount == 1)
        #expect(!model.reminderEnabled)
        #expect(try !repository.settings().reminderEnabled)
    }

    // Production break: a settings write failure after scheduling leaves a hidden pending request while the UI reports disabled.
    @Test("Enablement settings failure removes the unpersisted notification")
    @MainActor
    func enablementPersistenceFailureCompensates() async throws {
        let storage = try meaningfulReminderRepository()
        let repository = ReminderFailingRepository(storage: storage, failSettingsWrites: true)
        let notifications = RecordingLocalNotificationService(authorization: .authorized)
        let model = AppModel(
            library: ReminderTestPhotoLibrary(),
            repository: repository,
            notifications: notifications
        )

        await model.updateReminderEnabled(true)

        let recording = await notifications.recording()
        #expect(recording.scheduledRequests.isEmpty)
        #expect(recording.removalCount == 1)
        #expect(!model.reminderEnabled)
        #expect(try !storage.settings().reminderEnabled)
        #expect(model.reminderGuidance == "每周提醒未启用；已移除未保存的通知。")
    }

    // Production break: restoring persisted enablement without reconciling denied authorization falsely labels the reminder active.
    @Test("Denied authorization reconciles a persisted reminder to disabled")
    @MainActor
    func deniedAuthorizationReconcilesPersistedState() async throws {
        let repository = try meaningfulReminderRepository(reminderEnabled: true)
        let notifications = RecordingLocalNotificationService(authorization: .denied)
        try await notifications.replaceWeeklyReminder(weekday: 7)
        let model = AppModel(
            library: ReminderTestPhotoLibrary(),
            repository: repository,
            notifications: notifications
        )

        await model.refreshReminderAuthorization()

        let recording = await notifications.recording()
        #expect(model.notificationAuthorization == .denied)
        #expect(!model.reminderEnabled)
        #expect(try !repository.settings().reminderEnabled)
        #expect(recording.scheduledRequests.isEmpty)
        #expect(recording.authorizationRequestCount == 0)
        #expect(model.reminderGuidance?.contains("系统设置") == true)
    }

    // Production break: collapsing a failed permission request into denial gives incorrect recovery guidance.
    @Test("Authorization request failure reports a retryable inactive state")
    @MainActor
    func authorizationRequestFailureIsTruthful() async throws {
        let repository = try meaningfulReminderRepository()
        let notifications = RecordingLocalNotificationService(
            authorization: .notDetermined,
            requestAuthorizationFails: true
        )
        let model = AppModel(
            library: ReminderTestPhotoLibrary(),
            repository: repository,
            notifications: notifications
        )

        await model.updateReminderEnabled(true)

        #expect(!model.reminderEnabled)
        #expect(try !repository.settings().reminderEnabled)
        #expect(model.reminderGuidance == "通知授权请求失败，未开启每周提醒。请稍后重试。")
    }

    // Production break: a scheduling exception after granted access can be mislabeled as an authorization denial or active reminder.
    @Test("Scheduling failure keeps granted authorization but reports inactive reminder")
    @MainActor
    func schedulingFailureIsTruthful() async throws {
        let repository = try meaningfulReminderRepository()
        let notifications = RecordingLocalNotificationService(
            authorization: .authorized,
            schedulingFails: true
        )
        let model = AppModel(
            library: ReminderTestPhotoLibrary(),
            repository: repository,
            notifications: notifications
        )

        await model.updateReminderEnabled(true)

        let recording = await notifications.recording()
        #expect(model.notificationAuthorization == .authorized)
        #expect(!model.reminderEnabled)
        #expect(try !repository.settings().reminderEnabled)
        #expect(recording.scheduledRequests.isEmpty)
        #expect(model.reminderGuidance == "通知已允许，但无法安排每周提醒。请稍后重试。")
    }

    // Production break: replacing the request before a failed weekday write leaves the pending day different from the UI day.
    @Test("Weekday persistence failure restores the prior pending weekday")
    @MainActor
    func weekdayPersistenceFailureCompensates() async throws {
        let storage = try meaningfulReminderRepository(reminderEnabled: true)
        let repository = ReminderFailingRepository(storage: storage, failSettingsWrites: true)
        let notifications = RecordingLocalNotificationService(authorization: .authorized)
        try await notifications.replaceWeeklyReminder(weekday: 7)
        let model = AppModel(
            library: ReminderTestPhotoLibrary(),
            repository: repository,
            notifications: notifications
        )

        await model.updateReminderWeekday(2)

        let recording = await notifications.recording()
        #expect(model.reminderWeekday == 7)
        #expect(try storage.settings().reminderWeekday == 7)
        #expect(recording.scheduledRequests.first?.weekday == 7)
        #expect(model.reminderGuidance == "无法保存新提醒日期；已恢复原来的星期六提醒。")
    }

    // Production break: removing the request before a failed disable write leaves persisted/UI enabled state with no reminder.
    @Test("Disable persistence failure restores the prior pending reminder")
    @MainActor
    func disablePersistenceFailureCompensates() async throws {
        let storage = try meaningfulReminderRepository(reminderEnabled: true)
        let repository = ReminderFailingRepository(storage: storage, failSettingsWrites: true)
        let notifications = RecordingLocalNotificationService(authorization: .authorized)
        try await notifications.replaceWeeklyReminder(weekday: 7)
        let model = AppModel(
            library: ReminderTestPhotoLibrary(),
            repository: repository,
            notifications: notifications
        )

        await model.updateReminderEnabled(false)

        let recording = await notifications.recording()
        #expect(model.reminderEnabled)
        #expect(try storage.settings().reminderEnabled)
        #expect(recording.scheduledRequests.first?.weekday == 7)
        #expect(model.reminderGuidance == "无法保存关闭状态；已恢复原来的每周提醒。")
    }

    // Production break: initial fixture composition can ignore the persisted threshold, or threshold changes can leak into unrelated boundaries.
    @Test("Screenshot threshold restores persistently and invokes only the scan boundary")
    @MainActor
    func screenshotThresholdIsPersistentAndScanOnly() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        var settings = WorkflowSettings.defaults
        settings.screenshotRetentionDays = 90
        try repository.save(settings: settings)
        let library = CountingReminderPhotoLibrary()
        let notifications = RecordingLocalNotificationService(authorization: .authorized)
        let mutator = SimulatedPhotoLibraryMutator()
        var completed = LibraryScanSnapshot.idle
        completed.phase = .completed
        let model = AppModel(
            library: library,
            repository: repository,
            notifications: notifications,
            mutator: mutator,
            initialScan: completed
        )

        #expect(model.screenshotAgeDays == 90)
        await model.refreshAuthorization(forceScan: true)
        await library.waitForInventoryReads(1)
        model.updateScreenshotAge(7)
        await library.waitForInventoryReads(2)

        #expect(await library.inventoryReadCount() == 2)
        #expect(try repository.settings().screenshotRetentionDays == 7)
        #expect(await notifications.recording() == LocalNotificationRecording())
        #expect(await mutator.inventoryFingerprint().hasSuffix("mutationCalls=0"))
        #expect(model.mutationBackendMode == .simulated)
    }

    // Production break: publishing the picker value before its settings write succeeds changes UI state and starts an unrequested rescan.
    @Test("Screenshot persistence failure rolls back without rescanning")
    @MainActor
    func screenshotPersistenceFailureRollsBackWithoutRescan() async throws {
        let storage = try SwiftDataTaskRepository(inMemory: true)
        var settings = WorkflowSettings.defaults
        settings.screenshotRetentionDays = 90
        try storage.save(settings: settings)
        let repository = ReminderFailingRepository(storage: storage, failSettingsWrites: true)
        let library = CountingReminderPhotoLibrary()
        var completed = LibraryScanSnapshot.idle
        completed.phase = .completed
        let model = AppModel(
            library: library,
            repository: repository,
            notifications: RecordingLocalNotificationService(authorization: .authorized),
            initialScan: completed
        )

        await model.refreshAuthorization(forceScan: true)
        await library.waitForInventoryReads(1)
        model.updateScreenshotAge(7)
        try await Task.sleep(for: .milliseconds(100))

        #expect(model.screenshotAgeDays == 90)
        #expect(try storage.settings().screenshotRetentionDays == 90)
        #expect(await library.inventoryReadCount() == 1)
        #expect(model.screenshotPersistenceErrorMessage == "无法保存截图提醒天数。请重试；当前设置未更改。")
    }

    // Production break: a workflow persistence failure can be mislabeled as a screenshot-threshold failure in Settings.
    @Test("Screenshot recovery ignores unrelated persistence errors")
    @MainActor
    func screenshotRecoveryIgnoresUnrelatedPersistenceErrors() async throws {
        let model = AppModel(
            library: ReminderTestPhotoLibrary(),
            repository: try SwiftDataTaskRepository(inMemory: true),
            notifications: RecordingLocalNotificationService(authorization: .notDetermined)
        )

        model.persistenceErrorMessage = "无法打开本地整理记录"

        #expect(model.screenshotPersistenceErrorMessage == nil)
    }

    // Production break: a suspended enable can schedule and persist after a newer disable has already returned.
    @Test("Disable wins over a suspended enable")
    @MainActor
    func disableWinsOverSuspendedEnable() async throws {
        let repository = try meaningfulReminderRepository()
        let notifications = ControlledReminderNotificationService(
            authorization: .authorized,
            suspended: [.replace(7)]
        )
        let model = AppModel(
            library: ReminderTestPhotoLibrary(),
            repository: repository,
            notifications: notifications
        )

        let enable = Task { await model.updateReminderEnabled(true) }
        await notifications.waitUntilStarted(.replace(7))
        await model.updateReminderEnabled(false)
        await notifications.resume(.replace(7))
        await enable.value

        #expect(!model.reminderEnabled)
        #expect(try !repository.settings().reminderEnabled)
        #expect(await notifications.pendingWeekday() == nil)
    }

    // Production break: an older suspended replacement can resume last and overwrite the newer weekday externally and in persistence.
    @Test("Latest weekday wins after an older replacement resumes")
    @MainActor
    func latestWeekdayWinsAfterSuspension() async throws {
        let repository = try meaningfulReminderRepository(reminderEnabled: true)
        let notifications = ControlledReminderNotificationService(
            authorization: .authorized,
            pendingWeekday: 7,
            suspended: [.replace(2)]
        )
        let model = AppModel(
            library: ReminderTestPhotoLibrary(),
            repository: repository,
            notifications: notifications
        )

        let first = Task { await model.updateReminderWeekday(2) }
        await notifications.waitUntilStarted(.replace(2))
        await model.updateReminderWeekday(5)
        await notifications.resume(.replace(2))
        await first.value

        #expect(model.reminderWeekday == 5)
        #expect(try repository.settings().reminderWeekday == 5)
        #expect(await notifications.pendingWeekday() == 5)
    }

    // Production break: a weekday choice made after disable starts can leave model/persistence enabled while stale repair removes the request.
    @Test("Weekday change wins over an older suspended disable")
    @MainActor
    func weekdayChangeWinsOverSuspendedDisable() async throws {
        let repository = try meaningfulReminderRepository(reminderEnabled: true)
        let notifications = ControlledReminderNotificationService(
            authorization: .authorized,
            pendingWeekday: 7,
            suspended: [.remove]
        )
        let model = AppModel(
            library: ReminderTestPhotoLibrary(),
            repository: repository,
            notifications: notifications
        )

        let disable = Task { await model.updateReminderEnabled(false) }
        await notifications.waitUntilStarted(.remove)
        await model.updateReminderWeekday(2)
        await notifications.resume(.remove)
        await disable.value

        #expect(model.reminderEnabled)
        #expect(model.reminderWeekday == 2)
        #expect(try repository.settings().reminderEnabled)
        #expect(try repository.settings().reminderWeekday == 2)
        #expect(await notifications.pendingWeekday() == 2)
        #expect(model.reminderGuidance == nil)
    }

    // Production break: a failed stale repair is private-only, leaving enabled UI/persistence with no request and no recovery message.
    @Test("Failed stale repair is truthful and explicit retry converges")
    @MainActor
    func failedStaleRepairIsRetryable() async throws {
        let repository = try meaningfulReminderRepository(reminderEnabled: true)
        let notifications = ControlledReminderNotificationService(
            authorization: .authorized,
            pendingWeekday: 7,
            suspended: [.remove]
        )
        let model = AppModel(
            library: ReminderTestPhotoLibrary(),
            repository: repository,
            notifications: notifications
        )

        let disable = Task { await model.updateReminderEnabled(false) }
        await notifications.waitUntilStarted(.remove)
        await model.updateReminderWeekday(2)
        await notifications.failNext(.replace(2))
        await notifications.resume(.remove)
        await disable.value

        #expect(model.reminderEnabled)
        #expect(model.reminderWeekday == 2)
        #expect(try repository.settings().reminderEnabled)
        #expect(try repository.settings().reminderWeekday == 2)
        #expect(await notifications.pendingWeekday() == nil)
        #expect(model.reminderGuidance == "每周提醒仍显示为开启，但未能恢复待处理通知。请重试提醒日期。")

        await model.updateReminderWeekday(2)

        #expect(model.reminderEnabled)
        #expect(model.reminderWeekday == 2)
        #expect(try repository.settings().reminderEnabled)
        #expect(try repository.settings().reminderWeekday == 2)
        #expect(await notifications.pendingWeekday() == 2)
        #expect(model.reminderGuidance == nil)
    }

    // Production break: a disabled model with a pending request exposes no action that can retry removal without re-enabling reminders.
    @Test("Disabled stale repair remains explicitly retryable until removal succeeds")
    @MainActor
    func disabledStaleRepairIsExplicitlyRetryable() async throws {
        let repository = try meaningfulReminderRepository(reminderEnabled: true)
        let notifications = ControlledReminderNotificationService(
            authorization: .authorized,
            pendingWeekday: 7,
            suspended: [.replace(2)]
        )
        let model = AppModel(
            library: ReminderTestPhotoLibrary(),
            repository: repository,
            notifications: notifications
        )

        let weekdayChange = Task { await model.updateReminderWeekday(2) }
        await notifications.waitUntilStarted(.replace(2))
        await model.updateReminderEnabled(false)
        await notifications.failNext(.remove)
        await notifications.resume(.replace(2))
        await weekdayChange.value

        #expect(!model.reminderEnabled)
        #expect(try !repository.settings().reminderEnabled)
        #expect(await notifications.pendingWeekday() == 2)
        #expect(model.reminderGuidance == "每周提醒仍显示为关闭，但未能移除待处理通知。请重试。")
        #expect(model.canRetryReminderSynchronization)

        await notifications.failNext(.remove)
        await model.retryReminderSynchronization()

        #expect(!model.reminderEnabled)
        #expect(try !repository.settings().reminderEnabled)
        #expect(await notifications.pendingWeekday() == 2)
        #expect(model.reminderGuidance == "每周提醒仍显示为关闭，但未能移除待处理通知。请重试。")
        #expect(model.canRetryReminderSynchronization)

        await model.retryReminderSynchronization()

        #expect(!model.reminderEnabled)
        #expect(try !repository.settings().reminderEnabled)
        #expect(await notifications.pendingWeekday() == nil)
        #expect(model.reminderGuidance == nil)
        #expect(!model.canRetryReminderSynchronization)
    }

    // Production break: history clearing invalidates reminder work too late, allowing a suspended opt-in to recreate cleared settings and a request.
    @Test("History clear wins over a suspended reminder enable")
    @MainActor
    func historyClearWinsOverSuspendedEnable() async throws {
        let repository = try meaningfulReminderRepository()
        let notifications = ControlledReminderNotificationService(
            authorization: .authorized,
            suspended: [.replace(7)]
        )
        let model = AppModel(
            library: ReminderTestPhotoLibrary(),
            repository: repository,
            notifications: notifications
        )

        let enable = Task { await model.updateReminderEnabled(true) }
        await notifications.waitUntilStarted(.replace(7))
        #expect(await model.clearStatisticsHistory())
        await notifications.resume(.replace(7))
        await enable.value

        #expect(!model.weeklyModeEnabled)
        #expect(!model.reminderEnabled)
        #expect(try !repository.settings().reminderEnabled)
        #expect(await notifications.pendingWeekday() == nil)
    }

    // Production break: an opt-in begun while clear is suspended can schedule against stale weekly-mode state before clear finishes.
    @Test("Reminder mutation started during history clear has zero effects")
    @MainActor
    func reminderMutationDuringHistoryClearHasZeroEffects() async throws {
        let repository = try meaningfulReminderRepository()
        let notifications = ControlledReminderNotificationService(
            authorization: .authorized,
            suspended: [.remove]
        )
        let model = AppModel(
            library: ReminderTestPhotoLibrary(),
            repository: repository,
            notifications: notifications
        )

        let clear = Task { await model.clearStatisticsHistory() }
        await notifications.waitUntilStarted(.remove)
        #expect(model.isClearingStatisticsHistory)
        await model.updateReminderEnabled(true)

        #expect((await notifications.recording()).scheduledWeekdays.isEmpty)
        await notifications.resume(.remove)
        #expect(await clear.value)
        #expect(!model.reminderEnabled)
        #expect(try !repository.settings().reminderEnabled)
        await model.updateReminderEnabled(false)
        #expect((await notifications.recording()).removalCount == 1)
    }

    // Production break: a failed enable write plus failed compensation can become permanently stuck instead of converging on retry.
    @Test("Enable compensation failure remains retryable")
    @MainActor
    func enableCompensationFailureRemainsRetryable() async throws {
        let storage = try meaningfulReminderRepository()
        let repository = ReminderFailingRepository(storage: storage, failSettingsWrites: true)
        let notifications = ControlledReminderNotificationService(authorization: .authorized)
        await notifications.failNext(.remove)
        let model = AppModel(
            library: ReminderTestPhotoLibrary(),
            repository: repository,
            notifications: notifications
        )

        await model.updateReminderEnabled(true)
        #expect(!model.reminderEnabled)
        #expect(await notifications.pendingWeekday() == 7)
        #expect(model.reminderGuidance == "每周提醒未启用，但未能确认移除待处理通知。请前往系统设置检查通知。")

        repository.failSettingsWrites = false
        await model.updateReminderEnabled(true)
        #expect(model.reminderEnabled)
        #expect(try storage.settings().reminderEnabled)
        #expect(await notifications.pendingWeekday() == 7)
        #expect(model.reminderGuidance == nil)
    }

    // Production break: failed disable persistence plus failed re-add can hide a mismatch that a subsequent disable incorrectly treats as complete.
    @Test("Disable compensation failure remains retryable")
    @MainActor
    func disableCompensationFailureRemainsRetryable() async throws {
        let storage = try meaningfulReminderRepository(reminderEnabled: true)
        let repository = ReminderFailingRepository(storage: storage, failSettingsWrites: true)
        let notifications = ControlledReminderNotificationService(
            authorization: .authorized,
            pendingWeekday: 7
        )
        await notifications.failNext(.replace(7))
        let model = AppModel(
            library: ReminderTestPhotoLibrary(),
            repository: repository,
            notifications: notifications
        )

        await model.updateReminderEnabled(false)
        #expect(model.reminderEnabled)
        #expect(await notifications.pendingWeekday() == nil)
        #expect(model.reminderGuidance == "无法保存关闭状态，且未能恢复待处理提醒。当前设置可能不同步，请重试。")

        repository.failSettingsWrites = false
        await model.updateReminderEnabled(false)
        #expect(!model.reminderEnabled)
        #expect(try !storage.settings().reminderEnabled)
        #expect(await notifications.pendingWeekday() == nil)
    }

    // Production break: failed weekday persistence plus failed restoration can strand the pending request on the uncommitted day with no usable retry.
    @Test("Weekday restoration failure remains retryable")
    @MainActor
    func weekdayRestorationFailureRemainsRetryable() async throws {
        let storage = try meaningfulReminderRepository(reminderEnabled: true)
        let repository = ReminderFailingRepository(storage: storage, failSettingsWrites: true)
        let notifications = ControlledReminderNotificationService(
            authorization: .authorized,
            pendingWeekday: 7
        )
        await notifications.failNext(.replace(7))
        let model = AppModel(
            library: ReminderTestPhotoLibrary(),
            repository: repository,
            notifications: notifications
        )

        await model.updateReminderWeekday(2)
        #expect(model.reminderWeekday == 7)
        #expect(await notifications.pendingWeekday() == 2)
        #expect(model.reminderGuidance == "无法保存新提醒日期，且未能恢复原提醒。当前设置可能不同步，请重试。")

        repository.failSettingsWrites = false
        await model.updateReminderWeekday(2)
        #expect(model.reminderWeekday == 2)
        #expect(try storage.settings().reminderWeekday == 2)
        #expect(await notifications.pendingWeekday() == 2)
    }

    // Production break: denied reconciliation publishes disabled UI before failed removal/write, then skips the work forever on refresh.
    @Test("Denied reconciliation retries removal and persistence")
    @MainActor
    func deniedReconciliationRetriesRemovalAndPersistence() async throws {
        let storage = try meaningfulReminderRepository(reminderEnabled: true)
        let repository = ReminderFailingRepository(storage: storage, failSettingsWrites: true)
        let notifications = ControlledReminderNotificationService(
            authorization: .denied,
            pendingWeekday: 7
        )
        await notifications.failNext(.remove)
        let model = AppModel(
            library: ReminderTestPhotoLibrary(),
            repository: repository,
            notifications: notifications
        )

        await model.refreshReminderAuthorization()
        #expect(!model.reminderEnabled)
        #expect(try storage.settings().reminderEnabled)
        #expect(await notifications.pendingWeekday() == 7)
        #expect(model.reminderGuidance == "通知未获允许，且提醒状态无法同步。请前往系统设置检查通知后重试。")

        repository.failSettingsWrites = false
        await model.refreshReminderAuthorization()
        #expect(!model.reminderEnabled)
        #expect(try !storage.settings().reminderEnabled)
        #expect(await notifications.pendingWeekday() == nil)
    }

    // Production break: denial returned directly by the permission prompt can be mislabeled or can schedule despite the denial.
    @Test("Direct denial after permission request remains inactive")
    @MainActor
    func directDenialAfterPermissionRequestRemainsInactive() async throws {
        let repository = try meaningfulReminderRepository()
        let notifications = ControlledReminderNotificationService(
            authorization: .notDetermined,
            requestedAuthorization: .denied
        )
        let model = AppModel(
            library: ReminderTestPhotoLibrary(),
            repository: repository,
            notifications: notifications
        )

        await model.updateReminderEnabled(true)

        let recording = await notifications.recording()
        #expect(recording.authorizationRequestCount == 1)
        #expect(recording.scheduledRequests.isEmpty)
        #expect(model.notificationAuthorization == .denied)
        #expect(!model.reminderEnabled)
        #expect(model.reminderGuidance == "通知未获允许。你仍可使用每周整理，并可在系统设置中开启通知。")
    }

    // Production break: non-full notification states can be treated as permission to schedule a weekly request.
    @Test("Restricted and temporary notification states remain inactive", arguments: [
        LocalNotificationAuthorization.restricted,
        .provisional,
        .ephemeral
    ])
    @MainActor
    func nonFullNotificationAuthorizationRemainsInactive(
        authorization: LocalNotificationAuthorization
    ) async throws {
        let repository = try meaningfulReminderRepository(reminderEnabled: true)
        let notifications = ControlledReminderNotificationService(
            authorization: authorization,
            pendingWeekday: 7
        )
        let model = AppModel(
            library: ReminderTestPhotoLibrary(),
            repository: repository,
            notifications: notifications
        )

        await model.refreshReminderAuthorization()

        #expect(model.notificationAuthorization == authorization)
        #expect(!model.reminderEnabled)
        #expect(try !repository.settings().reminderEnabled)
        #expect(await notifications.pendingWeekday() == nil)
    }

    // Production break: transient authorization and scheduling failures can poison later explicit retries.
    @Test("Authorization and scheduling failures are retryable")
    @MainActor
    func authorizationAndSchedulingFailuresAreRetryable() async throws {
        let authorizationRepository = try meaningfulReminderRepository()
        let authorizationNotifications = ControlledReminderNotificationService(
            authorization: .notDetermined,
            requestedAuthorization: .authorized
        )
        await authorizationNotifications.failNext(.requestAuthorization)
        let authorizationModel = AppModel(
            library: ReminderTestPhotoLibrary(),
            repository: authorizationRepository,
            notifications: authorizationNotifications
        )

        await authorizationModel.updateReminderEnabled(true)
        #expect(!authorizationModel.reminderEnabled)
        await authorizationModel.updateReminderEnabled(true)
        #expect(authorizationModel.reminderEnabled)
        #expect(await authorizationNotifications.pendingWeekday() == 7)

        let schedulingRepository = try meaningfulReminderRepository()
        let schedulingNotifications = ControlledReminderNotificationService(authorization: .authorized)
        await schedulingNotifications.failNext(.replace(7))
        let schedulingModel = AppModel(
            library: ReminderTestPhotoLibrary(),
            repository: schedulingRepository,
            notifications: schedulingNotifications
        )

        await schedulingModel.updateReminderEnabled(true)
        #expect(!schedulingModel.reminderEnabled)
        await schedulingModel.updateReminderEnabled(true)
        #expect(schedulingModel.reminderEnabled)
        #expect(await schedulingNotifications.pendingWeekday() == 7)
    }

    // Production break: launch, onboarding, or diagnosis navigation can accidentally become an implicit notification opt-in path.
    @Test("Launch onboarding and diagnosis make zero notification effects")
    @MainActor
    func launchOnboardingAndDiagnosisHaveZeroNotificationEffects() async throws {
        let notifications = RecordingLocalNotificationService(authorization: .notDetermined)
        let model = AppModel(
            library: ReminderTestPhotoLibrary(),
            repository: try SwiftDataTaskRepository(inMemory: true),
            notifications: notifications
        )
        #expect(await notifications.recording() == LocalNotificationRecording())

        await model.refreshAuthorization()
        #expect(await notifications.recording() == LocalNotificationRecording())

        await model.requestPhotoAccess()
        #expect(await notifications.recording() == LocalNotificationRecording())

        model.taskNavigationPath = [.diagnosis]
        model.activeRoute = .diagnosis
        _ = DiagnosisReportView(model: model).body
        #expect(await notifications.recording() == LocalNotificationRecording())
    }

    // Production break: notification denial can incorrectly block the weekly inbox or make its truthful empty state unusable.
    @Test("Denied notifications preserve the empty weekly inbox")
    @MainActor
    func deniedNotificationsPreserveEmptyWeeklyInbox() async throws {
        let repository = try meaningfulReminderRepository(reminderEnabled: true)
        try repository.save(checkpoint: ScanCheckpoint(
            id: "denied-empty-weekly-baseline",
            stage: .completed,
            processedAssetIDs: [],
            discoveredCount: 0,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        ))
        let notifications = ControlledReminderNotificationService(
            authorization: .denied,
            pendingWeekday: 7
        )
        let model = AppModel(
            library: ReminderTestPhotoLibrary(),
            repository: repository,
            notifications: notifications
        )

        await model.refreshReminderAuthorization()
        await model.prepareWeeklyInbox()

        #expect(model.weeklyInboxFlow?.plan?.isTrulyEmpty == true)
        #expect(await notifications.pendingWeekday() == nil)
        #expect((await notifications.recording()).authorizationRequestCount == 0)
    }

    // Production break: returning from System Settings refreshes Photos only, leaving notification state and pending requests stale.
    @Test("App activation reconciles changed notification authorization")
    @MainActor
    func appActivationReconcilesNotificationAuthorization() async throws {
        let repository = try meaningfulReminderRepository(reminderEnabled: true)
        let notifications = ControlledReminderNotificationService(
            authorization: .authorized,
            pendingWeekday: 7
        )
        let model = AppModel(
            library: ReminderTestPhotoLibrary(),
            repository: repository,
            notifications: notifications
        )
        await notifications.setAuthorization(.denied)

        await model.refreshForAppActivation()

        #expect(model.notificationAuthorization == .denied)
        #expect(!model.reminderEnabled)
        #expect(try !repository.settings().reminderEnabled)
        #expect(await notifications.pendingWeekday() == nil)
        #expect((await notifications.recording()).authorizationRequestCount == 0)
    }

    // Production break: wiring reminder permission to result completion would request or schedule without a Settings opt-in.
    @Test("Meaningful cleanup completion without opt-in has zero notification effects")
    @MainActor
    func cleanupCompletionDoesNotPromptOrSchedule() async throws {
        let repository = try SwiftDataTaskRepository(inMemory: true)
        let summary = CleanupSummary(
            decisions: [PhotoDecision(assetID: "meaningful-private-fixture", kind: .keep)],
            elapsedSeconds: nil,
            id: UUID(uuidString: "55000000-0000-0000-0000-000000000001")!,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        try repository.save(summary: summary)
        let notifications = RecordingLocalNotificationService(authorization: .notDetermined)
        let model = AppModel(
            library: ReminderTestPhotoLibrary(),
            repository: repository,
            notifications: notifications
        )

        await model.prepareCleanupResults(source: .summary(summary.id))

        #expect(model.weeklyModeEnabled)
        #expect(!model.reminderEnabled)
        #expect(await notifications.recording() == LocalNotificationRecording())
    }

    // Production break: a stale Settings authorization refresh can disable a reminder that a concurrent explicit opt-in just scheduled.
    @Test("Explicit opt-in wins over an older authorization refresh")
    @MainActor
    func explicitOptInWinsOverStaleAuthorizationRefresh() async throws {
        let repository = try meaningfulReminderRepository()
        let notifications = SuspendedAuthorizationNotificationService()
        let model = AppModel(
            library: ReminderTestPhotoLibrary(),
            repository: repository,
            notifications: notifications
        )

        let refresh = Task { await model.refreshReminderAuthorization() }
        await notifications.waitUntilAuthorizationStatusReadStarts()
        await model.updateReminderEnabled(true)
        #expect(model.reminderEnabled)

        await notifications.resumeAuthorizationStatusRead(with: .notDetermined)
        await refresh.value

        let recording = await notifications.recording()
        #expect(model.reminderEnabled)
        #expect(try repository.settings().reminderEnabled)
        #expect(recording.scheduledRequests == [.weekly(weekday: 7)])
        #expect(recording.removalCount == 0)
    }

    // Production break: clearing persisted PhotoBox settings can leave the external weekly request and in-memory toggle active.
    @Test("Clearing PhotoBox history removes and resets the weekly reminder")
    @MainActor
    func historyClearRemovesWeeklyReminder() async throws {
        let repository = try meaningfulReminderRepository(reminderEnabled: true)
        let notifications = RecordingLocalNotificationService(authorization: .authorized)
        try await notifications.replaceWeeklyReminder(weekday: 7)
        let model = AppModel(
            library: ReminderTestPhotoLibrary(),
            repository: repository,
            notifications: notifications
        )

        #expect(await model.clearStatisticsHistory())

        let recording = await notifications.recording()
        #expect(!model.reminderEnabled)
        #expect(model.reminderWeekday == WorkflowSettings.defaults.reminderWeekday)
        #expect(try !repository.settings().reminderEnabled)
        #expect(recording.scheduledRequests.isEmpty)
        #expect(recording.removalCount == 1)
        #expect(model.reminderGuidance == nil)
    }

    // Production break: a failed pending-request removal can be hidden after history is cleared, leaving an unreported reminder mismatch.
    @Test("History clear reports a pending reminder removal mismatch")
    @MainActor
    func historyClearReportsReminderRemovalFailure() async throws {
        let repository = try meaningfulReminderRepository(reminderEnabled: true)
        let notifications = RecordingLocalNotificationService(
            authorization: .authorized,
            removalFails: true
        )
        try await notifications.replaceWeeklyReminder(weekday: 7)
        let model = AppModel(
            library: ReminderTestPhotoLibrary(),
            repository: repository,
            notifications: notifications
        )

        #expect(await model.clearStatisticsHistory())

        let recording = await notifications.recording()
        #expect(!model.reminderEnabled)
        #expect(try !repository.settings().reminderEnabled)
        #expect(recording.scheduledRequests.count == 1)
        #expect(model.reminderGuidance == "历史已清除，但未能移除待处理提醒。请前往系统设置检查通知。")
    }
}

@Suite("Live local notification service")
struct LiveLocalNotificationServiceTests {
    // Production break: the UserNotifications conversion can use the wrong identifier, content, hour, weekday, or repeat behavior.
    @Test("Production request conversion is generic and repeats weekly at nineteen hundred")
    func productionRequestConversionIsExact() throws {
        let request = UserNotificationCenterAdapter.makeRequest(
            from: .weekly(weekday: 3)
        )

        #expect(request.identifier == "photobox.weekly.cleanup")
        #expect(request.content.title == "每周照片整理")
        #expect(request.content.body == "打开 PhotoBox，花几分钟整理本周照片。")
        let trigger = try #require(request.trigger as? UNCalendarNotificationTrigger)
        #expect(trigger.dateComponents.hour == 19)
        #expect(trigger.dateComponents.weekday == 3)
        #expect(trigger.repeats)
    }

    // Production break: the UserNotifications adapter can emit an unstable, content-bearing, or non-replacing request.
    @Test("Live service replaces one generic calendar request and removes it")
    func stableCalendarRequestLifecycle() async throws {
        let center = ReminderCenterRecorder(status: .authorized)
        let service = LiveLocalNotificationService(center: center)

        #expect(await service.authorizationStatus() == .authorized)
        try await service.replaceWeeklyReminder(weekday: 2)
        try await service.replaceWeeklyReminder(weekday: 6)

        var requests = await center.pendingRequests()
        #expect(requests == [WeeklyNotificationRequest(
            identifier: "photobox.weekly.cleanup",
            title: "每周照片整理",
            body: "打开 PhotoBox，花几分钟整理本周照片。",
            weekday: 6
        )])

        await service.removeWeeklyReminder()
        requests = await center.pendingRequests()
        #expect(requests.isEmpty)
    }
}

@MainActor
private func meaningfulReminderRepository(
    reminderEnabled: Bool = false
) throws -> SwiftDataTaskRepository {
    let repository = try SwiftDataTaskRepository(inMemory: true)
    var settings = WorkflowSettings.defaults
    settings.weeklyModeEnabled = true
    settings.reminderEnabled = reminderEnabled
    try repository.save(settings: settings)
    return repository
}

private actor ReminderTestPhotoLibrary: PhotoLibraryReading {
    func authorizationStatus() -> PhotoAuthorization { .authorized }
    func requestAuthorization() -> PhotoAuthorization { .authorized }
    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> {
        AsyncStream { $0.finish() }
    }
}

private actor CountingReminderPhotoLibrary: PhotoLibraryReading {
    private var readCount = 0

    func authorizationStatus() -> PhotoAuthorization { .authorized }
    func requestAuthorization() -> PhotoAuthorization { .authorized }

    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> {
        AsyncStream { $0.finish() }
    }

    func accessibleAssetDescriptors() -> [PhotoAssetDescriptor] {
        readCount += 1
        return []
    }

    func inventoryReadCount() -> Int { readCount }

    func waitForInventoryReads(_ expected: Int) async {
        for _ in 0..<200 {
            if readCount >= expected { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for scan inventory read \(expected)")
    }
}

private actor ReminderCenterRecorder: UserNotificationCenterAccessing {
    private var status: LocalNotificationAuthorization
    private var requests: [String: WeeklyNotificationRequest] = [:]

    init(status: LocalNotificationAuthorization) {
        self.status = status
    }

    func authorizationStatus() -> LocalNotificationAuthorization { status }

    func requestAuthorization() -> LocalNotificationAuthorization { status }

    func add(_ request: WeeklyNotificationRequest) {
        requests[request.identifier] = request
    }

    func removePendingRequests(withIdentifiers identifiers: [String]) {
        identifiers.forEach { requests.removeValue(forKey: $0) }
    }

    func pendingRequests() -> [WeeklyNotificationRequest] {
        requests.values.sorted { $0.identifier < $1.identifier }
    }
}

private actor SuspendedAuthorizationNotificationService: LocalNotificationServing {
    private var statusReadStarted = false
    private var statusReadWaiters: [CheckedContinuation<Void, Never>] = []
    private var statusReadContinuation: CheckedContinuation<LocalNotificationAuthorization, Never>?
    private var state = LocalNotificationRecording()

    func authorizationStatus() async -> LocalNotificationAuthorization {
        state.authorizationStatusReadCount += 1
        if state.authorizationStatusReadCount > 1 {
            return .notDetermined
        }
        statusReadStarted = true
        statusReadWaiters.forEach { $0.resume() }
        statusReadWaiters.removeAll()
        return await withCheckedContinuation { continuation in
            statusReadContinuation = continuation
        }
    }

    func waitUntilAuthorizationStatusReadStarts() async {
        guard !statusReadStarted else { return }
        await withCheckedContinuation { continuation in
            statusReadWaiters.append(continuation)
        }
    }

    func resumeAuthorizationStatusRead(with authorization: LocalNotificationAuthorization) {
        statusReadContinuation?.resume(returning: authorization)
        statusReadContinuation = nil
    }

    func requestAuthorization() -> LocalNotificationAuthorization {
        state.authorizationRequestCount += 1
        return .authorized
    }

    func replaceWeeklyReminder(weekday: Int) {
        state.scheduledWeekdays.append(weekday)
        state.scheduledRequests = [.weekly(weekday: weekday)]
    }

    func removeWeeklyReminder() {
        state.removalCount += 1
        state.scheduledRequests.removeAll()
    }

    func recording() -> LocalNotificationRecording { state }
}

nonisolated private enum ControlledReminderOperation: Hashable, Sendable {
    case authorizationStatus
    case requestAuthorization
    case replace(Int)
    case remove
}

private actor ControlledReminderNotificationService: LocalNotificationServing {
    private var authorization: LocalNotificationAuthorization
    private let requestedAuthorization: LocalNotificationAuthorization
    private var state = LocalNotificationRecording()
    private var pending: WeeklyNotificationRequest?
    private var suspended: Set<ControlledReminderOperation>
    private var suspendedContinuations: [
        ControlledReminderOperation: [CheckedContinuation<Void, Never>]
    ] = [:]
    private var startedCounts: [ControlledReminderOperation: Int] = [:]
    private var startedWaiters: [
        ControlledReminderOperation: [(Int, CheckedContinuation<Void, Never>)]
    ] = [:]
    private var failures: [ControlledReminderOperation: Int] = [:]

    init(
        authorization: LocalNotificationAuthorization,
        requestedAuthorization: LocalNotificationAuthorization? = nil,
        pendingWeekday: Int? = nil,
        suspended: Set<ControlledReminderOperation> = []
    ) {
        self.authorization = authorization
        self.requestedAuthorization = requestedAuthorization ?? authorization
        self.pending = pendingWeekday.map(WeeklyNotificationRequest.weekly(weekday:))
        self.suspended = suspended
        if let pending {
            state.scheduledRequests = [pending]
        }
    }

    func authorizationStatus() async -> LocalNotificationAuthorization {
        state.authorizationStatusReadCount += 1
        await pauseIfNeeded(.authorizationStatus)
        return authorization
    }

    func requestAuthorization() async throws -> LocalNotificationAuthorization {
        state.authorizationRequestCount += 1
        try await perform(.requestAuthorization)
        authorization = requestedAuthorization
        return authorization
    }

    func replaceWeeklyReminder(weekday: Int) async throws {
        let operation = ControlledReminderOperation.replace(weekday)
        try await perform(operation)
        let request = WeeklyNotificationRequest.weekly(weekday: weekday)
        pending = request
        state.scheduledWeekdays.append(weekday)
        state.scheduledRequests = [request]
    }

    func removeWeeklyReminder() async throws {
        try await perform(.remove)
        pending = nil
        state.removalCount += 1
        state.scheduledRequests = []
    }

    func failNext(_ operation: ControlledReminderOperation) {
        failures[operation, default: 0] += 1
    }

    func setAuthorization(_ authorization: LocalNotificationAuthorization) {
        self.authorization = authorization
    }

    func waitUntilStarted(_ operation: ControlledReminderOperation, count: Int = 1) async {
        guard startedCounts[operation, default: 0] < count else { return }
        await withCheckedContinuation { continuation in
            startedWaiters[operation, default: []].append((count, continuation))
        }
    }

    func resume(_ operation: ControlledReminderOperation) {
        suspended.remove(operation)
        let continuations = suspendedContinuations.removeValue(forKey: operation) ?? []
        continuations.forEach { $0.resume() }
    }

    func pendingWeekday() -> Int? { pending?.weekday }

    func recording() -> LocalNotificationRecording { state }

    private func perform(_ operation: ControlledReminderOperation) async throws {
        await pauseIfNeeded(operation)
        if failures[operation, default: 0] > 0 {
            failures[operation, default: 0] -= 1
            throw ControlledReminderFailure.forced(operation)
        }
    }

    private func pauseIfNeeded(_ operation: ControlledReminderOperation) async {
        startedCounts[operation, default: 0] += 1
        if let waiters = startedWaiters[operation] {
            var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
            for (count, continuation) in waiters {
                if startedCounts[operation, default: 0] >= count {
                    continuation.resume()
                } else {
                    remaining.append((count, continuation))
                }
            }
            startedWaiters[operation] = remaining
        }
        guard suspended.contains(operation) else { return }
        await withCheckedContinuation { continuation in
            suspendedContinuations[operation, default: []].append(continuation)
        }
    }
}

private enum ControlledReminderFailure: Error {
    case forced(ControlledReminderOperation)
}

@MainActor
private final class ReminderFailingRepository: TaskRepository {
    let storage: SwiftDataTaskRepository
    var failSettingsWrites: Bool

    init(storage: SwiftDataTaskRepository, failSettingsWrites: Bool) {
        self.storage = storage
        self.failSettingsWrites = failSettingsWrites
    }

    func save(checkpoint: ScanCheckpoint) throws { try storage.save(checkpoint: checkpoint) }
    func latestCheckpoint() throws -> ScanCheckpoint? { try storage.latestCheckpoint() }
    func latestCompletedCheckpoint() throws -> ScanCheckpoint? { try storage.latestCompletedCheckpoint() }
    func initialCompletedCheckpoint() throws -> RepositoryLookup<ScanCheckpoint> { try storage.initialCompletedCheckpoint() }
    func save(task: CleanupTask) throws { try storage.save(task: task) }
    func save(tasks: [CleanupTask]) throws { try storage.save(tasks: tasks) }
    func tasks() throws -> [CleanupTask] { try storage.tasks() }
    func save(decision: PhotoDecision) throws { try storage.save(decision: decision) }
    func removeDecision(for assetID: String) throws { try storage.removeDecision(for: assetID) }
    func removeDecisions(for assetIDs: Set<String>) throws { try storage.removeDecisions(for: assetIDs) }
    func decision(for assetID: String) throws -> PhotoDecision? { try storage.decision(for: assetID) }
    func decisions() throws -> [PhotoDecision] { try storage.decisions() }
    func applySingleDecision(_ decision: PhotoDecision, undo: DecisionUndoEntry, task: CleanupTask?) throws {
        try storage.applySingleDecision(decision, undo: undo, task: task)
    }
    func save(decisions: [PhotoDecision]) throws { try storage.save(decisions: decisions) }
    func completeComparison(taskID: String, decisions: [PhotoDecision]) throws {
        try storage.completeComparison(taskID: taskID, decisions: decisions)
    }
    func completeArchive(
        transaction: MutationTransaction,
        decision: PhotoDecision,
        recentAlbumIDs: [String]
    ) throws {
        try storage.completeArchive(
            transaction: transaction,
            decision: decision,
            recentAlbumIDs: recentAlbumIDs
        )
    }
    func save(undo: DecisionUndoEntry) throws { try storage.save(undo: undo) }
    func latestUndo() throws -> DecisionUndoEntry? { try storage.latestUndo() }
    func removeUndo(id: UUID) throws { try storage.removeUndo(id: id) }
    func save(transaction: MutationTransaction) throws { try storage.save(transaction: transaction) }
    func transactions() throws -> [MutationTransaction] { try storage.transactions() }
    func transaction(id: String) throws -> RepositoryLookup<MutationTransaction> { try storage.transaction(id: id) }
    func save(settings: WorkflowSettings) throws {
        if failSettingsWrites { throw ReminderPersistenceFailure.forced }
        try storage.save(settings: settings)
    }
    func settings() throws -> WorkflowSettings { try storage.settings() }
    func save(summary: CleanupSummary) throws { try storage.save(summary: summary) }
    func summaries() throws -> [CleanupSummary] { try storage.summaries() }
    func summary(id: UUID) throws -> RepositoryLookup<CleanupSummary> { try storage.summary(id: id) }
    func reconcile(availableAssetIDs: Set<String>) throws { try storage.reconcile(availableAssetIDs: availableAssetIDs) }
    func clearHistory() throws { try storage.clearHistory() }
}

private enum ReminderPersistenceFailure: Error { case forced }
