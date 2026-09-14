import SwiftUI

struct MyWorkspaceView: View {
    @Bindable var model: AppModel
    let openOrganizeRoute: (AppRoute) -> Void
    let openTask: (CleanupTask) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var feedbackDraft = ""

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    metric("累计整理", value: model.myHome.projection?.processedCount, identifier: "my-processed-total")
                    metric("累计删除", value: model.myHome.projection?.deletedCount, identifier: "my-deleted-total")
                }
                .padding(.vertical, 24)
                .listRowSeparator(.hidden)
                if let error = model.myHome.errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error).font(.subheadline).foregroundStyle(.secondary)
                            .accessibilityIdentifier("my-home-error")
                        Button("重试") { Task { await model.myHome.load() } }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("my-home-retry")
                    }
                } else if model.myHome.isLoading && model.myHome.projection == nil {
                    ProgressView("正在读取整理记录")
                        .accessibilityIdentifier("my-home-loading")
                }
                NavigationLink {
                    MyHistoryView(model: model.myHome)
                        .toolbar(.hidden, for: .tabBar)
                } label: {
                    Label("整理记录", systemImage: "clock.arrow.circlepath")
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("my-history")
                NavigationLink {
                    SettingsView(model: model)
                        .toolbar(.hidden, for: .tabBar)
                } label: {
                    Label("设置", systemImage: "gearshape")
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("my-settings")
            }

            Section {
                NavigationLink {
                    MyHelpView().toolbar(.hidden, for: .tabBar)
                } label: {
                    Label("帮助", systemImage: "questionmark.circle").frame(minHeight: 44)
                }
                .accessibilityIdentifier("my-help")
                NavigationLink {
                    MyFeedbackView(draft: $feedbackDraft).toolbar(.hidden, for: .tabBar)
                } label: {
                    Label("反馈", systemImage: "bubble.left").frame(minHeight: 44)
                }
                .accessibilityIdentifier("my-feedback")
                NavigationLink {
                    MyAboutView().toolbar(.hidden, for: .tabBar)
                } label: {
                    Label("关于", systemImage: "info.circle").frame(minHeight: 44)
                }
                .accessibilityIdentifier("my-about")
            }

            if !unfinishedTasks.isEmpty {
                Section("继续整理") {
                    ForEach(unfinishedTasks.prefix(3)) { task in
                        Button {
                            openTask(task)
                        } label: {
                            MyWorkspaceRow(
                                icon: task.type == .dateBatch ? "calendar" : "arrow.forward.circle",
                                title: task.title,
                                detail: unfinishedDetail(task),
                                value: nil
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("my-unfinished-\(task.id)")
                        .accessibilityLabel(task.title)
                        .accessibilityValue(unfinishedDetail(task))
                    }
                }
            }

            Section("概览") {
                NavigationLink {
                    StatisticsView(model: model)
                        .toolbar(.hidden, for: .tabBar)
                } label: {
                    MyWorkspaceRow(
                        icon: "chart.bar",
                        title: "统计",
                        detail: "整理进度与空间估算",
                        value: nil
                    )
                }
                .accessibilityIdentifier("my-statistics")

                Button {
                    openOrganizeRoute(.taskDashboard)
                } label: {
                    MyWorkspaceRow(
                        icon: "tray.full",
                        title: "整理任务",
                        detail: "未完成任务与扫描诊断",
                        value: activeTaskCount > 0 ? activeTaskCount.formatted() : nil
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("my-task-dashboard")
                .accessibilityLabel("整理任务")
                .accessibilityValue("\(activeTaskCount) 个未完成任务")
            }

            Section("恢复与回顾") {
                Button {
                    openOrganizeRoute(.deleteReview)
                } label: {
                    MyWorkspaceRow(
                        icon: "trash",
                        title: "删除复核",
                        detail: "确认待删除照片",
                        value: pendingDeleteCount > 0 ? pendingDeleteCount.formatted() : nil
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("my-delete-review")
                .accessibilityLabel("删除复核")
                .accessibilityValue("\(pendingDeleteCount) 张待复核照片")

                Button {
                    openOrganizeRoute(.weeklyInbox)
                } label: {
                    MyWorkspaceRow(
                        icon: "calendar.badge.clock",
                        title: "每周整理",
                        detail: "查看本周收件箱",
                        value: nil
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("my-weekly-inbox")
                .accessibilityLabel("每周整理")
            }

        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(red: 18 / 255, green: 19 / 255, blue: 22 / 255).ignoresSafeArea())
        .navigationTitle("我的")
        .accessibilityIdentifier("my-workspace-list")
        .task { await model.myHome.load() }
        .refreshable { await model.myHome.load() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.myHome.load() } }
        }
    }

    private func metric(_ title: String, value: Int?, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value?.formatted() ?? "--")
                .font(.title.bold()).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            Text(title).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value.map { "\($0) 张" } ?? "暂不可用")
        .accessibilityIdentifier(identifier)
    }

    private var unfinishedTasks: [CleanupTask] {
        TaskRanker().rank(model.cleanupTasks.filter {
            $0.status == .inProgress || $0.status == .paused
        })
    }

    private var activeTaskCount: Int {
        model.cleanupTasks.filter(\.isQualifyingCleanupCandidate).count
    }

    private var pendingDeleteCount: Int {
        model.pendingDecisions.count { $0.kind == .deleteCandidate && !$0.isSubmitted }
    }

    private func unfinishedDetail(_ task: CleanupTask) -> String {
        let processed = min(task.currentAssetIndex, task.assetIDs.count)
        return "已处理 \(processed) / \(task.assetIDs.count) 张"
    }
}

private struct MyWorkspaceRow: View {
    let icon: String
    let title: String
    let detail: String
    let value: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(.tint)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}
