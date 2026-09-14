import SwiftUI

struct CleanupResultsScreen: View {
    @Bindable var model: CleanupResultsModel
    let persistenceMessage: String?
    let onLifecycle: () async -> Void
    let onReturn: () -> Void
    @State private var isRetryConfirmationPresented = false

    var body: some View {
        List {
            switch model.loadState {
            case .loading:
                Section {
                    ProgressView("正在载入整理结果")
                        .accessibilityIdentifier("cleanup-results-loading")
                        .accessibilityLabel("正在载入整理结果")
                        .accessibilityValue("正在读取本地整理记录")
                }
            case .missing, .failed:
                recoverySection
            case .ready:
                if let projection = model.projection {
                    resultSections(projection)
                } else {
                    recoverySection
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("整理结果")
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("返回任务") { onReturn() }
                    .accessibilityIdentifier("cleanup-results-return")
            }
        }
        .confirmationDialog(
            "确认重试未完成的删除吗？",
            isPresented: $isRetryConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("确认重试删除", role: .destructive) {
                Task { await model.retry() }
            }
            .accessibilityIdentifier("cleanup-results-retry-confirm")
            Button("取消", role: .cancel) {
                Task { await model.refreshRetrySubmissionSignal() }
            }
            .accessibilityIdentifier("cleanup-results-retry-cancel")
        } message: {
            Text("只会再次提交仍未完成且当前可访问的照片。")
        }
        .task {
            await model.load()
            await onLifecycle()
        }
    }

    @ViewBuilder
    private func resultSections(_ projection: CleanupResultProjection) -> some View {
        if projection.hasDeletionResult {
            Section("删除结果") {
                LabeledContent("已移到最近删除") {
                    Text("\(projection.succeededDeleteCount) 项")
                        .foregroundStyle(.green)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("已移到最近删除")
                .accessibilityIdentifier("cleanup-results-deleted-count")
                .accessibilityValue("\(projection.succeededDeleteCount) 项")
                if projection.unresolvedDeleteCount > 0 {
                    LabeledContent("未完成，可重试") {
                        Text("\(projection.unresolvedDeleteCount) 项")
                            .foregroundStyle(.orange)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("未完成，可重试")
                    .accessibilityIdentifier("cleanup-results-unresolved-count")
                    .accessibilityValue("\(projection.unresolvedDeleteCount) 项")
                }
                if projection.staleDeleteCount > 0 {
                    LabeledContent("照片已不可用") {
                        Text("\(projection.staleDeleteCount) 项")
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("照片已不可用")
                    .accessibilityIdentifier("cleanup-results-stale-count")
                    .accessibilityValue("\(projection.staleDeleteCount) 项")
                }
                if projection.estimatedReclaimableBytes > 0 {
                    LabeledContent("预计可释放") {
                        Text(ByteCountFormatter.string(fromByteCount: projection.estimatedReclaimableBytes, countStyle: .file))
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("cleanup-results-estimated-space")
                    .accessibilityLabel("预计可释放")
                    .accessibilityValue(formattedCleanupResultBytes(projection.estimatedReclaimableBytes))
                }
                Text("照片会先保留在“最近删除”中，空间释放为预计值，清空“最近删除”后才会永久释放。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("cleanup-results-recently-deleted-guidance")
            }
        }

        Section("本次整理") {
            if !projection.hasDeletionResult {
                LabeledContent("删除候选") {
                    Text("0 项")
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("删除候选")
                .accessibilityIdentifier("cleanup-results-delete-candidate-count")
                .accessibilityValue("0 项")
            }
            if projection.archiveSucceededCount > 0 {
                LabeledContent("归档成功") {
                    Text("\(projection.archiveSucceededCount) 项")
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("归档成功")
                .accessibilityIdentifier("cleanup-results-archive-count")
                .accessibilityValue("\(projection.archiveSucceededCount) 项")
            }
            if projection.protectCount > 0 {
                LabeledContent("已保护") {
                    Text("\(projection.protectCount) 项")
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("已保护")
                .accessibilityIdentifier("cleanup-results-protect-count")
                .accessibilityValue("\(projection.protectCount) 项")
            }
            if projection.decideLaterCount > 0 {
                LabeledContent("稍后决定") {
                    Text("\(projection.decideLaterCount) 项")
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("稍后决定")
                .accessibilityIdentifier("cleanup-results-deferred-count")
                .accessibilityValue("\(projection.decideLaterCount) 项")
            }
            if projection.keepCount > 0 {
                LabeledContent("保留") {
                    Text("\(projection.keepCount) 项")
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("保留")
                .accessibilityIdentifier("cleanup-results-keep-count")
                .accessibilityValue("\(projection.keepCount) 项")
            }
            if let elapsedSeconds = projection.elapsedSeconds {
                LabeledContent("用时") {
                    Text(elapsedSeconds.formatted(.number.precision(.fractionLength(0))) + " 秒")
                        .accessibilityIdentifier("cleanup-results-elapsed")
                }
            }
        }

        if projection.canRetry || model.recoveryMessage != nil || persistenceMessage != nil || !model.recordedRetryAssetIDs.isEmpty {
            Section {
                if let persistenceMessage {
                    Text(persistenceMessage).foregroundStyle(.orange)
                        .accessibilityIdentifier("cleanup-results-persistence-warning")
                }
                if let recoveryMessage = model.recoveryMessage {
                    Text(recoveryMessage).foregroundStyle(.red)
                        .accessibilityIdentifier("cleanup-results-recovery")
                }
                if projection.canRetry {
                    Button("重试未完成的删除") { isRetryConfirmationPresented = true }
                        .disabled(model.isRetrying)
                        .accessibilityIdentifier("cleanup-results-retry")
                }
                if model.hasRetrySubmissionCountSignal {
                    Text("测试删除请求 \(model.recordedRetrySubmissionCount) 次")
                        .accessibilityIdentifier("cleanup-results-recorded-retry-count")
                        .accessibilityValue("\(model.recordedRetrySubmissionCount)")
                }
                if !model.recordedRetryAssetIDs.isEmpty {
                    Text("已提交 \(model.recordedRetryAssetIDs.count) 项未完成请求")
                        .accessibilityIdentifier(
                            "cleanup-results-recorded-retry-ids:"
                                + model.recordedRetryAssetIDs.sorted().joined(separator: ",")
                        )
                        .accessibilityValue("\(model.recordedRetryAssetIDs.count) 项")
                }
            }
        }
    }

    private var recoverySection: some View {
        Section {
            ContentUnavailableView("无法显示整理结果", systemImage: "exclamationmark.triangle", description: Text(model.recoveryMessage ?? "请返回任务列表。"))
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier(recoveryStateIdentifier)
                .accessibilityLabel("无法显示整理结果")
                .accessibilityValue(model.recoveryMessage ?? "请返回任务列表。")
            Button("重新载入") { Task { await model.load() } }
                .accessibilityIdentifier("cleanup-results-reload")
        }
    }

    private var recoveryStateIdentifier: String {
        model.loadState == .missing ? "cleanup-results-missing" : "cleanup-results-failed"
    }
}

private func formattedCleanupResultBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
