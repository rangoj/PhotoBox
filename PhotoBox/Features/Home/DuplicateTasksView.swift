import SwiftUI

struct DuplicateTasksView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if tasks.isEmpty {
                    ContentUnavailableView(
                        "没有重复照片任务",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("完成照片扫描后，重复和相似照片任务会显示在这里。")
                    )
                    .foregroundStyle(DuplicatePalette.text)
                    .padding(.top, 80)
                    .accessibilityIdentifier("duplicates-empty")
                } else {
                    ForEach(tasks) { task in
                        Button {
                            model.openTask(task)
                        } label: {
                            HStack(spacing: 14) {
                                HomeCollectionCover(
                                    assetIDs: Array(task.assetIDs.prefix(2)),
                                    loader: model.thumbnailLoader,
                                    style: .split,
                                    showsShuffleBadge: false
                                )

                                VStack(alignment: .leading, spacing: 5) {
                                    Text(task.title)
                                        .font(.headline)
                                        .foregroundStyle(DuplicatePalette.text)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(task.type == .duplicates ? "重复照片" : "相似照片")
                                        .font(.subheadline)
                                        .foregroundStyle(DuplicatePalette.secondary)
                                    Text(progressText(for: task))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(DuplicatePalette.accent)
                                }

                                Spacer(minLength: 8)
                                Image(systemName: "chevron.forward")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(DuplicatePalette.secondary)
                                    .accessibilityHidden(true)
                            }
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("duplicates-task-\(task.id)")
                        .accessibilityLabel(task.title)
                        .accessibilityValue(progressText(for: task))

                        Divider()
                            .overlay(DuplicatePalette.secondary.opacity(0.25))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(DuplicatePalette.background.ignoresSafeArea())
        .navigationTitle("重复项")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("duplicates-list")
    }

    private var tasks: [CleanupTask] {
        TaskRanker().rank(model.cleanupTasks.filter {
            ($0.type == .duplicates || $0.type == .similar) && $0.isQualifyingCleanupCandidate
        })
    }

    private func progressText(for task: CleanupTask) -> String {
        let completed = min(task.currentAssetIndex, task.assetIDs.count)
        if completed > 0 { return "已处理 \(completed) / \(task.assetIDs.count) 张" }
        return "\(task.assetIDs.count) 张照片"
    }
}

private enum DuplicatePalette {
    static let background = Color(red: 18 / 255, green: 19 / 255, blue: 22 / 255)
    static let text = Color(red: 227 / 255, green: 226 / 255, blue: 230 / 255)
    static let secondary = Color(red: 139 / 255, green: 145 / 255, blue: 160 / 255)
    static let accent = Color(red: 170 / 255, green: 199 / 255, blue: 255 / 255)
}
