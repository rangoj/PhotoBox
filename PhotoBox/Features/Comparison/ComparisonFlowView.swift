import SwiftUI

struct ComparisonFlowScreen: View {
    @Bindable var model: ComparisonFlowModel
    let loader: BoundedThumbnailLoader
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var thumbnailModel: ComparisonThumbnailModel
    @State private var inspectedPage: MediaPage?
    @State private var completionError: String?
    @State private var recordedMotionMode: PhotoBoxMotion.Mode?

    init(model: ComparisonFlowModel, loader: BoundedThumbnailLoader) {
        self.model = model
        self.loader = loader
        _thumbnailModel = State(initialValue: ComparisonThumbnailModel(loader: loader))
    }

    var body: some View {
        Group {
            if let group = model.currentGroup {
                List {
                    Section {
                        Text(model.groupPositionText)
                            .font(.subheadline.monospacedDigit())
                            .accessibilityIdentifier("comparison-group-position")
                        Text("已选删除候选 \(model.deleteCandidateCount) 项")
                            .accessibilityIdentifier("comparison-delete-count")
                            .accessibilityValue("\(model.deleteCandidateCount)")
                        Text("预计可释放 \(formattedComparisonBytes(model.estimatedReclaimableBytes))")
                            .accessibilityIdentifier("comparison-reclaimable-bytes")
                            .accessibilityValue("\(model.estimatedReclaimableBytes)")
                    }

                    recommendationSection

                    Section("本组照片") {
                        LazyVGrid(
                            columns: dynamicTypeSize.isAccessibilitySize
                                ? [GridItem(.flexible())]
                                : [GridItem(.adaptive(minimum: 150), spacing: 12)],
                            spacing: 12
                        ) {
                            ForEach(Array(group.candidates.enumerated()), id: \.element.id) { index, candidate in
                                candidateTile(candidate, index: index)
                            }
                        }
                        .accessibilityIdentifier("comparison-media-grid")
                    }

                    Section {
                        Button("完成本组") {
                            do {
                                try PhotoBoxMotion.perform(
                                    reduceMotion: reduceMotion,
                                    recordMode: recordMotionMode
                                ) {
                                    try model.completeCurrentGroup()
                                }
                            } catch let error as ComparisonFlowError {
                                completionError = error == .keepSelectionRequired
                                    ? "此组没有可信推荐，请先明确选择一张要保留的照片。"
                                    : "无法完成本组。"
                            } catch {
                                completionError = "无法保存本组决定。请重试。"
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canCompleteCurrentGroup)
                        .accessibilityIdentifier("comparison-complete-group")
                    }
                }
                .listStyle(.insetGrouped)
                .task(id: group.id) {
                    thumbnailModel.load(pages: pages(for: group))
                }
            } else {
                ContentUnavailableView(
                    "已完成所有对比",
                    systemImage: "checkmark.circle",
                    description: Text("删除候选会在后续复核中统一确认。")
                )
            }
        }
        .navigationTitle("照片对比")
        .sheet(item: $inspectedPage) { page in
            NavigationStack {
                MediaPagerView(
                    pages: [page] + pagesForCurrentGroup.filter { $0.id != page.id },
                    loader: loader
                )
                .navigationTitle("查看照片")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { inspectedPage = nil } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("关闭查看照片")
                        .accessibilityIdentifier("comparison-inspector-dismiss")
                    }
                }
            }
        }
        .onDisappear(perform: thumbnailModel.cancelLoading)
        .alert("无法完成本组", isPresented: completionErrorAlert) {
            Button("好", role: .cancel) { completionError = nil }
        } message: {
            Text(completionError ?? "")
        }
        #if DEBUG
        .overlay(alignment: .topLeading) {
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-motion-probe"),
               let recordedMotionMode {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityIdentifier("motion-probe-comparison")
                    .accessibilityValue(recordedMotionMode.rawValue)
            }
        }
        #endif
    }

    @ViewBuilder
    private var recommendationSection: some View {
        if model.isLowConfidence {
            Section("需要你的选择") {
                Text("没有可信推荐，请选择要保留的照片。")
                    .accessibilityIdentifier("comparison-low-confidence")
            }
            .accessibilityIdentifier("comparison-low-confidence-section")
        } else if model.isRecommendationOverridden {
            Section("你的选择") {
                Text("已按你的选择保留照片。")
                    .accessibilityIdentifier("comparison-user-selection")
            }
        } else if let recommendation = model.displayedRecommendation {
            Section("推荐保留") {
                Text("建议保留当前选中的照片")
                    .accessibilityIdentifier("comparison-recommendation-section")
                ForEach(recommendation.reasons, id: \.self) { reason in
                    Label(reason.title, systemImage: "checkmark.seal")
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("comparison-reason-\(reason.rawValue)")
                }
            }
        }
    }

    private func candidateTile(_ candidate: PhotoCandidate, index: Int) -> some View {
        let page = MediaPage(
            descriptor: candidate.asset,
            isManuallyProtected: candidate.manualProtection
        )
        let isKeep = model.selectedKeepIDs.contains(candidate.id)
        return VStack(alignment: .leading, spacing: 8) {
            MediaViewport(page: page, state: thumbnailModel.state(for: page.id))
                .frame(height: 148)
            Text(isKeep ? "保留" : "删除候选")
                .font(.headline)
                .foregroundStyle(isKeep ? Color.primary : Color.red)
            MediaMetadataBadges(page: page)
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    inspectButton(page: page, candidate: candidate, index: index)
                    keepButton(candidate: candidate, index: index, isKeep: isKeep)
                        .frame(maxWidth: .infinity)
                }
            } else {
                HStack {
                    inspectButton(page: page, candidate: candidate, index: index)
                    Spacer()
                    keepButton(candidate: candidate, index: index, isKeep: isKeep)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(candidateAccessibilityLabel(candidate, index: index, isKeep: isKeep))
        .accessibilityIdentifier("comparison-media-\(candidate.id)")
    }

    private func inspectButton(
        page: MediaPage,
        candidate: PhotoCandidate,
        index: Int
    ) -> some View {
        Button {
            inspectedPage = page
        } label: {
            Image(systemName: "magnifyingglass")
        }
        .accessibilityLabel("查看第 \(index + 1) 张照片")
        .accessibilityHint("打开大图查看")
        .accessibilityIdentifier("comparison-inspect-\(candidate.id)")
    }

    private func keepButton(
        candidate: PhotoCandidate,
        index: Int,
        isKeep: Bool
    ) -> some View {
        Button {
            PhotoBoxMotion.perform(reduceMotion: reduceMotion, recordMode: recordMotionMode) {
                model.selectKeep(assetID: candidate.id)
            }
        } label: {
            Text("选为保留")
                .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("comparison-select-keep-\(candidate.id)")
        .accessibilityLabel("将第 \(index + 1) 张选为保留")
        .accessibilityValue(isKeep ? "已选中" : "未选中")
        .accessibilityAddTraits(isKeep ? .isSelected : [])
    }

    private var pagesForCurrentGroup: [MediaPage] {
        model.currentGroup.map(pages(for:)) ?? []
    }

    private func pages(for group: PhotoCandidateGroup) -> [MediaPage] {
        group.candidates.map {
            MediaPage(descriptor: $0.asset, isManuallyProtected: $0.manualProtection)
        }
    }

    private var completionErrorAlert: Binding<Bool> {
        Binding(
            get: { completionError != nil },
            set: { if !$0 { completionError = nil } }
        )
    }

    private func recordMotionMode(_ mode: PhotoBoxMotion.Mode) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing-motion-probe") else { return }
        recordedMotionMode = mode
        #endif
    }

    private func candidateAccessibilityLabel(
        _ candidate: PhotoCandidate,
        index: Int,
        isKeep: Bool
    ) -> String {
        var parts = ["第 \(index + 1) 张", "当前\(isKeep ? "保留" : "删除候选")"]
        if model.displayedRecommendation?.recommendedKeepID == candidate.id {
            parts.append("推荐保留")
        }
        if candidate.asset.isFavorite { parts.append("已收藏") }
        if candidate.asset.isEdited { parts.append("已编辑") }
        if candidate.manualProtection { parts.append("已保护") }
        return parts.joined(separator: "，")
    }
}

private func formattedComparisonBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
