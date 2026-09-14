import SwiftUI

struct StatisticsView: View {
    @Bindable var model: AppModel
    @State private var isShowingClearConfirmation = false
    @State private var isConfirmingClear = false

    var body: some View {
        let statistics = model.statistics

        List {
            switch statistics.state {
            case .loading:
                Section {
                    ProgressView("正在读取本地整理记录")
                        .accessibilityIdentifier("statistics-loading")
                }
            case .noHistory:
                Section {
                    ContentUnavailableView(
                        "还没有本地整理记录",
                        systemImage: "chart.bar.xaxis",
                        description: Text("完成整理后，这里会显示本机的整理进度。")
                    )
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("statistics-no-history")
                    .accessibilityLabel("还没有本地整理记录")
                    .accessibilityValue("完成整理后，这里会显示本机的整理进度")
                }
            case .partial:
                if let projection = statistics.projection {
                    metrics(projection)
                    Section {
                        Label("部分历史记录缺失，以下统计仅反映仍可读取的本地记录。", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("statistics-partial")
                }
            case .ready:
                if let projection = statistics.projection {
                    metrics(projection)
                }
            case .failure(let message):
                if let projection = statistics.projection {
                    metrics(projection)
                }
                Section {
                    ContentUnavailableView(
                        "无法读取统计",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("statistics-read-failure")
                    .accessibilityLabel("无法读取统计")
                    .accessibilityValue(message)
                    Button("重试") {
                        Task { await statistics.load() }
                    }
                    .accessibilityIdentifier("statistics-retry")
                }
            }

            if let clearFailureMessage = statistics.clearFailureMessage {
                Section {
                    Label(clearFailureMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("statistics-clear-failure")
                    Button("重试清除本机整理历史") {
                        Task { _ = await model.clearStatisticsHistory() }
                    }
                    .accessibilityIdentifier("statistics-clear-retry")
                    Button("保留历史并返回统计") {
                        model.dismissStatisticsClearFailure()
                    }
                    .accessibilityIdentifier("statistics-clear-return")
                }
            }

            if let clearCallCount = model.statisticsClearCallCount {
                LabeledContent("清除调用", value: clearCallCount.formatted())
                    .accessibilityIdentifier("statistics-clear-call-count")
                    .accessibilityValue(clearCallCount.formatted())
            }

            Section("扫描") {
                Button {
                    model.rescan()
                } label: {
                    Label("完整重新扫描", systemImage: "arrow.clockwise")
                }
                .disabled(model.scan.isScanning || statistics.isClearingHistory || model.isClearingStatisticsHistory)
                .accessibilityIdentifier("statistics-full-rescan")
                .accessibilityValue(scanPhaseAccessibilityValue)

                if model.scan.isScanning {
                    Label("正在重新扫描，现有整理历史会保留。", systemImage: "hourglass")
                        .foregroundStyle(.secondary)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("statistics-rescan-progress")
                } else if model.scan.phase == .cancelled {
                    Label("重新扫描已取消，现有整理历史会保留。", systemImage: "pause.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("statistics-rescan-cancelled")
                    Button("继续重新扫描") {
                        model.resumeScan()
                    }
                    .accessibilityIdentifier("statistics-rescan-resume")
                } else if model.scan.phase == .failed {
                    Label("重新扫描未完成，现有整理历史会保留。", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("statistics-rescan-failed")
                    Button("重试完整重新扫描") {
                        model.restartScan()
                    }
                    .accessibilityIdentifier("statistics-rescan-retry")
                }
            }

            Section {
                Button(role: .destructive) {
                    isShowingClearConfirmation = true
                } label: {
                    Label("清除本机整理历史", systemImage: "trash")
                }
                .disabled(statistics.isClearingHistory || model.isClearingStatisticsHistory)
                .accessibilityIdentifier("statistics-clear-history")
            } header: {
                Text("本机数据")
            } footer: {
                Text("只会清除 PhotoBox 保存在本机的整理记录，不会删除照片或修改系统相册。")
            }

        }
        .accessibilityIdentifier(statisticsListIdentifier)
        .navigationTitle("统计")
        .confirmationDialog(
            "清除本机整理历史？",
            isPresented: $isShowingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清除本机整理历史", role: .destructive) {
                isConfirmingClear = true
                Task {
                    _ = await model.clearStatisticsHistory()
                    isConfirmingClear = false
                }
            }
            .accessibilityIdentifier("statistics-clear-confirm")
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会移除本机的扫描、任务、决定和整理汇总；照片和系统相册不会改变。")
        }
        .onChange(of: isShowingClearConfirmation) { wasShowing, isShowing in
            guard wasShowing, !isShowing, !isConfirmingClear else { return }
            Task { await model.refreshStatisticsInventoryFingerprint() }
        }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-statistics-loading") {
                try? await Task.sleep(for: .seconds(60))
                return
            }
            #endif
            await statistics.load()
            await model.refreshStatisticsInventoryFingerprint()
            model.refreshStatisticsClearCallCount()
        }
    }

    private var statisticsListIdentifier: String {
        guard model.hasStatisticsInventorySignal else { return "statistics-list" }
        guard let fingerprint = model.statisticsInventoryFingerprint else {
            return "statistics-inventory-fingerprint:pending"
        }
        return "statistics-inventory-fingerprint:\(fingerprint)"
    }

    private var scanPhaseAccessibilityValue: String {
        switch model.scan.phase {
        case .idle: "尚未扫描"
        case .discovering: "正在读取相册"
        case .checkingLocalAvailability: "正在检查本地照片"
        case .cancelled: "扫描已取消"
        case .completed: "扫描已完成"
        case .failed: "扫描失败"
        }
    }

    @ViewBuilder
    private func metrics(_ projection: StatisticsProjection) -> some View {
        Section("整理概览") {
            LabeledContent("新增可整理项目", value: projection.newItemCount.formatted())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("新增可整理项目")
                .accessibilityIdentifier("statistics-new-items")
                .accessibilityValue(projection.newItemCount.formatted())
            LabeledContent("已处理项目", value: projection.processedItemCount.formatted())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("已处理项目")
                .accessibilityIdentifier("statistics-processed-items")
                .accessibilityValue(projection.processedItemCount.formatted())
            LabeledContent("成功归档", value: projection.successfulArchiveCount.formatted())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("成功归档")
                .accessibilityIdentifier("statistics-archives")
                .accessibilityValue(projection.successfulArchiveCount.formatted())
            LabeledContent("已保护", value: projection.protectionCount.formatted())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("已保护")
                .accessibilityIdentifier("statistics-protections")
                .accessibilityValue(projection.protectionCount.formatted())
            LabeledContent("稍后决定", value: projection.deferralCount.formatted())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("稍后决定")
                .accessibilityIdentifier("statistics-deferrals")
                .accessibilityValue(projection.deferralCount.formatted())
        }

        Section("删除复核") {
            LabeledContent("已送入最近删除", value: projection.reviewedDeletionCount.formatted())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("已送入最近删除")
                .accessibilityIdentifier("statistics-reviewed-deletions")
                .accessibilityValue(projection.reviewedDeletionCount.formatted())
            LabeledContent("预计可回收空间", value: formattedStatisticsBytes(projection.estimatedReclaimableBytes))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("预计可回收空间")
                .accessibilityIdentifier("statistics-estimated-space")
                .accessibilityValue(formattedStatisticsBytes(projection.estimatedReclaimableBytes))
            if projection.hasRecentlyDeletedEstimate || projection.hasEstimatedReclaimableSpace {
                Label("空间与最近删除状态均为估算，不代表永久释放。", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("statistics-estimated-wording")
            }
        }

        Section("任务趋势") {
            LabeledContent("已完成任务", value: "\(projection.completedTaskCount) / \(projection.totalTaskCount)")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("已完成任务")
                .accessibilityIdentifier("statistics-task-trend")
                .accessibilityValue("\(projection.completedTaskCount) / \(projection.totalTaskCount)")
            if projection.hasEstimatedAvailability {
                Label("iCloud 中的项目可能尚未完整计入扫描结果。", systemImage: "icloud")
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("statistics-icloud-estimate")
            }
        }
    }
}

private func formattedStatisticsBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
