import SwiftUI

struct AlbumsWorkspaceView: View {
    @Bindable var model: AppModel
    @ScaledMetric(relativeTo: .subheadline) private var quickAccessWidth = 96
    @State private var scrollPosition = AlbumHomeScrollPosition()

    var body: some View {
        @Bindable var home = model.albumHome
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    Text("相册").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button { home.beginCreation() } label: {
                        Image(systemName: "plus").font(.system(size: 24, weight: .medium))
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.photoBoxAccent)
                    .accessibilityLabel("新建相册")
                    .accessibilityIdentifier("album-home-add")
                }
                if home.isLimited {
                    Label("仅显示已授权的相册与照片", systemImage: "photo.badge.checkmark")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("album-home-limited")
                }
                if let notice = home.notice {
                    Text(notice).font(.subheadline).foregroundStyle(.secondary)
                        .accessibilityIdentifier("album-home-notice")
                }
                if home.isLoading && !home.hasLoaded && home.albums.isEmpty {
                    ProgressView("正在载入相册")
                        .accessibilityIdentifier("album-home-loading")
                }
                if let error = home.errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .accessibilityIdentifier("album-home-error")
                        Button("重试") { Task { await home.load() } }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("album-home-retry")
                    }
                }
                if !home.quickAccess.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            ForEach(home.quickAccess) { collection in
                                collectionLink(collection, quick: true)
                                    .frame(width: min(quickAccessWidth, 240))
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .accessibilityIdentifier("album-quick-access")
                }
                VStack(alignment: .leading, spacing: 18) {
                    Text("我的相册").font(.title2.bold())
                    if home.albums.isEmpty && home.hasLoaded && home.errorMessage == nil {
                        ContentUnavailableView("暂无相册", systemImage: "rectangle.stack")
                            .accessibilityIdentifier("album-home-empty")
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 16, alignment: .top), GridItem(.flexible(), alignment: .top)], alignment: .leading, spacing: 24) {
                        ForEach(home.albums) { collection in
                            collectionLink(collection, quick: false)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 16) {
                    Divider()
                    if let queues = model.decisionQueues {
                        queueContent(queues)
                    } else {
                        ContentUnavailableView("无法打开整理队列", systemImage: "exclamationmark.triangle")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .background {
                AlbumHomeScrollPositionProbe(position: scrollPosition)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .background(Color(red: 18 / 255, green: 19 / 255, blue: 22 / 255).ignoresSafeArea())
        .accessibilityIdentifier("albums-workspace-list")
        .navigationTitle("相册")
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $home.isPresentingCreation) {
            AlbumCreationSheet(model: home)
        }
        .refreshable { await home.load() }
        .task {
            await home.load()
            await model.decisionQueues?.loadIfNeeded()
        }
    }

    private func collectionLink(_ collection: PhotoCollectionDescriptor, quick: Bool) -> some View {
        NavigationLink(value: AppRoute.collection(collection.id)) {
            VStack(alignment: .leading, spacing: 7) {
                AlbumThumbnailView(assetID: collection.coverAssetID, loader: model.thumbnailLoader)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .bottomLeading) {
                        if collection.kind == .favorites {
                            Image(systemName: "heart.fill").foregroundStyle(.white)
                                .shadow(radius: 2).padding(8)
                        }
                    }
                Text(collection.title)
                    .font(quick ? .subheadline.weight(.medium) : .body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(collection.assetCount) 项")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(AlbumHomeNavigationStyle(position: scrollPosition))
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(collection.title)
        .accessibilityValue("\(collection.assetCount) 项")
        .accessibilityIdentifier("album-\(quick ? "quick" : "grid")-\(collection.id)")
    }

    @ViewBuilder
    private func queueContent(_ queues: DecisionQueueModel) -> some View {
        if queues.hasLoadedSuccessfully {
            WorkspaceNavigationRow(
                route: .decideLater,
                icon: "bookmark",
                tint: .photoBoxWarm,
                title: "稍后决定",
                count: queues.decideLaterCount,
                identifier: "albums-decide-later",
                countIdentifier: "albums-decide-later-count",
                scrollPosition: scrollPosition
            )
            WorkspaceNavigationRow(
                route: .protectedPhotos,
                icon: "shield.checkered",
                tint: .photoBoxAccent,
                title: "已保护",
                count: queues.protectedCount,
                identifier: "albums-protected",
                countIdentifier: "albums-protected-count",
                scrollPosition: scrollPosition
            )
            if case .failed(let message) = queues.loadState {
                queueFailure(message, queues: queues)
            }
            if let message = queues.reconciliationMessage {
                Label(message, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("albums-queue-reconciliation")
            }
            #if DEBUG
            if isDecisionQueueUITest {
                queueFixtureDiagnostics
            }
            #endif
        } else {
            switch queues.loadState {
            case .loading, .loaded:
                HStack(spacing: 12) {
                    ProgressView()
                    Text("正在载入整理队列")
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("albums-queue-loading")
            case .failed(let message):
                queueFailure(message, queues: queues)
            }
        }
    }

    private func queueFailure(_ message: String, queues: DecisionQueueModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .accessibilityIdentifier("albums-queue-error")
            Button("重试") {
                Task { await queues.load() }
            }
            .accessibilityIdentifier("albums-queue-retry")
        }
    }

    #if DEBUG
    private var isDecisionQueueUITest: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--ui-testing-queues-reset")
            || arguments.contains("--ui-testing-queues")
    }

    @ViewBuilder
    private var queueFixtureDiagnostics: some View {
        let decisions = model.pendingDecisions
        let deferred = decisions.first { $0.assetID == "queue-later" }
        QueueFixtureValue(
            value: decisions.count { $0.kind == .deleteCandidate }.formatted(),
            identifier: "queue-fixture-delete-count"
        )
        QueueFixtureValue(
            value: deferred?.kind.rawValue ?? "missing",
            identifier: "queue-fixture-later-kind"
        )
        QueueFixtureValue(
            value: deferred?.taskID ?? "missing",
            identifier: "queue-fixture-later-task"
        )
        QueueFixtureValue(
            value: deferred.map { String($0.estimatedBytes) } ?? "missing",
            identifier: "queue-fixture-later-bytes"
        )
    }
    #endif
}

#if DEBUG
private struct QueueFixtureValue: View {
    let value: String
    let identifier: String

    var body: some View {
        Text(value)
            .accessibilityIdentifier(identifier)
    }
}
#endif

private struct WorkspaceNavigationRow: View {
    let route: AppRoute
    let icon: String
    let tint: Color
    let title: String
    let count: Int
    let identifier: String
    let countIdentifier: String
    let scrollPosition: AlbumHomeScrollPosition

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .frame(width: 28)
                Text(title)
                Spacer()
                Text(count, format: .number)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityIdentifier(countIdentifier)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(AlbumHomeNavigationStyle(position: scrollPosition))
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(title)
        .accessibilityValue("\(count) 项")
    }
}

private struct AlbumHomeNavigationStyle: PrimitiveButtonStyle {
    let position: AlbumHomeScrollPosition

    func makeBody(configuration: Configuration) -> some View {
        Button {
            position.captureForNavigation()
            configuration.trigger()
        } label: {
            configuration.label
        }
        .buttonStyle(.plain)
    }
}
