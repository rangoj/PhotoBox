import SwiftUI

enum DecisionQueueKind {
    case decideLater
    case protectedPhotos

    var title: String {
        switch self {
        case .decideLater: "稍后决定"
        case .protectedPhotos: "受保护照片"
        }
    }

    var emptyTitle: String {
        switch self {
        case .decideLater: "没有稍后决定的照片"
        case .protectedPhotos: "没有受保护的照片"
        }
    }

    var emptySymbol: String {
        switch self {
        case .decideLater: "clock"
        case .protectedPhotos: "lock.shield"
        }
    }

    var listIdentifier: String {
        switch self {
        case .decideLater: "decide-later-list"
        case .protectedPhotos: "protected-list"
        }
    }

    var emptyIdentifier: String {
        switch self {
        case .decideLater: "decide-later-empty"
        case .protectedPhotos: "protected-empty"
        }
    }
}

struct DecisionQueueScreen: View {
    let kind: DecisionQueueKind
    @Bindable var model: DecisionQueueModel
    let loader: BoundedThumbnailLoader
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var recordedMotionMode: PhotoBoxMotion.Mode?

    var body: some View {
        Group {
            if model.isLoading && items.isEmpty {
                ProgressView("正在载入")
                    .accessibilityIdentifier("decision-queue-loading")
            } else if let message = model.errorMessage, items.isEmpty {
                QueueFailureView(message: message) {
                    retry()
                }
            } else if items.isEmpty {
                ContentUnavailableView(modelEmptyTitle, systemImage: kind.emptySymbol)
                    .accessibilityIdentifier(kind.emptyIdentifier)
            } else {
                List {
                    if let message = model.errorMessage {
                        Section {
                            Label(message, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                                .accessibilityIdentifier("decision-queue-error")
                            Button("重试") { retry() }
                                .accessibilityIdentifier("decision-queue-retry")
                        }
                    }

                    Section {
                        ForEach(items) { item in
                            DecisionQueueRow(
                                item: item,
                                kind: kind,
                                loader: loader,
                                action: { performAction(for: item.id) }
                            )
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .accessibilityIdentifier(kind.listIdentifier)
            }
        }
        .navigationTitle(kind.title)
        .task {
            if model.isLoading {
                await model.load()
            }
        }
        #if DEBUG
        .overlay(alignment: .topLeading) {
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-motion-probe"),
               let recordedMotionMode {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityIdentifier("motion-probe-queue")
                    .accessibilityValue(recordedMotionMode.rawValue)
            }
        }
        #endif
    }

    private var items: [DecisionQueueItem] {
        switch kind {
        case .decideLater: model.decideLaterItems
        case .protectedPhotos: model.protectedItems
        }
    }

    private var modelEmptyTitle: String { kind.emptyTitle }

    private func performAction(for assetID: String) {
        PhotoBoxMotion.perform(reduceMotion: reduceMotion, recordMode: recordMotionMode) {
            switch kind {
            case .decideLater:
                model.deferAgain(assetID: assetID)
            case .protectedPhotos:
                model.unprotect(assetID: assetID)
            }
        }
    }

    private func recordMotionMode(_ mode: PhotoBoxMotion.Mode) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing-motion-probe") else { return }
        recordedMotionMode = mode
        #endif
    }

    private func retry() {
        if model.canRetry {
            model.retryLastAction()
        } else {
            Task { await model.load() }
        }
    }
}

private struct QueueFailureView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                "无法载入整理队列",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
            .accessibilityIdentifier("decision-queue-error")
            Button("重试", action: retry)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("decision-queue-retry")
        }
        .padding()
    }
}

private struct DecisionQueueRow: View {
    let item: DecisionQueueItem
    let kind: DecisionQueueKind
    let loader: BoundedThumbnailLoader
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var thumbnailState = MediaThumbnailState.loading

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                MediaViewport(page: page, state: thumbnailState)
                    .frame(width: 88, height: 88)
                VStack(alignment: .leading, spacing: 8) {
                    MediaMetadataBadges(page: page)
                    Text(ByteCountFormatter.string(
                        fromByteCount: item.decision.estimatedBytes,
                        countStyle: .file
                    ))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }

            Button(action: action) {
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(spacing: 4) {
                            Image(systemName: actionSymbol)
                            Text(actionTitle)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Label(actionTitle, systemImage: actionSymbol)
                    }
                }
                .frame(
                    maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil,
                    minHeight: 44
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
            .accessibilityIdentifier(actionIdentifier)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(queueItemLabel)
        .accessibilityValue(kind == .decideLater ? "稍后决定" : "已保护")
        .accessibilityIdentifier("decision-queue-item-\(item.id)")
        .task(id: item.id) {
            await loadThumbnail()
        }
    }

    private var page: MediaPage {
        MediaPage(
            descriptor: item.descriptor,
            isManuallyProtected: item.decision.kind == .protect
        )
    }

    private var actionIdentifier: String {
        switch kind {
        case .decideLater: "decision-defer-again-\(item.id)"
        case .protectedPhotos: "decision-unprotect-\(item.id)"
        }
    }

    private var actionTitle: String {
        switch kind {
        case .decideLater: "再次稍后决定"
        case .protectedPhotos: "取消保护"
        }
    }

    private var actionSymbol: String {
        switch kind {
        case .decideLater: "clock.arrow.circlepath"
        case .protectedPhotos: "lock.open"
        }
    }

    private var queueItemLabel: String {
        var parts = [
            "队列照片",
            "预计大小 \(ByteCountFormatter.string(fromByteCount: item.decision.estimatedBytes, countStyle: .file))"
        ]
        if item.descriptor.isFavorite { parts.append("已收藏") }
        if item.descriptor.isEdited { parts.append("已编辑") }
        if item.decision.kind == .protect { parts.append("已保护") }
        return parts.joined(separator: "，")
    }

    private func loadThumbnail() async {
        thumbnailState = .loading
        let thumbnails = await loader.load(assetIDs: [item.id], maxPixelSize: 256)
        thumbnailState = thumbnails.first.map(MediaThumbnailState.loaded) ?? .unavailable
    }
}
