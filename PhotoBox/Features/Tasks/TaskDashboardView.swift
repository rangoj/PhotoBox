import Photos
import PhotosUI
import SwiftUI

struct TaskDashboardView: View {
    @Bindable var model: AppModel

    var body: some View {
        List {
            if let persistenceErrorMessage = model.persistenceErrorMessage {
                Section {
                    Text(persistenceErrorMessage)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("tasks-persistence-warning")
                }
            }

            if model.authorization == .limited {
                Section {
                    LimitedAccessBanner {
                        model.rescan()
                    }
                }
            }

            Section {
                scanOverview
                diagnosisSummary
            }

            Section {
                if let firstTask = rankedTasks.first {
                    NavigationLink(value: model.route(for: firstTask)) {
                        Label("开始首个任务", systemImage: "play.fill")
                    }
                    .accessibilityIdentifier("start-next-task")
                    .accessibilityLabel("开始首个任务")
                    .accessibilityValue(firstTask.title)
                }
                NavigationLink(value: AppRoute.diagnosis) {
                    Label("诊断报告", systemImage: "chart.pie")
                }
                .accessibilityIdentifier("diagnosis-report")
                .accessibilityLabel("查看诊断报告")
                if model.pendingDecisions.contains(where: { $0.kind == .deleteCandidate && !$0.isSubmitted }) {
                    NavigationLink(value: AppRoute.deleteReview) {
                        Label("删除复核", systemImage: "trash")
                    }
                    .accessibilityIdentifier("delete-review-route")
                }
            }

            Section {
                if !rankedTasks.isEmpty {
                    ForEach(rankedTasks) { task in
                        NavigationLink(value: model.route(for: task)) {
                            TaskInboxRow(task: task)
                        }
                        .accessibilityIdentifier("diagnosis-task-action-\(task.id)")
                        .accessibilityLabel(task.title)
                        .accessibilityValue(taskInboxAccessibilityValue(task))
                    }
                } else if isHealthyLibrary {
                    ContentUnavailableView {
                        Label {
                            Text("相册状态良好")
                        } icon: {
                            Image(systemName: "checkmark.circle")
                        }
                        .accessibilityRepresentation {
                            Text("相册状态良好")
                                .accessibilityIdentifier("scan-empty-state")
                        }
                    } description: {
                        Text("当前可访问范围内没有需要整理的照片或视频。")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                } else if model.scan.screenshotCount > 0 {
                    SmartTaskCard(
                        icon: "camera.viewfinder",
                        tint: .photoBoxWarm,
                        title: "处理过期截图",
                        detail: "超过 \(model.screenshotAgeDays) 天，可批量标记后统一复核",
                        count: model.scan.screenshotCount,
                        status: "低风险 · 约 2 分钟"
                    )
                } else if model.scan.phase == .completed {
                    ContentUnavailableView(
                        "没有过期截图",
                        systemImage: "checkmark.circle",
                        description: Text("当前可访问范围内没有超过 \(model.screenshotAgeDays) 天的截图")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                }
            } header: {
                Text("为你准备的任务")
            } footer: {
                Text(taskSummary)
            }

            if model.scan.largeVideoCount > 0 {
                Section {
                    SmartTaskCard(
                        icon: "video",
                        tint: .blue,
                        title: "查看长视频",
                        detail: "仅作空间诊断，不会自动压缩或删除",
                        count: model.scan.largeVideoCount,
                        status: "空间诊断"
                    )
                }
            }

            Section("空间诊断") {
                diagnosis
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("task-inbox-list")
        .navigationTitle("相册收件箱")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.rescan()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.scan.isScanning)
                .accessibilityLabel("重新扫描")
            }
        }
    }

    private var scanOverview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(scanTitle)
                        .font(.title3.bold())
                        .accessibilityLabel("扫描状态")
                        .accessibilityIdentifier("scan-status")
                        .accessibilityValue("\(authorizationScope)，\(scanTitle)")
                    Text(scanDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: model.scan.isScanning ? "sparkle.magnifyingglass" : "checkmark.shield")
                    .font(.title2)
                    .foregroundStyle(model.scan.isScanning ? Color.photoBoxWarm : Color.photoBoxAccent)
            }

            if model.scan.isScanning {
                ProgressView(value: model.scan.progress)
                    .tint(.photoBoxAccent)
                    .accessibilityLabel("扫描进度")
                    .accessibilityIdentifier("scan-progress")
                    .accessibilityValue(scanProgressAccessibilityValue)
                Text("已发现 \(model.scan.discoveredCount) 项，已处理 \(model.scan.processedCount) 项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("取消扫描", action: model.cancelScan)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("scan-cancel")
                    .accessibilityHint("保留已完成的安全进度")
            } else if model.scan.phase == .cancelled {
                HStack {
                    Button("继续扫描", action: model.resumeScan)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("scan-resume")
                        .accessibilityHint("从已保存的安全进度继续")
                    Button("重新开始", action: model.restartScan)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("scan-restart")
                        .accessibilityHint("放弃暂停进度并重新扫描")
                }
            } else if model.scan.phase == .failed {
                Button("重试扫描", action: model.restartScan)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("scan-retry")
                    .accessibilityHint("重新扫描当前可访问范围")
            }
        }
    }

    private var diagnosis: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 0) {
                DiagnosisMetric(value: model.scan.localCount, label: "本地可分析")
                Divider().frame(height: 42)
                DiagnosisMetric(value: model.scan.iCloudOnlyCount, label: "iCloud 跳过")
                Divider().frame(height: 42)
                DiagnosisMetric(value: model.scan.unavailableCount, label: "不可读取")
            }
            Text("PhotoBox 不会为扫描自动下载 iCloud 原图。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var diagnosisSummary: some View {
        let summary = DiagnosisSummary(
            tasks: model.cleanupTasks,
            currentPhotoStorageBytes: model.currentPhotoStorageBytes
        )
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("待整理 \(summary.uniqueAssetCount) 项", systemImage: "checklist")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("待整理项目")
                    .accessibilityValue("\(summary.uniqueAssetCount) 项")
                    .accessibilityIdentifier("task-summary-count")
                Spacer(minLength: 12)
                Text("预计 \(formattedBytes(summary.estimatedReclaimableBytes))")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("task-summary-reclaimable")
            }
            Text("按低风险和高置信度优先安排。空间数值为预计值。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let firstTask = rankedTasks.first {
                Text("下一项：\(firstTask.title) · 约 \(firstTask.estimatedMinutes) 分钟")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }
        }
    }

    private var scanTitle: String {
        switch model.scan.phase {
        case .idle: "准备扫描"
        case .discovering: "正在读取相册"
        case .checkingLocalAvailability: "正在检查本地照片"
        case .cancelled: "扫描已暂停"
        case .completed: "相册诊断已更新"
        case .failed: "无法扫描当前可访问范围"
        }
    }

    private var scanDetail: String {
        if let message = model.scan.errorMessage { return message }
        if model.scan.isScanning {
            return "已检查 \(model.scan.processedCount) / \(model.scan.discoveredCount) 项"
        }
        if model.scan.phase == .cancelled {
            return "已保存当前进度，可继续扫描或重新开始"
        }
        return "已分析 \(model.scan.localCount) 项本地照片和视频"
    }

    private var authorizationScope: String {
        model.authorization == .limited ? "部分照片" : "全部照片"
    }

    private var scanProgressAccessibilityValue: String {
        let percent = model.scan.progress.formatted(.percent.precision(.fractionLength(0)))
        return "\(percent)，已处理 \(model.scan.processedCount) 项，共 \(model.scan.discoveredCount) 项"
    }

    private var taskSummary: String {
        model.scan.isScanning ? "扫描中" : "按信任优先排序"
    }

    private var rankedTasks: [CleanupTask] {
        TaskRanker().rank(model.cleanupTasks.filter(\.isQualifyingCleanupCandidate))
    }

    private var isHealthyLibrary: Bool {
        model.scan.phase == .completed
            && rankedTasks.isEmpty
            && model.scan.screenshotCount == 0
            && model.scan.largeVideoCount == 0
    }
}

private struct TaskInboxRow: View {
    let task: CleanupTask

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(riskColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.headline)
                    .accessibilityIdentifier("diagnosis-task-\(task.id)")
                    .accessibilityLabel(task.title)
                    .accessibilityValue(taskInboxAccessibilityValue(task))
                Text(task.reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("\(task.assetIDs.count) 项 · \(timeText) · \(riskText) · \(spaceText)")
                    .font(.caption)
                    .foregroundStyle(riskColor)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch task.type {
        case .screenshots: "camera.viewfinder"
        case .duplicates, .similar, .bursts: "photo.on.rectangle"
        case .largeVideos: "video"
        case .weekly, .dateBatch: "calendar"
        }
    }

    private var timeText: String { "约 \(task.estimatedMinutes) 分钟" }

    private var riskText: String {
        switch task.risk {
        case .low: "低风险"
        case .medium: "中等风险"
        case .high: "高风险"
        }
    }

    private var riskColor: Color {
        switch task.risk {
        case .low: .green
        case .medium: .orange
        case .high: .red
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

private func taskInboxAccessibilityValue(_ task: CleanupTask) -> String {
    let risk = switch task.risk {
    case .low: "低风险"
    case .medium: "中等风险"
    case .high: "高风险"
    }
    let space = task.type == .largeVideos
        ? "占用 \(formattedBytes(task.estimatedBytes))，仅作空间诊断"
        : "预计可释放 \(formattedBytes(task.estimatedBytes))"
    return "\(task.assetIDs.count) 项，约 \(task.estimatedMinutes) 分钟，\(risk)，\(space)，\(task.reason)"
}

private struct SmartTaskCard: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String
    let count: Int
    let status: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(tint)
            }

            Spacer(minLength: 8)

            Text(count, format: .number)
                .font(.title2.bold())
                .foregroundStyle(.primary)
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary, lineWidth: 1)
        }
        .accessibilityLabel("\(title)，\(count) 项，\(status)")
    }
}

private struct DiagnosisMetric: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(spacing: 3) {
            Text(value, format: .number)
                .font(.headline)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value.formatted())
    }
}

private struct LimitedAccessBanner: View {
    let rescan: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "photo.badge.exclamationmark")
                .foregroundStyle(Color.photoBoxWarm)
            VStack(alignment: .leading, spacing: 2) {
                Text("正在整理已允许的照片")
                    .font(.subheadline.bold())
                Text("扫描结果仅包含当前可访问范围")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("管理") {
                guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                      let controller = scene.keyWindow?.rootViewController else { return }
                PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller) { _ in
                    Task { @MainActor in rescan() }
                }
            }
            .font(.subheadline.bold())
            .accessibilityIdentifier("permission-manage-limited")
            .accessibilityHint("打开系统照片选择器以更改 PhotoBox 可访问的照片")
        }
        .padding(12)
        .background(Color.photoBoxWarm.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("permission-limited-state")
        .accessibilityLabel("照片访问范围")
        .accessibilityValue("部分照片，仅整理已允许的照片")
    }
}

private extension UIWindowScene {
    var keyWindow: UIWindow? {
        windows.first(where: \.isKeyWindow)
    }
}
