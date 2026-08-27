import Photos
import PhotosUI
import SwiftUI

struct TaskDashboardView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if model.authorization == .limited {
                    LimitedAccessBanner {
                        model.rescan()
                    }
                }

                scanOverview

                SectionHeader("为你准备的任务", detail: taskSummary)

                if model.scan.screenshotCount > 0 {
                    SmartTaskCard(
                        icon: "camera.viewfinder",
                        tint: .photoBoxWarm,
                        title: "处理过期截图",
                        detail: "超过 \(model.screenshotAgeDays) 天，逐张确认后再删除",
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

                if model.scan.largeVideoCount > 0 {
                    SmartTaskCard(
                        icon: "video",
                        tint: .blue,
                        title: "查看长视频",
                        detail: "仅作空间诊断，不会自动压缩或删除",
                        count: model.scan.largeVideoCount,
                        status: "空间诊断"
                    )
                }

                diagnosis
            }
            .padding(16)
        }
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
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var diagnosis: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader("空间诊断")
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

    private var scanTitle: String {
        switch model.scan.phase {
        case .idle: "准备扫描"
        case .discovering: "正在读取相册"
        case .checkingLocalAvailability: "正在检查本地照片"
        case .completed: "相册诊断已更新"
        case .failed: "扫描暂停"
        }
    }

    private var scanDetail: String {
        if let message = model.scan.errorMessage { return message }
        if model.scan.isScanning {
            return "已检查 \(model.scan.processedCount) / \(model.scan.discoveredCount) 项"
        }
        return "已分析 \(model.scan.localCount) 项本地照片和视频"
    }

    private var taskSummary: String {
        model.scan.isScanning ? "扫描中" : "按信任优先排序"
    }
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
        }
        .padding(12)
        .background(Color.photoBoxWarm.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

private extension UIWindowScene {
    var keyWindow: UIWindow? {
        windows.first(where: \.isKeyWindow)
    }
}
