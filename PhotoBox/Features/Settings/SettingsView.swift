import Photos
import PhotosUI
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("每周整理") {
                Toggle("每周整理提醒", isOn: reminderEnabledBinding)
                    .disabled(!model.weeklyModeEnabled)
                    .accessibilityIdentifier("settings.reminderEnabled")
                    .accessibilityLabel("每周整理提醒")

                if !model.weeklyModeEnabled {
                    Text("完成一次有实际决定的整理后，才可开启每周提醒。")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.reminderLockedReason")
                }

                Picker("提醒日期", selection: reminderWeekdayBinding) {
                    Text("星期日").tag(1)
                    Text("星期一").tag(2)
                    Text("星期二").tag(3)
                    Text("星期三").tag(4)
                    Text("星期四").tag(5)
                    Text("星期五").tag(6)
                    Text("星期六").tag(7)
                }
                .disabled(!model.reminderEnabled)
                .accessibilityIdentifier("settings.reminderWeekday")
                .accessibilityValue(reminderWeekdayTitle)

                LabeledContent("通知权限", value: notificationAuthorizationTitle)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("通知权限")
                    .accessibilityIdentifier("settings.reminderAuthorization")
                    .accessibilityValue(notificationAuthorizationTitle)

                if let guidance = model.reminderGuidance {
                    Text(guidance)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.reminderGuidance")
                }

                if model.canRetryReminderSynchronization {
                    Button("重试同步提醒") {
                        Task {
                            await model.retryReminderSynchronization()
                            await model.refreshSettingsSignals()
                        }
                    }
                    .accessibilityIdentifier("settings.retryReminderSynchronization")
                }

                if [.denied, .restricted, .provisional, .ephemeral]
                    .contains(model.notificationAuthorization) {
                    Button("打开系统通知设置") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                    .accessibilityIdentifier("settings.openNotificationSettings")
                }
            }

            Section("截图任务") {
                Picker("提醒处理", selection: screenshotAgeBinding) {
                    Text("7 天").tag(7)
                    Text("30 天").tag(30)
                    Text("90 天").tag(90)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.screenshotThreshold")
                .accessibilityLabel("提醒处理")
                .accessibilityValue("\(model.screenshotAgeDays) 天")

                if let message = model.screenshotPersistenceErrorMessage {
                    Text(message)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.screenshotPersistenceError")
                }
            }

            Section("照片访问") {
                LabeledContent("当前范围", value: authorizationTitle)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("当前范围")
                    .accessibilityIdentifier("settings.photoAuthorization")
                    .accessibilityValue(authorizationTitle)
                if model.authorization == .limited {
                    Button("管理可访问照片") {
                        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                              let controller = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
                        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller) { _ in
                            Task { @MainActor in model.rescan() }
                        }
                    }
                    .accessibilityHint("打开系统照片选择器以更改 PhotoBox 可访问的照片")
                }
            }

            Section("隐私") {
                Label("所有分析均在设备端完成", systemImage: "lock.shield")
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("settings.privacyLocalOnly")
                Label("不会自动下载 iCloud 原图", systemImage: "icloud.slash")
                Label("不会自动删除照片", systemImage: "trash.slash")
                Label("提醒仅包含通用整理文字，不含照片内容", systemImage: "bell.badge")
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("settings.privacyGenericReminder")
            }

                #if DEBUG
            Section("开发者") {
                Toggle("允许真实照片变更", isOn: debugMutationBinding)
                    .accessibilityIdentifier("settings.debugRealMutation")
                    .accessibilityLabel("允许真实照片变更")
                LabeledContent("照片变更模式") {
                    Text(model.mutationModeLabel)
                        .accessibilityIdentifier("settings.mutationMode")
                }
            }
            #endif

            #if DEBUG
            if let recording = model.reminderRecording,
               let scanCount = model.settingsScanCount {
                Section("自动化记录") {
                    LabeledContent("授权请求") {
                        Text("\(recording.authorizationRequestCount)")
                            .accessibilityIdentifier("settings.recordedAuthorizationRequests")
                    }
                    LabeledContent("待处理提醒") {
                        Text("\(recording.scheduledRequests.count)")
                            .accessibilityIdentifier("settings.recordedReminderCount")
                    }
                    LabeledContent("最后提醒日期") {
                        Text(recording.scheduledWeekdays.last.map(String.init) ?? "-")
                            .accessibilityIdentifier("settings.recordedReminderWeekday")
                    }
                    LabeledContent("移除次数") {
                        Text("\(recording.removalCount)")
                            .accessibilityIdentifier("settings.recordedRemovalCount")
                    }
                    LabeledContent("扫描次数") {
                        Text("\(scanCount)")
                            .accessibilityIdentifier("settings.recordedScanCount")
                    }
                }
            }
            #endif

            Section {
                LabeledContent("版本", value: "0.1.0")
            }
        }
        .navigationTitle("设置")
        .task {
            await model.refreshMutationMode()
            await model.refreshReminderAuthorization()
            await model.refreshSettingsSignals()
        }
    }

    private var screenshotAgeBinding: Binding<Int> {
        Binding(
            get: { model.screenshotAgeDays },
            set: { days in
                model.updateScreenshotAge(days)
                Task {
                    try? await Task.sleep(for: .milliseconds(100))
                    await model.refreshSettingsSignals()
                }
            }
        )
    }

    private var reminderEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.reminderEnabled },
            set: { enabled in
                Task {
                    await model.updateReminderEnabled(enabled)
                    await model.refreshSettingsSignals()
                }
            }
        )
    }

    private var reminderWeekdayBinding: Binding<Int> {
        Binding(
            get: { model.reminderWeekday },
            set: { weekday in
                Task {
                    await model.updateReminderWeekday(weekday)
                    await model.refreshSettingsSignals()
                }
            }
        )
    }

        #if DEBUG
    private var debugMutationBinding: Binding<Bool> {
        Binding(
            get: { model.debugRealMutationEnabled },
            set: { model.updateDebugRealMutation($0) }
        )
    }
    #endif

    private var authorizationTitle: String {
        switch model.authorization {
        case .authorized: "全部照片"
        case .limited: "部分照片"
        case .denied: "未允许"
        case .restricted: "受限制"
        case .notDetermined: "未选择"
        }
    }

    private var notificationAuthorizationTitle: String {
        switch model.notificationAuthorization {
        case .notDetermined: "尚未请求"
        case .denied: "未允许"
        case .restricted: "受限制"
        case .authorized: "已允许"
        case .provisional: "临时允许（提醒未启用）"
        case .ephemeral: "临时会话（提醒未启用）"
        }
    }

    private var reminderWeekdayTitle: String {
        switch model.reminderWeekday {
        case 1: "星期日"
        case 2: "星期一"
        case 3: "星期二"
        case 4: "星期三"
        case 5: "星期四"
        case 6: "星期五"
        case 7: "星期六"
        default: "未知日期"
        }
    }
}
