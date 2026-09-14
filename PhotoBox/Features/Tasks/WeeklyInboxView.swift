import SwiftUI

struct WeeklyInboxScreen: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if let flow = model.weeklyInboxFlow, let plan = flow.plan {
                inbox(flow: flow, plan: plan)
            } else if let flow = model.weeklyInboxFlow, let message = flow.errorMessage {
                failure(message)
            } else {
                VStack {
                    ProgressView("正在载入本周整理")
                        .accessibilityIdentifier("weekly-loading")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("weekly-inbox-list")
            }
        }
        .navigationTitle("本周收件箱")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await model.prepareWeeklyInbox() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.weeklyInboxFlow?.isLoading == true)
                .accessibilityLabel("刷新本周整理")
                .accessibilityIdentifier("weekly-refresh")
            }
        }
        .task {
            if model.weeklyInboxFlow?.plan == nil {
                await model.prepareWeeklyInbox()
            }
        }
    }

    private func inbox(flow: WeeklyInboxModel, plan: WeeklyInboxPlan) -> some View {
        List {
            if let message = flow.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("weekly-refresh-warning")
                }
            }

            if plan.isTrulyEmpty {
                Section {
                    ContentUnavailableView(
                        "本周已整理好",
                        systemImage: "checkmark.circle",
                        description: Text("当前可访问范围内没有需要处理的新照片、过期截图、未完成任务或到期的稍后决定。")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("weekly-tidy-empty")
                    .accessibilityLabel("本周已整理好")
                    .accessibilityValue("当前可访问范围内没有需要处理的新照片、过期截图、未完成任务或到期的稍后决定")

                    Button {
                        Task { await model.prepareWeeklyInbox() }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .accessibilityIdentifier("weekly-refresh-empty")
                }
            } else if plan.items.isEmpty {
                Section {
                    ContentUnavailableView(
                        "本周仍有待处理任务",
                        systemImage: "clock.badge.exclamationmark",
                        description: Text("有 \(plan.remainingTaskCount) 项完整任务预计超过本周 5 分钟计划，可返回任务列表继续处理。")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .accessibilityIdentifier("weekly-work-over-limit")

                    Button {
                        model.returnFromWeeklyInbox()
                    } label: {
                        Label("返回任务列表", systemImage: "list.bullet")
                    }
                    .accessibilityIdentifier("weekly-return-to-tasks")
                }
            } else {
                Section("本周计划") {
                    LabeledContent("任务") {
                        Text(plan.taskCount, format: .number)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("任务")
                    .accessibilityIdentifier("weekly-task-count")
                    .accessibilityValue("\(plan.taskCount) 项")
                    LabeledContent("预计时间") {
                        Text("约 \(plan.estimatedMinutes) 分钟")
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("预计时间")
                    .accessibilityIdentifier("weekly-duration")
                    .accessibilityValue("约 \(plan.estimatedMinutes) 分钟")
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("完成进度")
                            Spacer()
                            Text(plan.progress, format: .percent.precision(.fractionLength(0)))
                        }
                        ProgressView(value: plan.progress)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("完成进度")
                    .accessibilityIdentifier("weekly-progress")
                    .accessibilityValue(plan.progress.formatted(.percent.precision(.fractionLength(0))))
                }

                ForEach(plan.items) { item in
                    Section {
                        Button {
                            model.startWeeklyInboxItem(item)
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: item.source.systemImage)
                                    .foregroundStyle(.tint)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title)
                                        .font(.headline)
                                    Text(item.reason)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Text("\(item.assetIDs.count) 项 · 约 \(item.estimatedMinutes) 分钟")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.forward")
                                    .font(.caption.bold())
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("weekly-start-\(item.id)")
                        .accessibilityLabel("开始\(item.title)")
                        .accessibilityValue("\(item.assetIDs.count) 项，约 \(item.estimatedMinutes) 分钟，\(item.reason)")
                    } header: {
                        Text(item.source.title)
                            .accessibilityIdentifier("weekly-source-\(item.id)")
                    }
                }

                if plan.remainingTaskCount > 0 {
                    Section {
                        Label(
                            "另有 \(plan.remainingTaskCount) 项工作未加入本周 5 分钟计划",
                            systemImage: "clock.badge.exclamationmark"
                        )
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("weekly-work-remaining")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("weekly-inbox-list")
        .refreshable { await model.prepareWeeklyInbox() }
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 16) {
            ContentUnavailableView {
                Label("无法载入本周整理", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("weekly-load-failure")
            .accessibilityLabel("无法载入本周整理")
            .accessibilityValue(message)

            Button("重试") {
                Task { await model.prepareWeeklyInbox() }
            }
            .accessibilityIdentifier("weekly-load-retry")
        }
    }
}
