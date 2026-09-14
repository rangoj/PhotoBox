import Photos
import SwiftUI

struct MainTabView: View {
    @Bindable var model: AppModel
    @State private var selectedTab = MainTab.organize

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $model.taskNavigationPath) {
                CleanupHomeView(model: model) {
                    openOrganizeRoute(.duplicates)
                }
                    .navigationDestination(for: AppRoute.self) { route in
                        TaskRouteView(route: route, model: model)
                    }
            }
            .tabItem { Label("整理", systemImage: "photo.on.rectangle") }
            .tag(MainTab.organize)

            NavigationStack {
                AlbumsWorkspaceView(model: model)
                    .navigationDestination(for: AppRoute.self) { route in
                        AlbumRouteView(route: route, model: model)
                    }
            }
            .tabItem { Label("相册", systemImage: "rectangle.stack") }
            .tag(MainTab.albums)

            NavigationStack {
                MyWorkspaceView(
                    model: model,
                    openOrganizeRoute: openOrganizeRoute,
                    openTask: openTask
                )
            }
            .tabItem { Label("我的", systemImage: "person.crop.circle") }
            .tag(MainTab.my)
        }
        .tint(Color(red: 170 / 255, green: 199 / 255, blue: 255 / 255))
        .preferredColorScheme(.dark)
    }

    private func openOrganizeRoute(_ route: AppRoute) {
        selectedTab = .organize
        if model.taskNavigationPath.last != route {
            model.taskNavigationPath.append(route)
        }
        model.activeRoute = route
    }

    private func openTask(_ task: CleanupTask) {
        selectedTab = .organize
        model.openTask(task)
    }
}

private enum MainTab: Hashable {
    case organize
    case albums
    case my
}

private struct AlbumRouteView: View {
    let route: AppRoute
    @Bindable var model: AppModel

    var body: some View {
        Group {
            switch route {
            case .collection(let id):
                AlbumContentView(collectionID: id, appModel: model)
            case .decideLater:
                queueScreen(kind: .decideLater)
            case .protectedPhotos:
                queueScreen(kind: .protectedPhotos)
            default:
                ContentUnavailableView("无法打开此相册", systemImage: "exclamationmark.triangle")
            }
        }
        .toolbar(.visible, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
    }

    @ViewBuilder
    private func queueScreen(kind: DecisionQueueKind) -> some View {
        if let queues = model.decisionQueues {
            DecisionQueueScreen(kind: kind, model: queues, loader: model.thumbnailLoader)
        } else {
            ContentUnavailableView("无法打开整理队列", systemImage: "exclamationmark.triangle")
                .navigationTitle(kind.title)
        }
    }
}

private struct TaskRouteView: View {
    let route: AppRoute
    @Bindable var model: AppModel

    var body: some View {
        Group {
            switch route {
            case .duplicates:
                DuplicateTasksView(model: model)
            case .taskDashboard:
                TaskDashboardView(model: model)
            case .diagnosis:
                DiagnosisReportView(model: model)
            case .task(let taskID):
                if let decisionFlow = model.singleDecisionFlow(for: taskID) {
                    SinglePhotoDecisionScreen(model: decisionFlow, loader: model.thumbnailLoader)
                } else {
                    SingleDecisionRouteView(taskID: taskID, model: model)
                }
            case .comparison(let taskID):
                if let comparisonFlow = model.comparisonFlow(for: taskID) {
                    ComparisonFlowScreen(model: comparisonFlow, loader: model.thumbnailLoader)
                } else if taskID == "media-fixture", !model.mediaPages.isEmpty {
                    MediaPagerScreen(pages: model.mediaPages, loader: model.thumbnailLoader)
                } else {
                    ComparisonRouteView(taskID: taskID, model: model)
                }
            case .decision:
                ContentUnavailableView("整理照片", systemImage: "photo")
                    .navigationTitle("整理照片")
            case .albumSelection(let assetID):
                if let albumFlow = model.albumSelectionFlow(for: assetID) {
                    AlbumSelectionScreen(model: albumFlow)
                } else {
                    AlbumSelectionRouteView(assetID: assetID, model: model)
                }
            case .collection(let id):
                AlbumContentView(collectionID: id, appModel: model)
            case .deleteReview:
                if let deleteReviewFlow = model.deleteReviewFlow, !model.isPreparingDeleteReview {
                    DeleteReviewScreen(model: deleteReviewFlow)
                } else {
                    DeleteReviewRouteView(model: model)
                }
            case .result(let source):
                if let resultsFlow = model.cleanupResultsFlow,
                   model.cleanupResultsSource == source,
                   !model.isPreparingCleanupResults {
                    CleanupResultsScreen(
                        model: resultsFlow,
                        persistenceMessage: model.persistenceErrorMessage,
                        onLifecycle: { await model.refreshSettingsSignals() }
                    ) {
                        model.returnFromCleanupResults()
                    }
                    .toolbar {
                        if model.weeklyTransitionNeedsRetry {
                            ToolbarItemGroup(placement: .topBarLeading) {
                                Button {
                                    model.retryWeeklyModeTransition()
                                } label: {
                                    Label("重试启用每周整理", systemImage: "arrow.clockwise")
                                }
                                .accessibilityIdentifier("cleanup-results-weekly-retry")
                                Button("暂不启用每周整理并返回") {
                                    model.leaveCleanupResultsKeepingRecovery()
                                }
                                .accessibilityIdentifier("cleanup-results-weekly-exit")
                            }
                        }
                    }
                } else {
                    CleanupResultsRouteView(source: source, model: model)
                }
            case .weeklyInbox:
                WeeklyInboxScreen(model: model)
            case .decideLater:
                if let queues = model.decisionQueues {
                    DecisionQueueScreen(
                        kind: .decideLater,
                        model: queues,
                        loader: model.thumbnailLoader
                    )
                } else {
                    ContentUnavailableView("无法打开整理队列", systemImage: "exclamationmark.triangle")
                        .navigationTitle("稍后决定")
                }
            case .protectedPhotos:
                ContentUnavailableView("受保护照片", systemImage: "lock.shield")
                    .navigationTitle("受保护照片")
            }
        }
        .toolbar(.hidden, for: .tabBar)
    }
}

private struct CleanupResultsRouteView: View {
    let source: CleanupResultSource
    @Bindable var model: AppModel

    var body: some View {
        ProgressView("正在载入整理结果")
            .accessibilityIdentifier("cleanup-results-loading")
            .accessibilityLabel("正在载入整理结果")
            .accessibilityValue("正在读取本地整理记录")
            .navigationTitle("整理结果")
            .navigationBarBackButtonHidden(true)
            .task(id: source) { await model.prepareCleanupResults(source: source) }
    }
}

private struct DeleteReviewRouteView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if let message = model.deleteReviewLoadError {
                VStack(spacing: 16) {
                    ContentUnavailableView(
                        "无法载入删除复核",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                    Button("重试") {
                        Task { await model.prepareDeleteReview() }
                    }
                    .accessibilityIdentifier("delete-review-load-retry")
                    .accessibilityHint("重新载入仍可访问的删除候选")
                }
            } else {
                ProgressView("正在载入删除复核")
                    .accessibilityIdentifier("delete-review-loading")
            }
        }
        .navigationTitle("删除复核")
        .task {
            if model.deleteReviewFlow == nil {
                await model.prepareDeleteReview()
            }
        }
    }
}

private struct AlbumSelectionRouteView: View {
    let assetID: String
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if let message = model.albumSelectionLoadError {
                VStack(spacing: 16) {
                    ContentUnavailableView(
                        "无法载入系统相册",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                    Button("重试") {
                        Task { await model.prepareAlbumSelection(assetID: assetID) }
                    }
                    .accessibilityIdentifier("album-load-retry")
                    .accessibilityHint("重新载入可访问的系统相册")
                }
            } else {
                ProgressView("正在载入相册")
                    .accessibilityIdentifier("album-loading-state")
            }
        }
        .navigationTitle("选择相册")
        .task(id: assetID) {
            await model.prepareAlbumSelection(assetID: assetID)
        }
    }
}

private struct SingleDecisionRouteView: View {
    let taskID: String
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if let message = model.decisionLoadError {
                VStack(spacing: 16) {
                    ContentUnavailableView(
                        "无法打开整理任务",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                    Button("重试") {
                        Task { await model.prepareSingleDecision(taskID: taskID) }
                    }
                    .accessibilityIdentifier("decision-load-retry")
                }
            } else {
                ProgressView("正在载入整理任务")
                    .accessibilityIdentifier("decision-loading")
            }
        }
        .navigationTitle("整理照片")
        .task(id: taskID) {
            await model.prepareSingleDecision(taskID: taskID)
        }
    }
}

private struct ComparisonRouteView: View {
    let taskID: String
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if let message = model.comparisonLoadError {
                VStack(spacing: 16) {
                    ContentUnavailableView(
                        "无法打开照片对比",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                    Button("重试") {
                        Task { await model.prepareComparison(taskID: taskID) }
                    }
                    .accessibilityIdentifier("comparison-load-retry")
                }
            } else {
                ProgressView("正在载入照片对比")
                    .accessibilityIdentifier("comparison-loading")
            }
        }
        .navigationTitle("照片对比")
        .task(id: taskID) {
            await model.prepareComparison(taskID: taskID)
        }
    }
}
