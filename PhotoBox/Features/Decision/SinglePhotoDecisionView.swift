import SwiftUI

struct SinglePhotoDecisionScreen: View {
    @Bindable var model: SinglePhotoDecisionFlow
    let loader: BoundedThumbnailLoader
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var thumbnailState: MediaThumbnailState = .loading
    @State private var errorMessage: String?
    @State private var recordedMotionMode: PhotoBoxMotion.Mode?
    @State private var isShowingBatchDeleteConfirmation = false

    var body: some View {
        List {
            Section {
                Text(model.positionText)
                    .font(.subheadline.monospacedDigit())
                    .accessibilityIdentifier("decision-position")
                Text("待处理决定 \(model.pendingDecisionCount) 项")
                    .accessibilityIdentifier("decision-pending-count")
                    .accessibilityValue("\(model.pendingDecisionCount)")
                Text("预计可释放 \(ByteCountFormatter.string(fromByteCount: model.estimatedReclaimableBytes, countStyle: .file))")
                    .accessibilityIdentifier("decision-reclaimable-bytes")
                    .accessibilityValue("\(model.estimatedReclaimableBytes)")
            }

            if let descriptor = model.currentDescriptor {
                Section("当前照片") {
                    let page = MediaPage(descriptor: descriptor)
                    MediaViewport(page: page, state: thumbnailState)
                        .frame(height: 280)
                        .accessibilityIdentifier("decision-media-viewport")
                    MediaMetadataBadges(page: page)
                }

            } else {
                ContentUnavailableView("已完成整理", systemImage: "checkmark.circle")
                    .accessibilityIdentifier("decision-complete")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("decision-error")
                }
            }

            if dynamicTypeSize.isAccessibilitySize {
                Section("决定") {
                    decisionControls
                }
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            if !dynamicTypeSize.isAccessibilitySize {
                decisionControls
                    .padding(12)
                    .background(.bar)
            }
        }
        .navigationTitle("整理照片")
        .confirmationDialog(
            "批量标记剩余截图？",
            isPresented: $isShowingBatchDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("标记为删除候选", role: .destructive) {
                batchDeleteRemaining()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这些截图未收藏且未编辑，标记后仍会进入统一删除复核。")
        }
        .task(id: model.currentDescriptor?.id) {
            await loadCurrentThumbnail()
        }
        #if DEBUG
        .overlay(alignment: .topLeading) {
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-motion-probe"),
               let recordedMotionMode {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityIdentifier("motion-probe-decision")
                    .accessibilityValue(recordedMotionMode.rawValue)
            }
        }
        #endif
    }

    @ViewBuilder
    private var decisionControls: some View {
        if model.currentDescriptor != nil || model.canUndo {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 8),
                    count: dynamicTypeSize.isAccessibilitySize ? 1 : 3
                ),
                spacing: 8
            ) {
                if model.currentDescriptor != nil { Button { decide(.keep) } label: {
                    decisionControlLabel("保留")
                }
                    .accessibilityIdentifier("decision-keep")
                    .accessibilityHint("记录为已处理，不修改照片")
                Button(role: .destructive) { decide(.deleteCandidate) } label: {
                    decisionControlLabel("删除")
                }
                    .accessibilityIdentifier("decision-delete")
                    .accessibilityHint("标记为删除候选，提交前仍可撤销")
                Button {
                    PhotoBoxMotion.perform(reduceMotion: reduceMotion, recordMode: recordMotionMode) {
                        model.requestArchive()
                    }
                } label: {
                    decisionControlLabel("归档")
                }
                    .accessibilityIdentifier("decision-archive")
                    .accessibilityHint("选择要加入的系统相册")
                Button { decide(.protect) } label: {
                    decisionControlLabel("保护")
                }
                    .accessibilityIdentifier("decision-protect")
                    .accessibilityHint("加入已保护队列并排除自动删除选择")
                Button { decide(.decideLater) } label: {
                    decisionControlLabel("稍后决定")
                }
                    .accessibilityIdentifier("decision-later")
                    .accessibilityHint("移到稍后决定队列")
                }
                if model.canUndo {
                    Button { undo() } label: {
                        decisionControlLabel("撤销")
                    }
                        .accessibilityIdentifier("decision-undo")
                }
                if model.canBatchDeleteRemaining {
                    Button {
                        isShowingBatchDeleteConfirmation = true
                    } label: {
                        decisionControlLabel("批量标记删除")
                    }
                    .accessibilityIdentifier("decision-batch-delete")
                    .accessibilityHint("仅标记未收藏且未编辑的剩余截图，之后仍需删除复核")
                }
            }
        }
    }

    private func decisionControlLabel(_ title: String) -> some View {
        Text(title)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
    }

    private func decide(_ kind: PhotoDecisionKind) {
        do {
            try PhotoBoxMotion.perform(reduceMotion: reduceMotion, recordMode: recordMotionMode) {
                try model.decide(kind)
            }
            errorMessage = nil
        } catch {
            errorMessage = "无法保存决定，请重试。"
        }
    }

    private func undo() {
        do {
            try PhotoBoxMotion.perform(reduceMotion: reduceMotion, recordMode: recordMotionMode) {
                try model.undo()
            }
            errorMessage = nil
        } catch {
            errorMessage = error as? DecisionFlowError == .requiresRecentlyDeleted
                ? "此决定已提交，请在“最近删除”中恢复。"
                : "无法撤销决定，请重试。"
        }
    }

    private func batchDeleteRemaining() {
        do {
            try model.decideRemainingAsDeleteCandidate()
            errorMessage = nil
        } catch {
            errorMessage = "无法批量保存决定，请重试。"
        }
    }

    private func recordMotionMode(_ mode: PhotoBoxMotion.Mode) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing-motion-probe") else { return }
        recordedMotionMode = mode
        #endif
    }

    private func loadCurrentThumbnail() async {
        guard let descriptor = model.currentDescriptor else { return }
        thumbnailState = .loading
        guard descriptor.availability != .unavailable else {
            thumbnailState = .unavailable
            return
        }
        let thumbnails = await loader.load(assetIDs: [descriptor.id], maxPixelSize: 512)
        thumbnailState = thumbnails.first.map(MediaThumbnailState.loaded) ?? .unavailable
    }
}
