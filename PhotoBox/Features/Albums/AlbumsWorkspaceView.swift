import SwiftUI

struct AlbumsWorkspaceView: View {
    @Bindable var model: AppModel

    var body: some View {
        List {
            Section("整理队列") {
                WorkspaceRow(icon: "tray", tint: .blue, title: "未整理", count: 0)
                WorkspaceRow(icon: "bookmark", tint: .photoBoxWarm, title: "稍后决定", count: 0)
                WorkspaceRow(icon: "shield.checkered", tint: .photoBoxAccent, title: "已保护", count: 0)
            }

            Section("系统相册") {
                WorkspaceRow(
                    icon: "rectangle.stack",
                    tint: .purple,
                    title: "常用相册",
                    count: model.scan.userAlbumCount
                )
            }
        }
        .navigationTitle("相册")
    }
}

private struct WorkspaceRow: View {
    let icon: String
    let tint: Color
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 28)
            Text(title)
            Spacer()
            Text(count, format: .number)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
