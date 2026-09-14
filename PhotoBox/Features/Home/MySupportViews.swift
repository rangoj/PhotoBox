import SwiftUI

struct MyHistoryView: View {
    @Bindable var model: MyHomeModel

    var body: some View {
        Group {
            if let error = model.errorMessage {
                ContentUnavailableView {
                    Label("无法读取记录", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("重试") { Task { await model.load() } }.frame(minHeight: 44)
                        .accessibilityIdentifier("my-history-retry")
                }
            } else if let projection = model.projection {
                if projection.history.isEmpty {
                    ContentUnavailableView("暂无整理记录", systemImage: "clock.arrow.circlepath")
                        .accessibilityIdentifier("my-history-empty")
                } else {
                    List {
                        ForEach(projection.days()) { day in
                            Section(day.date.formatted(date: .abbreviated, time: .omitted)) {
                                ForEach(day.entries) { entry in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(entry.title).font(.body.weight(.medium))
                                        Text(entry.detail).font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 6)
                                    .accessibilityElement(children: .combine)
                                    .accessibilityIdentifier("my-history-\(entry.id)")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .refreshable { await model.load() }
                }
            } else {
                ProgressView("正在读取整理记录")
            }
        }
        .navigationTitle("整理记录")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("my-history-content")
        .task { await model.load() }
    }
}

struct MyHelpView: View {
    var body: some View {
        List {
            Section("照片删除") {
                Text("待删除照片需要经过删除复核。系统删除成功后，可在系统照片的“最近删除”中查看可恢复的照片。")
            }
            Section("整理记录") {
                Text("整理记录保存在此设备。清除本地记录后，累计数字也会重置。")
            }
            Section("照片访问") {
                Text("仅可访问你已授权的照片。访问范围可在设置中管理。")
            }
        }
        .navigationTitle("帮助")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MyFeedbackView: View {
    @Binding var draft: String

    var body: some View {
        Form {
            Section("反馈内容") {
                TextEditor(text: $draft)
                    .frame(minHeight: 180)
                    .accessibilityLabel("反馈内容")
                    .accessibilityIdentifier("my-feedback-draft")
            }
            Section {
                ShareLink(item: draft.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    Label("分享反馈", systemImage: "square.and.arrow.up")
                        .frame(minHeight: 44)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("my-feedback-share")
            }
        }
        .navigationTitle("反馈")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MyAboutView: View {
    var body: some View {
        List {
            Section {
                Text("PhotoBox").font(.title2.bold())
                LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "--")
                LabeledContent("构建", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "--")
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}
