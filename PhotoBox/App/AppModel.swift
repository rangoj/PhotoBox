import Observation
import Photos

@MainActor
@Observable
final class AppModel {
    private let library: any PhotoLibraryReading
    private let repository: (any TaskRepository)?
    private let notifications: any LocalNotificationServing
    private var mutator: any PhotoLibraryMutating
    private let mutationSubmissionSignal: (@Sendable () async -> Int)?
    private let mutationSubmissionReadSignal: (@Sendable () async -> Int)?
    private let mutationSubmittedAssetIDsSignal: (@Sendable () async -> [String])?
    private let statisticsInventorySignal: (@Sendable () async -> String)?
    private let statisticsClearCountSignal: (@MainActor @Sendable () -> Int)?
    private let reminderRecordingSignal: (@Sendable () async -> LocalNotificationRecording)?
    private let settingsScanCountSignal: (@Sendable () async -> Int)?
    private let scanCoordinator: ScanCoordinator
    private let checkpointStore: AppModelCheckpointStore
    private let inventoryStore = LibraryInventoryStore()
    let thumbnailLoader: BoundedThumbnailLoader
    let statistics: StatisticsModel
    let myHome: MyHomeModel
    let albumHome: AlbumHomeModel

    @ObservationIgnored
    private var scanTask: Task<Void, Never>?

    @ObservationIgnored
    private var libraryChangeTask: Task<Void, Never>?

    @ObservationIgnored
    private var scanGeneration = UUID()

    @ObservationIgnored
    private var comparisonLoadTask: Task<Void, Never>?

    @ObservationIgnored
    private var comparisonLoadGeneration = UUID()

    @ObservationIgnored
    private var decisionLoadGeneration = UUID()

    @ObservationIgnored
    private var authorizationOperationGeneration = UUID()

    @ObservationIgnored
    private var readableAuthorizationRecoveryGeneration: UUID?

    @ObservationIgnored
    private var reminderMutationGeneration = UUID()

    @ObservationIgnored
    private var desiredReminderEnabled = false

    @ObservationIgnored
    private var desiredReminderWeekday = WorkflowSettings.defaults.reminderWeekday

    @ObservationIgnored
    private var reminderSynchronizationNeedsRetry = false

    var authorization: PhotoAuthorization = .notDetermined
    var hasLoadedAuthorization = false
    var scan = LibraryScanSnapshot.idle
    var screenshotAgeDays = 30
    var cleanupTasks: [CleanupTask] = []
    var currentPhotoStorageBytes: Int64?
    var pendingDecisions: [PhotoDecision] = []
    private(set) var homeProjection = CleanupHomeProjection(descriptors: [], decisions: [])
    private(set) var isHomeInventoryReady = false
    var homeNotice: String?
    private(set) var homeNow: Date
    let homeCalendar: Calendar
    private let fixedHomeNow: Date?
    private var allHomeDecisions: [PhotoDecision] = []
    var mediaPages: [MediaPage] = []
    var comparisonFlow: ComparisonFlowModel?
    var comparisonTaskID: String?
    var comparisonLoadError: String?
    var isLoadingComparison = false
    var decisionFlow: SinglePhotoDecisionFlow?
    var decisionTaskID: String?
    var decisionLoadError: String?
    var albumSelectionFlow: AlbumSelectionFlow?
    var albumSelectionLoadError: String?
    var deleteReviewFlow: DeleteReviewModel?
    var deleteReviewLoadError: String?
    var isPreparingDeleteReview = false
    var cleanupResultsFlow: CleanupResultsModel?
    var cleanupResultsSource: CleanupResultSource?
    var isPreparingCleanupResults = false
    var weeklyInboxFlow: WeeklyInboxModel?
    var decisionQueues: DecisionQueueModel?
    var activeRoute: AppRoute?
    var taskNavigationPath: [AppRoute] = [] {
        didSet { pauseDepartedHomeTasks(from: oldValue) }
    }
    var persistenceErrorMessage: String?
    var screenshotPersistenceErrorMessage: String?
    var debugRealMutationEnabled = false
    var mutationBackendMode = MutationBackendMode.simulated
    var weeklyModeEnabled = false
    var reminderEnabled = false
    var reminderWeekday = 7
    var notificationAuthorization = LocalNotificationAuthorization.notDetermined
    var reminderGuidance: String?
    var statisticsInventoryFingerprint: String?
    var statisticsClearCallCount: Int?
    var reminderRecording: LocalNotificationRecording?
    var settingsScanCount: Int?
    private(set) var libraryInventory = LibraryInventory()
    private(set) var isClearingStatisticsHistory = false
    private(set) var weeklyTransitionNeedsRetry = false
    var canRetryReminderSynchronization: Bool { reminderSynchronizationNeedsRetry }

    @ObservationIgnored
    private var weeklyBaselineAssetIDs: Set<String>?

    @ObservationIgnored
    private var canEstablishInitialWeeklyBaseline = false

    var mutationModeLabel: String {
        MutationComposition.modeLabel(for: mutationBackendMode)
    }

    var hasStatisticsInventorySignal: Bool { statisticsInventorySignal != nil }

    init(
        library: (any PhotoLibraryReading)? = nil,
        repository: (any TaskRepository)? = nil,
        notifications: (any LocalNotificationServing)? = nil,
        mutator: (any PhotoLibraryMutating)? = nil,
        initialScan: LibraryScanSnapshot? = nil,
        initialCleanupTasks: [CleanupTask] = [],
        currentPhotoStorageBytes: Int64? = nil,
        initialActiveRoute: AppRoute? = nil,
        mediaPages: [MediaPage] = [],
        comparisonGroups: [PhotoCandidateGroup] = [],
        comparisonRecommendations: [PhotoGroupRecommendation] = [],
        mutationSubmissionSignal: (@Sendable () async -> Int)? = nil,
        mutationSubmissionReadSignal: (@Sendable () async -> Int)? = nil,
        mutationSubmittedAssetIDsSignal: (@Sendable () async -> [String])? = nil,
        statisticsInventorySignal: (@Sendable () async -> String)? = nil,
        statisticsClearCountSignal: (@MainActor @Sendable () -> Int)? = nil,
        reminderRecordingSignal: (@Sendable () async -> LocalNotificationRecording)? = nil,
        settingsScanCountSignal: (@Sendable () async -> Int)? = nil,
        initialInventory: LibraryInventory? = nil,
        homeNow: Date? = nil,
        homeCalendar: Calendar = Calendar(identifier: .gregorian),
        myHomeReader: (@MainActor () throws -> MyHomeSnapshot)? = nil
    ) {
        self.homeNow = homeNow ?? .now
        self.fixedHomeNow = homeNow
        self.homeCalendar = homeCalendar
        let resolvedLibrary = library ?? LivePhotoLibraryService()
        self.library = resolvedLibrary
        let resolvedRepository = repository ?? (try? SwiftDataTaskRepository())
        self.repository = resolvedRepository
        self.notifications = notifications ?? LocalNotificationComposition.live()
        self.statistics = StatisticsModel(repository: resolvedRepository)
        self.myHome = myHomeReader.map { MyHomeModel(read: $0) } ?? MyHomeModel(repository: resolvedRepository)
        let checkpointStore = AppModelCheckpointStore(repository: resolvedRepository)
        self.checkpointStore = checkpointStore
        self.scanCoordinator = ScanCoordinator(reader: resolvedLibrary) { checkpoint in
            await checkpointStore.save(checkpoint)
        }
        self.thumbnailLoader = BoundedThumbnailLoader(reader: resolvedLibrary)
        let settings = (try? resolvedRepository?.settings()) ?? .defaults
        screenshotAgeDays = settings.screenshotRetentionDays
        weeklyModeEnabled = settings.weeklyModeEnabled
        reminderEnabled = settings.reminderEnabled
        reminderWeekday = settings.reminderWeekday
        desiredReminderEnabled = settings.reminderEnabled
        desiredReminderWeekday = settings.reminderWeekday
        weeklyBaselineAssetIDs = Self.initialWeeklyBaseline(from: resolvedRepository)
        canEstablishInitialWeeklyBaseline = !settings.weeklyModeEnabled && weeklyBaselineAssetIDs == nil
        debugRealMutationEnabled = settings.debugRealMutationEnabled
        let resolvedMutator = mutator ?? MutationComposition.current(settings: settings)
        self.mutator = resolvedMutator
        self.albumHome = AlbumHomeModel(
            library: resolvedLibrary,
            mutator: resolvedMutator,
            recentAlbumIDs: { try resolvedRepository?.settings().recentAlbumIDs ?? [] }
        )
        self.mutationSubmissionSignal = mutationSubmissionSignal
        self.mutationSubmissionReadSignal = mutationSubmissionReadSignal
        self.mutationSubmittedAssetIDsSignal = mutationSubmittedAssetIDsSignal
        self.statisticsInventorySignal = statisticsInventorySignal
        self.statisticsClearCountSignal = statisticsClearCountSignal
        self.reminderRecordingSignal = reminderRecordingSignal
        self.settingsScanCountSignal = settingsScanCountSignal
        if let resolvedRepository {
            decisionQueues = DecisionQueueModel(
                repository: resolvedRepository,
                library: resolvedLibrary,
                inventoryStore: inventoryStore,
                onDecisionsChanged: { [weak self] in
                    self?.refreshPendingDecisions()
                }
            )
        }
        self.cleanupTasks = initialCleanupTasks
        self.currentPhotoStorageBytes = currentPhotoStorageBytes
        self.mediaPages = mediaPages
        if let resolvedRepository, !comparisonGroups.isEmpty {
            let routedTaskID: String?
            if case .comparison(let taskID)? = initialActiveRoute {
                routedTaskID = taskID
            } else {
                routedTaskID = nil
            }
            comparisonFlow = ComparisonFlowModel(
                groups: comparisonGroups,
                recommendations: comparisonRecommendations,
                decisionWorkflow: DecisionWorkflow(repository: resolvedRepository),
                taskID: routedTaskID,
                onDecisionsChanged: { [weak self] in
                    self?.refreshPendingDecisions()
                    if let routedTaskID {
                        self?.completeNoDeleteCleanupIfEligible(taskID: routedTaskID)
                    }
                }
            )
            if let routedTaskID {
                comparisonTaskID = routedTaskID
            }
        }
        if let initialScan {
            scan = initialScan
        } else {
            restoreWorkflowState()
        }
        if let initialActiveRoute {
            activeRoute = initialActiveRoute
            taskNavigationPath = [initialActiveRoute]
        }
        if let initialInventory { libraryInventory = initialInventory }
        isHomeInventoryReady = initialInventory != nil || initialScan?.phase == .completed
        refreshPendingDecisions()
        observeLibraryChanges()
    }

    deinit {
        scanTask?.cancel()
        libraryChangeTask?.cancel()
        comparisonLoadTask?.cancel()
    }

    func refreshAuthorization(forceScan: Bool = false) async {
        let generation = UUID()
        authorizationOperationGeneration = generation
        let latest = await library.authorizationStatus()
        guard authorizationOperationGeneration == generation else { return }
        let changed = latest != authorization
        let wasLoaded = hasLoadedAuthorization
        if changed { albumHome.invalidate() }

        if latest.canReadLibrary, !wasLoaded || changed {
            readableAuthorizationRecoveryGeneration = generation
            await reconcileInterruptedMutations()
            if readableAuthorizationRecoveryGeneration == generation {
                readableAuthorizationRecoveryGeneration = nil
            }
            guard authorizationOperationGeneration == generation else { return }
        }
        authorization = latest
        hasLoadedAuthorization = true
        if latest.canReadLibrary,
           scan.phase == .idle || (wasLoaded && changed) || (forceScan && scan.phase == .completed) {
            startScan()
        } else if !latest.canReadLibrary {
            scanTask?.cancel()
            scan = .idle
        }
    }

    func requestPhotoAccess() async {
        let generation = UUID()
        authorizationOperationGeneration = generation
        let latest = await library.requestAuthorization()
        guard authorizationOperationGeneration == generation else { return }
        if latest != authorization { albumHome.invalidate() }
        if latest.canReadLibrary {
            readableAuthorizationRecoveryGeneration = generation
            await reconcileInterruptedMutations()
            if readableAuthorizationRecoveryGeneration == generation {
                readableAuthorizationRecoveryGeneration = nil
            }
            guard authorizationOperationGeneration == generation else { return }
        }
        authorization = latest
        hasLoadedAuthorization = true
        if latest.canReadLibrary {
            startScan()
        } else {
            scanTask?.cancel()
            scan = .idle
        }
    }

    func refreshForAppActivation() async {
        homeNow = fixedHomeNow ?? .now
        let refreshAlbums = albumHome.hasLoaded || albumHome.isLoading || albumHome.errorMessage != nil
        await refreshAuthorization()
        await refreshReminderAuthorization()
        if authorization.canReadLibrary, refreshAlbums {
            await albumHome.load()
        }
    }

    func makeAlbumContentModel(collectionID: String) -> AlbumContentModel? {
        guard let collection = albumHome.collection(id: collectionID) else { return nil }
        return AlbumContentModel(
            collection: collection,
            library: library,
            isSimulated: albumHome.isSimulatedCollection(id: collectionID)
        )
    }

    func rescan() {
        if activeRoute == .weeklyInbox || taskNavigationPath.first == .weeklyInbox {
            returnFromWeeklyInbox()
        }
        restartScan()
    }

    func clearStatisticsHistory() async -> Bool {
        guard !isClearingStatisticsHistory else { return false }
        isClearingStatisticsHistory = true
        defer { isClearingStatisticsHistory = false }

        reminderMutationGeneration = UUID()
        desiredReminderEnabled = false
        desiredReminderWeekday = WorkflowSettings.defaults.reminderWeekday

        let wasLiveMutationBackend = await mutator.backendMode == .live
        guard statistics.clearHistory() else {
            desiredReminderEnabled = reminderEnabled
            desiredReminderWeekday = reminderWeekday
            await refreshStatisticsInventoryFingerprint()
            refreshStatisticsClearCallCount()
            return false
        }

        let reminderRemovalFailed: Bool
        do {
            try await notifications.removeWeeklyReminder()
            reminderRemovalFailed = false
        } catch {
            reminderRemovalFailed = true
        }

        scanTask?.cancel()
        scanGeneration = UUID()
        comparisonLoadTask?.cancel()
        comparisonLoadGeneration = UUID()
        decisionLoadGeneration = UUID()
        scan = .idle
        checkpointStore.clear()
        screenshotAgeDays = WorkflowSettings.defaults.screenshotRetentionDays
        cleanupTasks = []
        pendingDecisions = []
        allHomeDecisions = []
        refreshHomeProjection()
        mediaPages = []
        currentPhotoStorageBytes = nil
        comparisonFlow = nil
        comparisonTaskID = nil
        comparisonLoadError = nil
        isLoadingComparison = false
        decisionFlow = nil
        decisionTaskID = nil
        decisionLoadError = nil
        albumSelectionFlow = nil
        albumSelectionLoadError = nil
        deleteReviewFlow = nil
        deleteReviewLoadError = nil
        isPreparingDeleteReview = false
        cleanupResultsFlow = nil
        cleanupResultsSource = nil
        isPreparingCleanupResults = false
        weeklyInboxFlow = nil
        decisionQueues = repository.map {
            DecisionQueueModel(
                repository: $0,
                library: library,
                inventoryStore: inventoryStore,
                onDecisionsChanged: { [weak self] in
                    self?.refreshPendingDecisions()
                }
            )
        }
        activeRoute = nil
        taskNavigationPath = []
        weeklyModeEnabled = false
        reminderEnabled = false
        reminderWeekday = WorkflowSettings.defaults.reminderWeekday
        reminderGuidance = reminderRemovalFailed
            ? "历史已清除，但未能移除待处理提醒。请前往系统设置检查通知。"
            : nil
        reminderSynchronizationNeedsRetry = reminderRemovalFailed
        weeklyTransitionNeedsRetry = false
        weeklyBaselineAssetIDs = nil
        canEstablishInitialWeeklyBaseline = true
        debugRealMutationEnabled = false
#if DEBUG
        if wasLiveMutationBackend {
            mutator = MutationComposition.current(settings: .defaults)
            albumHome.replaceMutator(mutator)
            albumSelectionFlow?.replaceMutator(mutator)
            deleteReviewFlow?.replaceMutator(mutator)
            cleanupResultsFlow?.replaceMutator(mutator)
        }
#endif
        mutationBackendMode = await mutator.backendMode
        persistenceErrorMessage = nil
        screenshotPersistenceErrorMessage = nil
        await refreshStatisticsInventoryFingerprint()
        refreshStatisticsClearCallCount()
        return true
    }

    func refreshStatisticsInventoryFingerprint() async {
        statisticsInventoryFingerprint = await statisticsInventorySignal?()
    }

    func refreshStatisticsClearCallCount() {
        statisticsClearCallCount = statisticsClearCountSignal?()
    }

    func refreshSettingsSignals() async {
        reminderRecording = await reminderRecordingSignal?()
        settingsScanCount = await settingsScanCountSignal?()
    }

    func dismissStatisticsClearFailure() {
        statistics.dismissClearFailure()
    }

    func cancelScan() {
        guard scan.isScanning else { return }
        Task { await scanCoordinator.cancelCurrent() }
    }

    func resumeScan() {
        guard authorization.canReadLibrary, scan.phase == .cancelled else { return }
        startScan(mode: .resume)
    }

    func restartScan() {
        guard authorization.canReadLibrary else { return }
        startScan(mode: .restart)
    }

    func updateScreenshotAge(_ days: Int) {
        guard screenshotAgeDays != days else { return }
        guard let repository else {
            screenshotPersistenceErrorMessage = "无法保存截图提醒天数。请重试；当前设置未更改。"
            return
        }
        do {
            var settings = try repository.settings()
            settings.screenshotRetentionDays = days
            try repository.save(settings: settings)
        } catch {
            screenshotPersistenceErrorMessage = "无法保存截图提醒天数。请重试；当前设置未更改。"
            return
        }
        screenshotAgeDays = days
        screenshotPersistenceErrorMessage = nil
        rescan()
    }

    func updateReminderEnabled(_ enabled: Bool) async {
        guard !isClearingStatisticsHistory else { return }
        let wasDesiredEnabled = desiredReminderEnabled
        let generation = UUID()
        reminderMutationGeneration = generation
        desiredReminderEnabled = enabled
        if !enabled {
            guard reminderEnabled || wasDesiredEnabled || reminderSynchronizationNeedsRetry else { return }
            guard let repository else {
                reminderSynchronizationNeedsRetry = true
                reminderGuidance = "无法打开本地提醒设置，请稍后重试。"
                return
            }
            do {
                try await notifications.removeWeeklyReminder()
            } catch {
                guard reminderMutationIsCurrent(generation) else {
                    await repairPendingReminderAfterStaleMutation()
                    return
                }
                reminderSynchronizationNeedsRetry = true
                reminderGuidance = "无法移除待处理提醒；已保留当前开启状态。请稍后重试。"
                return
            }
            guard reminderMutationIsCurrent(generation) else {
                await repairPendingReminderAfterStaleMutation()
                return
            }
            do {
                var settings = try repository.settings()
                settings.reminderEnabled = false
                try repository.save(settings: settings)
                reminderEnabled = false
                reminderSynchronizationNeedsRetry = false
                reminderGuidance = nil
            } catch {
                reminderSynchronizationNeedsRetry = true
                do {
                    try await notifications.replaceWeeklyReminder(weekday: reminderWeekday)
                    guard reminderMutationIsCurrent(generation) else {
                        await repairPendingReminderAfterStaleMutation()
                        return
                    }
                    reminderGuidance = "无法保存关闭状态；已恢复原来的每周提醒。"
                } catch {
                    guard reminderMutationIsCurrent(generation) else {
                        await repairPendingReminderAfterStaleMutation()
                        return
                    }
                    reminderGuidance = "无法保存关闭状态，且未能恢复待处理提醒。当前设置可能不同步，请重试。"
                }
            }
            return
        }
        if reminderEnabled, wasDesiredEnabled, !reminderSynchronizationNeedsRetry { return }
        guard weeklyModeEnabled else {
            desiredReminderEnabled = false
            reminderEnabled = false
            reminderGuidance = "完成一次有实际决定的整理后，才可开启每周提醒。"
            return
        }
        guard let repository else {
            reminderSynchronizationNeedsRetry = true
            reminderEnabled = false
            reminderGuidance = "无法打开本地提醒设置，请稍后重试。"
            return
        }
        var authorization = await notifications.authorizationStatus()
        guard reminderMutationIsCurrent(generation) else { return }
        if authorization == .notDetermined {
            do {
                authorization = try await notifications.requestAuthorization()
            } catch {
                guard reminderMutationIsCurrent(generation) else { return }
                notificationAuthorization = .notDetermined
                reminderEnabled = false
                reminderSynchronizationNeedsRetry = true
                reminderGuidance = "通知授权请求失败，未开启每周提醒。请稍后重试。"
                return
            }
            guard reminderMutationIsCurrent(generation) else { return }
        }
        notificationAuthorization = authorization
        guard authorization.permitsWeeklyReminder else {
            desiredReminderEnabled = false
            reminderEnabled = false
            reminderSynchronizationNeedsRetry = false
            reminderGuidance = "通知未获允许。你仍可使用每周整理，并可在系统设置中开启通知。"
            return
        }
        do {
            try await notifications.replaceWeeklyReminder(weekday: desiredReminderWeekday)
        } catch {
            guard reminderMutationIsCurrent(generation) else {
                await repairPendingReminderAfterStaleMutation()
                return
            }
            reminderEnabled = false
            reminderSynchronizationNeedsRetry = true
            reminderGuidance = "通知已允许，但无法安排每周提醒。请稍后重试。"
            return
        }
        guard reminderMutationIsCurrent(generation) else {
            await repairPendingReminderAfterStaleMutation()
            return
        }
        do {
            var settings = try repository.settings()
            settings.reminderEnabled = true
            settings.reminderWeekday = desiredReminderWeekday
            try repository.save(settings: settings)
            reminderWeekday = desiredReminderWeekday
            reminderEnabled = true
            reminderSynchronizationNeedsRetry = false
            reminderGuidance = nil
        } catch {
            reminderEnabled = false
            reminderSynchronizationNeedsRetry = true
            do {
                try await notifications.removeWeeklyReminder()
                guard reminderMutationIsCurrent(generation) else {
                    await repairPendingReminderAfterStaleMutation()
                    return
                }
                reminderGuidance = "每周提醒未启用；已移除未保存的通知。"
            } catch {
                guard reminderMutationIsCurrent(generation) else {
                    await repairPendingReminderAfterStaleMutation()
                    return
                }
                reminderGuidance = "每周提醒未启用，但未能确认移除待处理通知。请前往系统设置检查通知。"
            }
        }
    }

    func retryReminderSynchronization() async {
        guard reminderSynchronizationNeedsRetry, !isClearingStatisticsHistory else { return }
        if desiredReminderEnabled {
            if reminderEnabled {
                await updateReminderWeekday(reminderWeekday)
            } else {
                await updateReminderEnabled(true)
            }
            return
        }

        let generation = UUID()
        reminderMutationGeneration = generation
        desiredReminderEnabled = false
        guard let repository else {
            reminderGuidance = "无法打开本地提醒设置，请稍后重试。"
            return
        }

        do {
            try await notifications.removeWeeklyReminder()
        } catch {
            guard reminderMutationIsCurrent(generation) else {
                await repairPendingReminderAfterStaleMutation()
                return
            }
            reminderSynchronizationNeedsRetry = true
            reminderGuidance = "每周提醒仍显示为关闭，但未能移除待处理通知。请重试。"
            return
        }
        guard reminderMutationIsCurrent(generation) else {
            await repairPendingReminderAfterStaleMutation()
            return
        }

        do {
            var settings = try repository.settings()
            if settings.reminderEnabled {
                settings.reminderEnabled = false
                try repository.save(settings: settings)
            }
            reminderEnabled = false
            reminderSynchronizationNeedsRetry = false
            reminderGuidance = nil
        } catch {
            reminderSynchronizationNeedsRetry = true
            reminderGuidance = "待处理提醒已移除，但无法确认保存关闭状态。请稍后重试。"
        }
    }

    func refreshReminderAuthorization() async {
        let mutationGeneration = reminderMutationGeneration
        let wasEnabled = reminderEnabled
        let authorization = await notifications.authorizationStatus()
        guard mutationGeneration == reminderMutationGeneration,
              wasEnabled == reminderEnabled else { return }
        notificationAuthorization = authorization
        guard !authorization.permitsWeeklyReminder else {
            if reminderEnabled { reminderGuidance = nil }
            return
        }
        let persistedEnabled = (try? repository?.settings().reminderEnabled) ?? false
        guard reminderEnabled || persistedEnabled || reminderSynchronizationNeedsRetry else {
            reminderGuidance = authorization == .notDetermined
                ? "提醒尚未开启。开启时才会请求通知权限。"
                : "通知未获允许。你仍可使用每周整理，并可在系统设置中开启通知。"
            return
        }

        desiredReminderEnabled = false

        var removedPendingRequest = true
        do {
            try await notifications.removeWeeklyReminder()
        } catch {
            removedPendingRequest = false
        }
        guard mutationGeneration == reminderMutationGeneration else {
            await repairPendingReminderAfterStaleMutation()
            return
        }
        reminderEnabled = false
        do {
            guard let repository else { throw ReminderSettingsError.repositoryUnavailable }
            var settings = try repository.settings()
            settings.reminderEnabled = false
            try repository.save(settings: settings)
            reminderSynchronizationNeedsRetry = !removedPendingRequest
            reminderGuidance = removedPendingRequest
                ? "通知未获允许。已关闭每周提醒；你仍可使用每周整理，并可在系统设置中开启通知。"
                : "通知未获允许，且未能确认移除待处理通知。请前往系统设置检查通知。"
        } catch {
            reminderSynchronizationNeedsRetry = true
            reminderGuidance = removedPendingRequest
                ? "通知未获允许，已移除待处理通知，但无法保存关闭状态。请稍后重试。"
                : "通知未获允许，且提醒状态无法同步。请前往系统设置检查通知后重试。"
        }
    }

    func updateReminderWeekday(_ weekday: Int) async {
        guard !isClearingStatisticsHistory, (1...7).contains(weekday) else { return }
        let generation = UUID()
        reminderMutationGeneration = generation
        desiredReminderEnabled = reminderEnabled
        desiredReminderWeekday = weekday
        guard reminderWeekday != weekday || reminderSynchronizationNeedsRetry else { return }
        guard let repository else {
            reminderSynchronizationNeedsRetry = true
            reminderGuidance = "无法打开本地提醒设置，请稍后重试。"
            return
        }
        let priorWeekday = reminderWeekday
        if reminderEnabled {
            do {
                try await notifications.replaceWeeklyReminder(weekday: weekday)
            } catch {
                guard reminderMutationIsCurrent(generation) else {
                    await repairPendingReminderAfterStaleMutation()
                    return
                }
                reminderSynchronizationNeedsRetry = true
                reminderGuidance = "无法更新提醒日期，已保留原设置。"
                return
            }
            guard reminderMutationIsCurrent(generation) else {
                await repairPendingReminderAfterStaleMutation()
                return
            }
        }
        do {
            var settings = try repository.settings()
            settings.reminderWeekday = weekday
            try repository.save(settings: settings)
            reminderWeekday = weekday
            reminderSynchronizationNeedsRetry = false
            reminderGuidance = nil
        } catch {
            reminderSynchronizationNeedsRetry = true
            guard reminderEnabled else {
                reminderGuidance = "无法保存新提醒日期，已保留原设置。"
                return
            }
            do {
                try await notifications.replaceWeeklyReminder(weekday: priorWeekday)
                guard reminderMutationIsCurrent(generation) else {
                    await repairPendingReminderAfterStaleMutation()
                    return
                }
                reminderGuidance = "无法保存新提醒日期；已恢复原来的\(Self.reminderWeekdayTitle(priorWeekday))提醒。"
            } catch {
                guard reminderMutationIsCurrent(generation) else {
                    await repairPendingReminderAfterStaleMutation()
                    return
                }
                reminderGuidance = "无法保存新提醒日期，且未能恢复原提醒。当前设置可能不同步，请重试。"
            }
        }
    }

    private func reminderMutationIsCurrent(_ generation: UUID) -> Bool {
        generation == reminderMutationGeneration && !isClearingStatisticsHistory
    }

    private func repairPendingReminderAfterStaleMutation() async {
        while true {
            let generation = reminderMutationGeneration
            do {
                if desiredReminderEnabled && !isClearingStatisticsHistory {
                    try await notifications.replaceWeeklyReminder(weekday: desiredReminderWeekday)
                } else {
                    try await notifications.removeWeeklyReminder()
                }
            } catch {
                if generation == reminderMutationGeneration {
                    reminderSynchronizationNeedsRetry = true
                    reminderGuidance = desiredReminderEnabled
                        ? "每周提醒仍显示为开启，但未能恢复待处理通知。请重试提醒日期。"
                        : "每周提醒仍显示为关闭，但未能移除待处理通知。请重试。"
                }
                return
            }
            guard generation != reminderMutationGeneration else { return }
        }
    }

    private static func reminderWeekdayTitle(_ weekday: Int) -> String {
        switch weekday {
        case 1: "星期日"
        case 2: "星期一"
        case 3: "星期二"
        case 4: "星期三"
        case 5: "星期四"
        case 6: "星期五"
        case 7: "星期六"
        default: "原日期"
        }
    }

    func updateDebugRealMutation(_ enabled: Bool) {
        #if DEBUG
        guard debugRealMutationEnabled != enabled else { return }
        guard let repository else { return }
        do {
            var settings = try repository.settings()
            settings.debugRealMutationEnabled = enabled
            try repository.save(settings: settings)
            debugRealMutationEnabled = enabled
            mutator = MutationComposition.current(settings: settings)
            albumHome.replaceMutator(mutator)
            albumSelectionFlow?.replaceMutator(mutator)
            deleteReviewFlow?.replaceMutator(mutator)
            cleanupResultsFlow?.replaceMutator(mutator)
            persistenceErrorMessage = nil
        } catch {
            persistenceErrorMessage = error.localizedDescription
        }
        #endif
    }

    func refreshMutationMode() async {
        mutationBackendMode = await mutator.backendMode
    }

    func reconcileInterruptedMutations() async {
        guard let repository else { return }
        do {
            try await MutationCoordinator(
                repository: repository,
                mutator: mutator
            ).reconcileInterruptedTransactions()
            refreshPendingDecisions()
            refreshCleanupTasks()
            persistenceErrorMessage = nil
        } catch {
            persistenceErrorMessage = error.localizedDescription
        }
    }

    func route(for task: CleanupTask) -> AppRoute {
        switch task.type {
        case .similar, .bursts:
            .comparison(task.id)
        case .screenshots, .duplicates, .largeVideos, .weekly, .dateBatch:
            .task(task.id)
        }
    }

    func startHomeCollection(_ source: CleanupHomeSource) {
        guard authorization.canReadLibrary, isHomeInventoryReady, !scan.isScanning else {
            homeNotice = "照片仍在载入，请稍后重试。"
            return
        }
        guard let repository else {
            homeNotice = "无法打开本地整理记录。"
            return
        }
        do {
            let plan = DateBatchPlanner.plan(
                source: source, descriptors: libraryInventory.descriptors,
                tasks: try repository.tasks(), decisions: try repository.decisions(),
                now: homeNow, calendar: homeCalendar
            )
            guard let task = plan.task else {
                homeNotice = plan.notice
                return
            }
            try repository.save(tasks: plan.newTasks)
            refreshCleanupTasks()
            homeNotice = nil
            openTask(task)
        } catch {
            homeNotice = "无法保存整理批次，请重试。"
            persistenceErrorMessage = error.localizedDescription
        }
    }

    func openTask(_ task: CleanupTask) {
        if task.type == .dateBatch {
            decisionFlow = nil
            decisionTaskID = nil
        }
        let destination = route(for: task)
        if taskNavigationPath.last != destination { taskNavigationPath.append(destination) }
        activeRoute = destination
    }

    private func refreshHomeProjection() {
        homeProjection = CleanupHomeProjection(
            descriptors: isHomeInventoryReady ? libraryInventory.descriptors : [],
            decisions: allHomeDecisions, calendar: homeCalendar
        )
    }

    private func pauseDepartedHomeTasks(from oldPath: [AppRoute]) {
        guard let repository else { return }
        let remainingIDs = Set(taskNavigationPath.compactMap { route -> String? in
            if case .task(let id) = route { return id }
            return nil
        })
        do {
            let departedIDs = Set(oldPath.compactMap { route -> String? in
                if case .task(let id) = route, !remainingIDs.contains(id) { return id }
                return nil
            })
            guard !departedIDs.isEmpty else { return }
            for task in try repository.tasks()
            where departedIDs.contains(task.id) && task.type == .dateBatch && task.status == .inProgress {
                _ = try TaskLifecycleController(repository: repository).pause(taskID: task.id)
            }
            refreshCleanupTasks()
        } catch {
            persistenceErrorMessage = "未能保存暂停位置，请重试。"
        }
    }

    func comparisonFlow(for taskID: String) -> ComparisonFlowModel? {
        comparisonTaskID == taskID ? comparisonFlow : nil
    }

    func singleDecisionFlow(for taskID: String) -> SinglePhotoDecisionFlow? {
        decisionTaskID == taskID ? decisionFlow : nil
    }

    func albumSelectionFlow(for assetID: String) -> AlbumSelectionFlow? {
        albumSelectionFlow?.assetID == assetID ? albumSelectionFlow : nil
    }

    func prepareDeleteReview() async {
        guard !isPreparingDeleteReview else { return }
        guard let repository else {
            deleteReviewLoadError = "无法打开本地整理记录"
            return
        }
        isPreparingDeleteReview = true
        deleteReviewLoadError = nil
        defer { isPreparingDeleteReview = false }
        if deleteReviewFlow == nil {
            deleteReviewFlow = DeleteReviewModel(
                repository: repository,
                library: library,
                inventoryStore: inventoryStore,
                mutator: mutator,
                submissionSignal: mutationSubmissionSignal,
                submissionReadSignal: mutationSubmissionReadSignal,
                onSubmissionCompleted: { [weak self] in
                    self?.refreshPendingDecisions()
                    self?.refreshCleanupTasks()
                },
                onTransactionCompleted: { [weak self] transaction in
                    self?.routeToCleanupResults(.transaction(transaction.id))
                }
            )
        }
        await deleteReviewFlow?.load()
    }

    func prepareCleanupResults(source: CleanupResultSource) async {
        guard !isPreparingCleanupResults else { return }
        guard let repository else { return }
        isPreparingCleanupResults = true
        defer { isPreparingCleanupResults = false }
        if cleanupResultsSource != source || cleanupResultsFlow == nil {
            cleanupResultsSource = source
            cleanupResultsFlow = CleanupResultsModel(
                source: source,
                repository: repository,
                mutator: mutator,
                retrySubmissionCountSignal: mutationSubmissionSignal,
                retrySubmissionSignal: mutationSubmittedAssetIDsSignal
            )
        }
        await cleanupResultsFlow?.load()
        enableWeeklyModeIfMeaningful(source: source)
        refreshPendingDecisions()
        refreshCleanupTasks()
    }

    func returnFromCleanupResults() {
        if weeklyTransitionNeedsRetry {
            persistenceErrorMessage = "整理结果已保留。请重试启用每周整理，或明确选择暂不启用后返回。"
            return
        }
        taskNavigationPath = []
        activeRoute = nil
        cleanupResultsSource = nil
        cleanupResultsFlow = nil
        guard let repository else {
            persistenceErrorMessage = "已返回任务列表，但无法清除上次结果的恢复位置。下次启动时可能再次打开该结果。"
            return
        }
        do {
            var settings = try repository.settings()
            settings.pendingResultSource = nil
            try repository.save(settings: settings)
            persistenceErrorMessage = nil
        } catch {
            persistenceErrorMessage = "已返回任务列表，但无法清除上次结果的恢复位置。下次启动时可能再次打开该结果。"
        }
    }

    func leaveCleanupResultsKeepingRecovery() {
        guard weeklyTransitionNeedsRetry else {
            returnFromCleanupResults()
            return
        }
        taskNavigationPath = []
        activeRoute = nil
        persistenceErrorMessage = "尚未启用每周整理；整理结果将在下次启动时继续恢复。"
    }

    func prepareWeeklyInbox() async {
        guard let repository else { return }
        if weeklyInboxFlow == nil {
            weeklyInboxFlow = WeeklyInboxModel(
                repository: repository,
                library: library,
                inventoryStore: inventoryStore,
                previouslyAccessibleAssetIDs: weeklyBaselineAssetIDs
            )
        }
        await weeklyInboxFlow?.refresh(screenshotRetentionDays: screenshotAgeDays)
    }

    func returnFromWeeklyInbox() {
        taskNavigationPath = []
        activeRoute = nil
        weeklyInboxFlow = nil
    }

    func retryWeeklyModeTransition() {
        guard let source = cleanupResultsSource else { return }
        enableWeeklyModeIfMeaningful(source: source)
    }

    func startWeeklyInboxItem(_ item: WeeklyInboxItem) {
        guard let repository else { return }
        do {
            let route: AppRoute
            if let task = item.task {
                if try !repository.tasks().contains(where: { $0.id == task.id }) {
                    try repository.save(task: task)
                    refreshCleanupTasks()
                }
                route = self.route(for: task)
            } else {
                route = .decideLater
            }
            if taskNavigationPath.last != route {
                taskNavigationPath.append(route)
            }
            activeRoute = route
            persistenceErrorMessage = nil
        } catch {
            persistenceErrorMessage = "无法开始这项整理，请重试。"
        }
    }

    func prepareSingleDecision(taskID: String) async {
        guard readableAuthorizationRecoveryGeneration == nil else { return }
        guard decisionTaskID != taskID || decisionFlow == nil else { return }
        decisionLoadError = nil
        guard let repository else {
            decisionLoadError = "无法打开本地整理记录"
            return
        }
        let generation = UUID()
        decisionLoadGeneration = generation

        do {
            guard let storedTask = try repository.tasks().first(where: { $0.id == taskID }) else {
                decisionLoadError = "找不到此整理任务"
                return
            }
            guard storedTask.type != .similar && storedTask.type != .bursts else {
                decisionLoadError = "此任务需要照片对比"
                return
            }
            if storedTask.type == .dateBatch && (!authorization.canReadLibrary || !isHomeInventoryReady) {
                decisionLoadError = "请等待照片载入完成后重试。"
                return
            }
            var task = storedTask.status == .completed
                ? storedTask
                : try TaskLifecycleController(repository: repository).start(taskID: taskID)
            let descriptorsByID = try await descriptorsByID(for: task.assetIDs)
            guard decisionLoadGeneration == generation, !Task.isCancelled else { return }
            let descriptors = task.assetIDs.map { descriptorsByID[$0] ?? unavailableDescriptor(for: $0) }
            let decisions = try repository.decisions().filter { $0.taskID == taskID }
            var eligibleIDs: Set<String>?
            if task.type == .dateBatch {
                let decidedIDs = Set(try repository.decisions().map(\.assetID))
                let localIDs = Set(descriptors.filter { $0.availability == .local }.map(\.id))
                let available = Set(task.ownedAssetIDs).intersection(localIDs).subtracting(decidedIDs)
                guard let nextIndex = task.assetIDs.firstIndex(where: { available.contains($0) }) else {
                    _ = try TaskLifecycleController(repository: repository).pause(taskID: taskID)
                    decisionLoadError = "本批暂无可整理的本地照片，进度已保存。"
                    refreshCleanupTasks()
                    return
                }
                task.ownedAssetIDs = task.assetIDs.filter { available.contains($0) }
                task.currentAssetIndex = nextIndex
                try repository.save(task: task)
                eligibleIDs = available
            }
            let hasReversibleUndo: Bool
            if let undo = try repository.latestUndo(), undo.taskID == taskID {
                hasReversibleUndo = try repository.decision(for: undo.assetID)?.isSubmitted == false
            } else {
                hasReversibleUndo = false
            }
            decisionTaskID = taskID
            decisionFlow = SinglePhotoDecisionFlow(
                task: task,
                descriptors: descriptors,
                decisionWorkflow: DecisionWorkflow(repository: repository),
                existingDecisions: decisions,
                hasReversibleUndo: hasReversibleUndo,
                eligibleAssetIDs: eligibleIDs,
                undoAssetID: try repository.latestUndo()?.assetID,
                onDecisionsChanged: { [weak self] in
                    self?.refreshPendingDecisions()
                    self?.refreshCleanupTasks()
                    self?.completeNoDeleteCleanupIfEligible(taskID: taskID)
                    self?.finishDateBatchSessionIfNeeded(taskID: taskID)
                },
                onArchiveRequested: { [weak self] assetID in
                    self?.taskNavigationPath.append(.albumSelection(assetID))
                }
            )
            refreshCleanupTasks()
        } catch {
            guard decisionLoadGeneration == generation, !Task.isCancelled else { return }
            decisionLoadError = error.localizedDescription
        }
    }

    func prepareAlbumSelection(assetID: String) async {
        guard albumSelectionFlow?.assetID != assetID else { return }
        albumSelectionLoadError = nil
        guard let repository else {
            albumSelectionLoadError = "无法打开本地整理记录"
            return
        }

        let descriptor = decisionFlow?.currentDescriptor
        let routedDescriptor = descriptor?.id == assetID ? descriptor : nil
        let routedTaskID = routedDescriptor == nil ? nil : decisionTaskID
        let flow = AlbumSelectionFlow(
            assetID: assetID,
            taskID: routedTaskID,
            estimatedBytes: routedDescriptor?.estimatedBytes ?? 0,
            repository: repository,
            mutator: mutator,
            onArchiveSucceeded: { [weak self] decision in
                self?.completeAlbumSelection(with: decision)
            }
        )
        albumSelectionFlow = flow
        await flow.loadAlbums()
    }

    func prepareComparison(taskID: String) async {
        guard comparisonTaskID != taskID || comparisonFlow == nil else { return }
        comparisonLoadTask?.cancel()
        let generation = UUID()
        comparisonLoadGeneration = generation
        isLoadingComparison = true
        comparisonLoadError = nil
        let task = Task { [weak self] in
            guard let self else { return }
            await self.loadComparison(taskID: taskID, generation: generation)
        }
        comparisonLoadTask = task
        await task.value
    }

    private func loadComparison(taskID: String, generation: UUID) async {
        defer {
            if isCurrentComparisonLoad(generation) {
                isLoadingComparison = false
                comparisonLoadTask = nil
            }
        }
        guard isCurrentComparisonLoad(generation) else { return }
        guard let repository else {
            comparisonLoadError = "无法打开本地整理记录"
            return
        }

        do {
            guard let task = try repository.tasks().first(where: { $0.id == taskID }) else {
                comparisonLoadError = "找不到此整理任务"
                return
            }
            guard task.type == .similar || task.type == .bursts else {
                comparisonLoadError = "此任务不支持照片对比"
                return
            }

            let decidedAssetIDs = Set(try repository.decisions()
                .filter { task.assetIDs.contains($0.assetID) }
                .map(\.assetID))
            let remainingAssetIDs = task.assetIDs.filter { !decidedAssetIDs.contains($0) }
            if remainingAssetIDs.isEmpty {
                _ = try TaskLifecycleController(repository: repository).complete(taskID: taskID)
                refreshCleanupTasks()
                completeNoDeleteCleanupIfEligible(taskID: taskID)
                comparisonTaskID = taskID
                comparisonFlow = ComparisonFlowModel(
                    groups: [],
                    recommendations: [],
                    decisionWorkflow: DecisionWorkflow(repository: repository)
                )
                return
            }

            let activeTask = try TaskLifecycleController(repository: repository).start(taskID: taskID)
            let activeAssetIDs = activeTask.ownedAssetIDs.filter { !decidedAssetIDs.contains($0) }
            guard !activeAssetIDs.isEmpty else {
                comparisonLoadError = "此任务中的照片正在由其他任务处理"
                return
            }

            let descriptorsByID = try await descriptorsByID(for: activeAssetIDs)
            guard isCurrentComparisonLoad(generation) else { return }
            let analysisEngine = LocalPhotoAnalysisEngine()
            let thumbnails = await thumbnailLoader.load(
                assetIDs: activeAssetIDs,
                maxPixelSize: 256
            )
            let thumbnailsByID = Dictionary(uniqueKeysWithValues: thumbnails.map { ($0.assetID, $0) })
            let candidates = activeAssetIDs.map { assetID in
                let descriptor = descriptorsByID[assetID] ?? unavailableDescriptor(for: assetID)
                return PhotoCandidate(
                    asset: descriptor,
                    quality: thumbnailsByID[assetID].flatMap(analysisEngine.qualitySignals)
                        ?? metadataQuality(for: descriptor),
                    manualProtection: false
                )
            }
            let group = PhotoCandidateGroup(
                id: "task:\(task.id)",
                kind: task.type == .similar ? .similar : .burst,
                candidates: candidates
            )
            let recommendation = analysisEngine.recommendation(for: group)

            comparisonTaskID = taskID
            comparisonFlow = ComparisonFlowModel(
                groups: [group],
                recommendations: [recommendation],
                decisionWorkflow: DecisionWorkflow(repository: repository),
                taskID: taskID,
                onDecisionsChanged: { [weak self] in
                    guard let self else { return }
                    self.refreshPendingDecisions()
                    self.refreshCleanupTasks()
                    self.completeNoDeleteCleanupIfEligible(taskID: taskID)
                }
            )
            refreshCleanupTasks()
        } catch {
            guard isCurrentComparisonLoad(generation) else { return }
            comparisonLoadError = error.localizedDescription
        }
    }

    func restoreWorkflowState() {
        guard let repository else {
            persistenceErrorMessage = "无法打开本地整理记录"
            return
        }
        do {
            cleanupTasks = try repository.tasks()
            pendingDecisions = try repository.decisions().filter { !$0.isSubmitted }
            let settings = try repository.settings()
            screenshotAgeDays = settings.screenshotRetentionDays
            debugRealMutationEnabled = settings.debugRealMutationEnabled
            weeklyModeEnabled = settings.weeklyModeEnabled
            reminderEnabled = settings.reminderEnabled
            reminderWeekday = settings.reminderWeekday
            weeklyTransitionNeedsRetry = false
            weeklyBaselineAssetIDs = Self.initialWeeklyBaseline(from: repository)
            weeklyInboxFlow?.updatePreviouslyAccessibleAssetIDs(weeklyBaselineAssetIDs)
            canEstablishInitialWeeklyBaseline = !settings.weeklyModeEnabled && weeklyBaselineAssetIDs == nil
            if let checkpoint = try repository.latestCheckpoint(),
               checkpoint.stage != .completed {
                scan = checkpoint.snapshot
                checkpointStore.restore(checkpoint)
            }
            let fallbackRoute: AppRoute? = nil
            var resultRestorationError: String?
            if let source = settings.pendingResultSource {
                do {
                    activeRoute = try shouldRestoreResultSource(source, repository: repository)
                        ? .result(source)
                        : fallbackRoute
                } catch {
                    activeRoute = .result(source)
                    resultRestorationError = error.localizedDescription
                }
            } else {
                activeRoute = fallbackRoute
            }
            taskNavigationPath = activeRoute.map { [$0] } ?? []
            persistenceErrorMessage = resultRestorationError
        } catch {
            persistenceErrorMessage = error.localizedDescription
        }
    }

    private func refreshPendingDecisions() {
        do {
            allHomeDecisions = try repository?.decisions() ?? []
            pendingDecisions = allHomeDecisions.filter { !$0.isSubmitted }
            refreshHomeProjection()
        } catch {
            persistenceErrorMessage = error.localizedDescription
        }
    }

    private func refreshCleanupTasks() {
        do {
            cleanupTasks = try repository?.tasks() ?? []
        } catch {
            persistenceErrorMessage = error.localizedDescription
        }
    }

    private func completeAlbumSelection(with decision: PhotoDecision) {
        if taskNavigationPath.last == .albumSelection(decision.assetID) {
            taskNavigationPath.removeLast()
        }
        decisionFlow?.recordArchiveSuccess(decision)
        refreshPendingDecisions()
        refreshCleanupTasks()
        if let taskID = decision.taskID {
            completeNoDeleteCleanupIfEligible(taskID: taskID)
            finishDateBatchSessionIfNeeded(taskID: taskID)
        }
    }

    private func finishDateBatchSessionIfNeeded(taskID: String) {
        guard let repository, decisionFlow?.isCompleted == true else { return }
        do {
            guard let task = try repository.tasks().first(where: { $0.id == taskID }),
                  task.type == .dateBatch else { return }
            if try repository.decisions().contains(where: {
                $0.taskID == taskID && $0.kind == .deleteCandidate && !$0.isSubmitted
            }) {
                if taskNavigationPath.last != .deleteReview { taskNavigationPath.append(.deleteReview) }
                activeRoute = .deleteReview
            } else if task.status != .completed {
                taskNavigationPath = []
                activeRoute = nil
                homeNotice = "本批剩余照片暂不可用，进度已保存。"
            }
        } catch {
            persistenceErrorMessage = error.localizedDescription
        }
    }

    func completeNoDeleteCleanupIfEligible(taskID: String) {
        guard let repository else { return }
        do {
            guard let task = try repository.tasks().first(where: { $0.id == taskID }),
                  task.status == .completed else { return }
            let decisions = try repository.decisions().filter { $0.taskID == taskID }
            guard !decisions.contains(where: { $0.kind == .deleteCandidate }) else { return }
            let supportedDecisions = decisions.filter {
                [.keep, .archive, .protect, .decideLater].contains($0.kind)
            }
            guard !supportedDecisions.isEmpty else { return }

            let summaryID = CleanupSummary.identifier(forTaskID: taskID)
            let summary: CleanupSummary
            switch try repository.summary(id: summaryID) {
            case .found(let existing):
                summary = existing
            case .missing:
                summary = CleanupSummary(
                    decisions: supportedDecisions,
                    elapsedSeconds: nil,
                    id: summaryID,
                    createdAt: task.updatedAt
                )
                try repository.save(summary: summary)
            case .corrupt:
                persistenceErrorMessage = "这次整理摘要已损坏，无法安全打开结果。请返回任务列表后重试。"
                return
            }
            routeToCleanupResults(.summary(summary.id))
        } catch {
            persistenceErrorMessage = error.localizedDescription
        }
    }

    private func routeToCleanupResults(_ source: CleanupResultSource) {
        let route = AppRoute.result(source)
        if taskNavigationPath.last == .deleteReview {
            taskNavigationPath[taskNavigationPath.count - 1] = route
        } else if taskNavigationPath.last != route {
            taskNavigationPath.append(route)
        }
        activeRoute = route

        guard let repository else {
            persistenceErrorMessage = "整理结果已打开，但无法保存恢复位置。退出应用后可能无法回到本页，请完成后返回任务列表。"
            return
        }
        do {
            var settings = try repository.settings()
            if settings.pendingResultSource != source {
                settings.pendingResultSource = source
                try repository.save(settings: settings)
            }
            persistenceErrorMessage = nil
        } catch {
            persistenceErrorMessage = "整理结果已打开，但无法保存恢复位置。退出应用后可能无法回到本页，请完成后返回任务列表。"
        }
    }

    private func enableWeeklyModeIfMeaningful(source: CleanupResultSource) {
        guard cleanupResultsFlow?.loadState == .ready,
              let projection = cleanupResultsFlow?.projection,
              let repository else { return }
        do {
            let hasSupportedDecision = projection.keepCount + projection.archiveSucceededCount
                + projection.protectCount + projection.decideLaterCount > 0
            let isMeaningful: Bool
            switch source {
            case .summary(let id):
                switch try repository.summary(id: id) {
                case .found(let summary):
                    isMeaningful = summary.keptCount + summary.archivedCount
                        + summary.protectedCount + summary.deferredCount > 0
                case .missing, .corrupt:
                    isMeaningful = false
                }
            case .transaction(let id):
                switch try repository.transaction(id: id) {
                case .found(let transaction):
                    isMeaningful = hasSupportedDecision || (
                        transaction.operation == .delete
                        && transaction.items.contains(where: {
                            [.submitted, .succeeded, .failed, .cancelled].contains($0.state)
                        })
                    )
                case .missing, .corrupt:
                    isMeaningful = false
                }
            }
            guard isMeaningful else {
                weeklyTransitionNeedsRetry = false
                return
            }
            establishInitialWeeklyBaselineIfAvailable()
            var settings = try repository.settings()
            if !settings.weeklyModeEnabled {
                settings.weeklyModeEnabled = true
                try repository.save(settings: settings)
            }
            weeklyModeEnabled = true
            canEstablishInitialWeeklyBaseline = false
            weeklyTransitionNeedsRetry = false
            persistenceErrorMessage = nil
        } catch {
            weeklyTransitionNeedsRetry = true
            persistenceErrorMessage = "整理结果已保留，但无法启用每周整理。请重试。"
        }
    }

    private func shouldRestoreResultSource(
        _ source: CleanupResultSource,
        repository: any TaskRepository
    ) throws -> Bool {
        switch source {
        case .transaction(let id):
            switch try repository.transaction(id: id) {
            case .found, .corrupt: true
            case .missing: false
            }
        case .summary(let id):
            switch try repository.summary(id: id) {
            case .found, .corrupt: true
            case .missing: false
            }
        }
    }

    private func isCurrentComparisonLoad(_ generation: UUID) -> Bool {
        !Task.isCancelled && comparisonLoadGeneration == generation
    }

    private func unavailableDescriptor(for assetID: String) -> PhotoAssetDescriptor {
        PhotoAssetDescriptor(
            id: assetID,
            mediaType: .photo,
            creationDate: nil,
            pixelWidth: 0,
            pixelHeight: 0,
            duration: 0,
            estimatedBytes: 0,
            isFavorite: false,
            isEdited: false,
            isScreenshot: false,
            burstIdentifier: nil,
            availability: .unavailable
        )
    }

    private func startScan(mode: ScanStartMode = .restart) {
        scanTask?.cancel()
        isHomeInventoryReady = false
        refreshHomeProjection()
        if cleanupTasks.contains(where: { $0.id == decisionTaskID && $0.type == .dateBatch }) {
            decisionFlow = nil
            decisionTaskID = nil
            decisionLoadGeneration = UUID()
        }
        scan = .starting
        let ageDays = screenshotAgeDays
        let coordinator = scanCoordinator
        let checkpoint: ScanCheckpoint?
        switch mode {
        case .resume:
            checkpoint = checkpointStore.latest
        case .restart:
            checkpoint = nil
        }
        let generation = UUID()
        scanGeneration = generation

        scanTask = Task { [weak self] in
            let updates = await coordinator.start(
                screenshotAgeDays: ageDays,
                mode: mode,
                checkpoint: checkpoint
            )
            var completedUpdate: LibraryScanSnapshot?
            for await update in updates {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard self.scanGeneration == generation else { return }
                if update.phase == .completed {
                    // Hold the terminal snapshot until the final descriptor set has
                    // been materialized, so completion and task state are atomic to UI.
                    completedUpdate = update
                    continue
                }
                self.scan = update
                if let descriptors = await coordinator.takePartialDescriptors() {
                    self.materializeScanTasks(from: descriptors, includeGroups: false)
                }
            }
            guard !Task.isCancelled,
                  let self,
                  self.scanGeneration == generation,
                  self.checkpointStore.latest?.stage == .completed else { return }
            if let descriptors = await coordinator.takeCompletedDescriptors() {
                self.libraryInventory = LibraryInventory(descriptors: descriptors)
                self.isHomeInventoryReady = true
                self.refreshHomeProjection()
                await self.inventoryStore.replace(with: descriptors)
                // A scan refreshes the current inventory but must not erase
                // local decisions just because an asset is temporarily outside
                // the readable scope (for example, after a limited-access change).
                // Review flows reconcile against the current descriptors when
                // they need to submit a mutation.
                self.materializeScanTasks(from: descriptors)
            }
            if let completedUpdate,
               !Task.isCancelled,
               self.scanGeneration == generation {
                self.scan = completedUpdate
            }
            self.establishInitialWeeklyBaselineIfAvailable()
            await self.statistics.load()
        }
    }

    private func descriptorsByID(
        for assetIDs: [String]
    ) async throws -> [String: PhotoAssetDescriptor] {
        let requestedIDs = Set(assetIDs)
        var result = Dictionary(
            uniqueKeysWithValues: libraryInventory.descriptors
                .filter { requestedIDs.contains($0.id) }
                .map { ($0.id, $0) }
        )
        let missingIDs = assetIDs.filter { result[$0] == nil }
        if !missingIDs.isEmpty {
            let fetched = try await library.assetDescriptors(for: missingIDs)
            libraryInventory.merge(
                PhotoLibraryChange(
                    addedAssetIDs: fetched.map(\.id),
                    removedAssetIDs: [],
                    scopeChanged: false
                ),
                addedDescriptors: fetched
            )
            for descriptor in fetched where requestedIDs.contains(descriptor.id) {
                result[descriptor.id] = descriptor
            }
        }
        return result
    }

    private func materializeScanTasks(
        from descriptors: [PhotoAssetDescriptor],
        includeGroups: Bool = true
    ) {
        guard let repository else { return }
        let generated = CleanupTaskGenerator().generate(
            descriptors: descriptors,
            screenshotAgeDays: screenshotAgeDays,
            includeGroups: includeGroups
        )
        do {
            let existingTasks = try repository.tasks()
            let existingByID = Dictionary(uniqueKeysWithValues: existingTasks.map { ($0.id, $0) })
            let generatedIDs = Set(generated.map(\.id))
            let staleTaskIDs = Self.staleScanTaskIDs(
                existingTasks: existingTasks,
                generatedTaskIDs: generatedIDs,
                includeGroups: includeGroups
            )
            let staleTasks: [CleanupTask]
            if includeGroups {
                staleTasks = existingTasks.compactMap { existing -> CleanupTask? in
                    guard staleTaskIDs.contains(existing.id) else { return nil }
                    var invalid = existing
                    invalid.assetIDs = []
                    invalid.ownedAssetIDs = []
                    invalid.currentAssetIndex = 0
                    invalid.status = .invalid
                    invalid.updatedAt = .now
                    return invalid
                }
            } else {
                staleTasks = []
            }
            let generatedTasks = generated.compactMap { generatedTask -> CleanupTask? in
                guard let existing = existingByID[generatedTask.id] else {
                    return generatedTask
                }
                let merged = Self.mergeGeneratedTask(generatedTask, preserving: existing)
                return merged == existing ? nil : merged
            }
            let tasksToSave = staleTasks + generatedTasks
            guard !tasksToSave.isEmpty else {
                refreshCleanupTasks()
                return
            }
            do {
                try repository.save(tasks: tasksToSave)
            } catch TaskRepositoryBatchError.atomicPersistenceUnsupported {
                for task in tasksToSave {
                    try repository.save(task: task)
                }
            }
            refreshCleanupTasks()
        } catch {
            persistenceErrorMessage = error.localizedDescription
        }
    }

    nonisolated static func mergeGeneratedTask(
        _ generated: CleanupTask,
        preserving existing: CleanupTask
    ) -> CleanupTask {
        let generatedIDs = Set(generated.assetIDs)
        let discoveredNewAsset = !generatedIDs.isSubset(of: Set(existing.assetIDs))
        let shouldReopenTerminalTask = discoveredNewAsset
            && (existing.status == .completed || existing.status == .skipped)
        let preservedIndex: Int
        let currentAssetID = existing.assetIDs.indices.contains(existing.currentAssetIndex)
            ? existing.assetIDs[existing.currentAssetIndex]
            : nil
        if let currentAssetID,
           let generatedIndex = generated.assetIDs.firstIndex(of: currentAssetID) {
            preservedIndex = generatedIndex
        } else {
            preservedIndex = min(existing.currentAssetIndex, generated.assetIDs.count)
        }
        return CleanupTask(
            id: generated.id,
            type: generated.type,
            title: generated.title,
            reason: generated.reason,
            assetIDs: generated.assetIDs,
            estimatedBytes: generated.estimatedBytes,
            estimatedMinutes: generated.estimatedMinutes,
            risk: generated.risk,
            confidence: generated.confidence,
            status: shouldReopenTerminalTask ? .queued : existing.status,
            ownedAssetIDs: shouldReopenTerminalTask
                ? []
                : existing.ownedAssetIDs.filter { generatedIDs.contains($0) },
            currentAssetIndex: shouldReopenTerminalTask
                ? 0
                : preservedIndex,
            skipCount: existing.skipCount,
            lastSkippedAt: existing.lastSkippedAt,
            createdAt: existing.createdAt,
            updatedAt: .now
        )
    }

    nonisolated static func staleScanTaskIDs(
        existingTasks: [CleanupTask],
        generatedTaskIDs: Set<String>,
        includeGroups: Bool
    ) -> Set<String> {
        guard includeGroups else { return [] }
        let scanTaskTypes: Set<CleanupTaskType> = [
            .screenshots, .duplicates, .similar, .bursts, .largeVideos
        ]
        return Set(existingTasks.compactMap { task in
            guard task.id.hasPrefix("scan:"),
                  scanTaskTypes.contains(task.type),
                  !generatedTaskIDs.contains(task.id) else { return nil }
            return task.id
        })
    }

    private func metadataQuality(for descriptor: PhotoAssetDescriptor) -> PhotoQualitySignals {
        let pixels = max(0, descriptor.pixelWidth * descriptor.pixelHeight)
        let resolution = min(1, log10(Double(pixels) + 1) / 8)
        let exposure = descriptor.creationDate == nil ? 0.5 : 0.6
        return PhotoQualitySignals(
            sharpness: resolution,
            exposure: exposure,
            completeness: resolution
        )
    }

    private func observeLibraryChanges() {
        let library = self.library
        libraryChangeTask = Task { [weak self] in
            let stream = await library.libraryChanges()
            for await change in stream {
                guard !Task.isCancelled, let self else { return }
                await self.handleLibraryChange(change)
            }
        }
    }

    private func handleLibraryChange(_ change: PhotoLibraryChange) async {
        guard authorization.canReadLibrary else { return }
        let reloadAlbums = albumHome.hasLoaded || albumHome.isLoading
        if change.scopeChanged { albumHome.invalidate() }
        if reloadAlbums { await albumHome.load() }
        if change.scopeChanged {
            startScan()
            return
        }
        guard !change.addedAssetIDs.isEmpty || !change.removedAssetIDs.isEmpty else { return }
        do {
            let additions = try await library.assetDescriptors(for: change.addedAssetIDs)
            libraryInventory.merge(change, addedDescriptors: additions)
            refreshHomeProjection()
            await inventoryStore.merge(change, addedDescriptors: additions)
            try repository?.reconcile(
                availableAssetIDs: Set(libraryInventory.descriptors.map(\.id))
            )
            if let taskID = decisionTaskID,
               var task = try repository?.tasks().first(where: { $0.id == taskID && $0.type == .dateBatch }) {
                let localIDs = Set(libraryInventory.descriptors.filter { $0.availability == .local }.map(\.id))
                task.ownedAssetIDs.removeAll { !localIDs.contains($0) }
                let eligibleIDs = Set(task.ownedAssetIDs)
                task.currentAssetIndex = task.assetIDs.firstIndex(where: { eligibleIDs.contains($0) })
                    ?? task.assetIDs.count
                if eligibleIDs.isEmpty && task.status == .inProgress { task.status = .paused }
                try repository?.save(task: task)
                decisionFlow?.updateEligibility(eligibleIDs)
                finishDateBatchSessionIfNeeded(taskID: taskID)
            }
            if !additions.isEmpty {
                materializeScanTasks(
                    from: libraryInventory.descriptors,
                    includeGroups: !scan.isScanning
                )
            }
            refreshCleanupTasks()
        } catch {
            persistenceErrorMessage = error.localizedDescription
        }
    }

    private func establishInitialWeeklyBaselineIfAvailable() {
        guard canEstablishInitialWeeklyBaseline,
              let baseline = Self.initialWeeklyBaseline(from: repository) else { return }
        weeklyBaselineAssetIDs = baseline
        weeklyInboxFlow?.updatePreviouslyAccessibleAssetIDs(baseline)
        canEstablishInitialWeeklyBaseline = false
    }

    private static func initialWeeklyBaseline(from repository: (any TaskRepository)?) -> Set<String>? {
        guard let repository else { return nil }
        do {
            switch try repository.initialCompletedCheckpoint() {
            case .found(let checkpoint): return Set(checkpoint.processedAssetIDs)
            case .missing, .corrupt: return nil
            }
        } catch {
            return nil
        }
    }
}

nonisolated private enum ReminderSettingsError: Error {
    case repositoryUnavailable
}

@MainActor
private final class AppModelCheckpointStore {
    private let repository: (any TaskRepository)?
    private(set) var latest: ScanCheckpoint?

    init(repository: (any TaskRepository)?) {
        self.repository = repository
    }

    func restore(_ checkpoint: ScanCheckpoint) {
        latest = checkpoint
    }

    func clear() {
        latest = nil
    }

    func save(_ checkpoint: ScanCheckpoint) {
        latest = checkpoint
        do {
            try repository?.save(checkpoint: checkpoint)
        } catch {
            // A later scan can retry persistence without discarding visible safe progress.
        }
    }
}
