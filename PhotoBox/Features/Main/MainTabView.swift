import Photos
import SwiftUI

struct MainTabView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            NavigationStack {
                TaskDashboardView(model: model)
            }
            .tabItem { Label("任务", systemImage: "tray.full") }

            NavigationStack {
                AlbumsWorkspaceView(model: model)
            }
            .tabItem { Label("相册", systemImage: "rectangle.stack") }

            NavigationStack {
                SettingsView(model: model)
            }
            .tabItem { Label("设置", systemImage: "gearshape") }
        }
    }
}
