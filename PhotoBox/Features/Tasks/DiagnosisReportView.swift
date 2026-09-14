import SwiftUI

struct DiagnosisReportView: View {
    @Bindable var model: AppModel

    private var summary: DiagnosisSummary {
        DiagnosisSummary(
            tasks: model.cleanupTasks,
            currentPhotoStorageBytes: model.currentPhotoStorageBytes
        )
    }

    private var rankedTasks: [CleanupTask] {
        TaskRanker().rank(model.cleanupTasks.filter(\.isQualifyingCleanupCandidate))
    }

    var body: some View {
        List {
            Section("存储概览") {
                Text("当前照片存储：\(currentStorageText)")
                    .accessibilityIdentifier("diagnosis-current-storage")
                    .accessibilityLabel("当前照片存储")
                    .accessibilityValue(currentStorageText)
                Text("预计可释放空间：\(formattedBytes(summary.estimatedReclaimableBytes))")
                    .accessibilityIdentifier("diagnosis-estimated-reclaimable")
                    .accessibilityLabel("预计可释放空间")
                    .accessibilityValue(formattedBytes(summary.estimatedReclaimableBytes))
                Text("预计可释放空间是估算值，不保证实际释放的容量。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("待整理项目") {
                if rankedTasks.isEmpty {
                    Text("当前没有符合条件的整理任务。建议稍后重新扫描。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rankedTasks) { task in
                        DiagnosisTaskRow(task: task)
                    }
                }
            }

            Section("空间回收") {
                Text("删除项目会先移到“最近删除”。从“最近删除”中移除后，iOS 才会永久回收空间。")
                    .accessibilityIdentifier("diagnosis-recently-deleted-guidance")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("诊断报告")
        .task { await model.refreshSettingsSignals() }
    }

    private var currentStorageText: String {
        guard let bytes = summary.currentPhotoStorageBytes else { return "未知" }
        return formattedBytes(bytes)
    }
}

private struct DiagnosisTaskRow: View {
    let task: CleanupTask

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(task.title)
                .font(.headline)
                .accessibilityIdentifier("diagnosis-report-task-\(task.id)")
                .accessibilityLabel(task.title)
                .accessibilityValue("\(task.assetIDs.count) 项，约 \(task.estimatedMinutes) 分钟，\(riskText)，\(spaceText)，\(task.reason)")
            Text(task.reason)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("\(task.assetIDs.count) 项 · 约 \(task.estimatedMinutes) 分钟 · \(riskText) · \(spaceText)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 2)
    }

    private var riskText: String {
        switch task.risk {
        case .low: "低风险"
        case .medium: "中等风险"
        case .high: "高风险"
        }
    }

    private var spaceText: String {
        if task.type == .largeVideos {
            "占用 \(formattedBytes(task.estimatedBytes))，仅作空间诊断"
        } else {
            "预计可释放 \(formattedBytes(task.estimatedBytes))"
        }
    }
}

private func formattedBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
