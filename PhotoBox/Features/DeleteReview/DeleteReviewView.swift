import SwiftUI

struct DeleteReviewScreen: View {
    @Bindable var model: DeleteReviewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmationPresented = false

    var body: some View {
        List {
            summarySection

            if case .failed(let message) = model.loadState {
                Section {
                    ContentUnavailableView(
                        "无法载入删除复核",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("delete-review-load-failed")
                    .accessibilityLabel("无法载入删除复核")
                    .accessibilityValue(message)
                    Button("重新载入") {
                        Task { await model.retryLoad() }
                    }
                    .accessibilityIdentifier("delete-review-retry")
                }
            } else if case .loading = model.loadState {
                Section {
                    ProgressView("正在载入删除复核")
                        .accessibilityIdentifier("delete-review-loading")
                }
            } else if model.selectedCandidates.isEmpty {
                Section {
                    ContentUnavailableView(
                        "没有待删除的照片",
                        systemImage: "checkmark.circle",
                        description: Text("可返回任务列表继续整理，所有未提交决定仍可撤销。")
                    )
                    .accessibilityIdentifier("delete-review-empty")
                    if model.recoveryRequiresReload {
                        Button("重新载入未完成请求") {
                            Task { await model.reloadRecovery() }
                        }
                        .accessibilityIdentifier("delete-review-recovery-reload")
                    }
                }
            } else {
                Section("待删除照片") {
                    ForEach(model.selectedCandidates) { candidate in
                        candidateRow(candidate)
                    }
                }
            }

            if let message = model.submissionErrorMessage, !isLoadFailure {
                Section {
                    Text(message)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("delete-review-error")
                    Button(model.retryTransactionID == nil ? "重新载入" : "重新确认并重试") {
                        if model.retryTransactionID == nil {
                            Task { await model.retryLoad() }
                        } else {
                            isConfirmationPresented = true
                        }
                    }
                    .disabled(model.isSubmitting || (model.retryTransactionID != nil && model.selectedCandidateIDs.isEmpty))
                    .accessibilityIdentifier("delete-review-retry")
                }
            }

            if model.hasSubmissionSignal {
                Section {
                    Text("测试提交记录 " + String(model.recordedSubmissionCount) + " 次")
                        .accessibilityIdentifier("delete-review-submission-count")
                        .accessibilityValue("\(model.recordedSubmissionCount)")
                    Text("测试记录读取 " + String(model.recordedSubmissionReadCount) + " 次")
                        .accessibilityIdentifier("delete-review-submission-read-count")
                        .accessibilityValue("\(model.recordedSubmissionReadCount)")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("删除复核")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("退出复核") {
                    Task {
                        await model.refreshSubmissionSignal()
                        dismiss()
                    }
                }
                .accessibilityIdentifier("delete-review-exit")
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button("确认删除 \(model.selectedCandidateIDs.count) 项", role: .destructive) {
                isConfirmationPresented = true
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!model.canConfirm)
            .accessibilityIdentifier("delete-review-confirm")
            .accessibilitySortPriority(-1)
            .padding()
            .background(.bar)
        }
        .alert(
            "确认将这些照片移到“最近删除”吗？",
            isPresented: $isConfirmationPresented,
        ) {
            Button("确认删除", role: .destructive) {
                Task {
                    if model.retryTransactionID == nil {
                        await model.confirmDeletion()
                    } else {
                        await model.retryDeletion()
                    }
                }
            }
            .accessibilityIdentifier("delete-review-confirm-final")
            Button("取消", role: .cancel) {
                Task {
                    model.cancelConfirmation()
                    await model.refreshSubmissionSignal()
                }
            }
        } message: {
            Text("系统仍会在真实模式下要求最终确认。")
        }
        .task {
            if case .loading = model.loadState {
                await model.load()
            }
            await model.refreshSubmissionSignal()
        }
    }

    @ViewBuilder
    private var summarySection: some View {
        Section("删除摘要") {
            LabeledContent("待删除") {
                Text("\(model.selectedCandidateIDs.count) 项")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("待删除")
            .accessibilityIdentifier("delete-review-candidate-count")
            .accessibilityValue("\(model.selectedCandidateIDs.count) 项")
            LabeledContent("预计可释放") {
                Text(ByteCountFormatter.string(
                    fromByteCount: model.estimatedReclaimableBytes,
                    countStyle: .file
                ))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("预计可释放")
            .accessibilityIdentifier("delete-review-estimated-bytes")
            .accessibilityValue(formattedDeleteReviewBytes(model.estimatedReclaimableBytes))
            if model.protectedExclusionCount > 0 {
                Label("已排除 \(model.protectedExclusionCount) 项手动保护照片", systemImage: "lock.shield")
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("delete-review-protected-exclusion")
            }
        }
    }

    private var isLoadFailure: Bool {
        if case .failed = model.loadState { return true }
        return false
    }

    private func candidateRow(_ candidate: DeleteReviewCandidate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(candidate.sourceTask.title)
                    .font(.headline)
                Spacer()
                Button(role: .destructive) {
                    model.removeCandidate(id: candidate.id)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .accessibilityLabel("从删除复核中移除此候选")
                .accessibilityHint("移除后不会提交删除，决定仍可恢复")
                .accessibilityIdentifier("delete-review-remove-\(candidate.id)")
            }
            Text(candidate.sourceTask.reason)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(ByteCountFormatter.string(fromByteCount: candidate.estimatedBytes, countStyle: .file))
                if candidate.descriptor.isFavorite {
                    Label("收藏", systemImage: "star.fill")
                        .foregroundStyle(.yellow)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("已收藏")
                        .accessibilityIdentifier("delete-review-favorite-\(candidate.id)")
                }
                if candidate.descriptor.isEdited {
                    Label("已编辑", systemImage: "slider.horizontal.3")
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("delete-review-edited-\(candidate.id)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(candidateAccessibilityLabel(candidate))
        .accessibilityValue("已包含在本次删除")
        .accessibilityIdentifier("delete-review-candidate-\(candidate.id)")
    }

    private func candidateAccessibilityLabel(_ candidate: DeleteReviewCandidate) -> String {
        var parts = [
            "删除候选",
            "来自\(candidate.sourceTask.title)",
            "预计大小 \(formattedDeleteReviewBytes(candidate.estimatedBytes))"
        ]
        if candidate.descriptor.isFavorite { parts.append("已收藏") }
        if candidate.descriptor.isEdited { parts.append("已编辑") }
        return parts.joined(separator: "，")
    }
}

private func formattedDeleteReviewBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
