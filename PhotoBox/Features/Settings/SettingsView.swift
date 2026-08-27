import Photos
import PhotosUI
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("截图任务") {
                Picker("提醒处理", selection: screenshotAgeBinding) {
                    Text("7 天").tag(7)
                    Text("30 天").tag(30)
                    Text("90 天").tag(90)
                }
                .pickerStyle(.segmented)
            }

            Section("照片访问") {
                LabeledContent("当前范围", value: authorizationTitle)
                if model.authorization == .limited {
                    Button("管理可访问照片") {
                        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                              let controller = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
                        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller) { _ in
                            Task { @MainActor in model.rescan() }
                        }
                    }
                }
            }

            Section("隐私") {
                Label("所有分析均在设备端完成", systemImage: "lock.shield")
                Label("不会自动下载 iCloud 原图", systemImage: "icloud.slash")
                Label("不会自动删除照片", systemImage: "trash.slash")
            }

            Section {
                LabeledContent("版本", value: "0.1.0")
            }
        }
        .navigationTitle("设置")
    }

    private var screenshotAgeBinding: Binding<Int> {
        Binding(
            get: { model.screenshotAgeDays },
            set: { model.updateScreenshotAge($0) }
        )
    }

    private var authorizationTitle: String {
        switch model.authorization {
        case .authorized: "全部照片"
        case .limited: "部分照片"
        case .denied: "未允许"
        case .restricted: "受限制"
        case .notDetermined: "未选择"
        }
    }
}
