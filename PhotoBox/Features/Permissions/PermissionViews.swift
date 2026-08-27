import SwiftUI

struct PermissionEducationView: View {
    let requestAccess: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 52, weight: .medium))
                .foregroundStyle(Color.photoBoxAccent)
                .accessibilityHidden(true)

            VStack(spacing: 10) {
                Text("整理从了解相册开始")
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                Text("照片只在这台 iPhone 上分析。PhotoBox 不会上传原图，也不会自动删除任何内容。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 16) {
                PermissionBenefit(icon: "lock.shield", title: "设备端处理", detail: "照片和分析结果不离开设备")
                PermissionBenefit(icon: "checkmark.circle", title: "删除前复核", detail: "每一项都由你确认后再交给系统")
                PermissionBenefit(icon: "icloud.slash", title: "不自动下载", detail: "仅在 iCloud 的照片会被跳过")
            }
            .padding(.vertical, 8)

            Spacer()

            Button(action: requestAccess) {
                Label("允许访问照片", systemImage: "photo.badge.checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(24)
    }
}

private struct PermissionBenefit: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.photoBoxAccent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct PermissionRecoveryView: View {
    let isRestricted: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        ContentUnavailableView {
            Label("无法访问照片", systemImage: "photo.badge.exclamationmark")
        } description: {
            Text(isRestricted ? "此设备限制了照片访问。请检查屏幕使用时间或设备管理设置。" : "请在系统设置中允许 PhotoBox 访问照片。")
        } actions: {
            if !isRestricted {
                Button("打开系统设置") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    openURL(url)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
