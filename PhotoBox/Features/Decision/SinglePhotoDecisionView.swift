import SwiftUI
import UIKit

struct SinglePhotoDecisionScreen: View {
    @Bindable var model: SinglePhotoDecisionFlow
    let loader: BoundedThumbnailLoader
    var albumFlow: AlbumSelectionFlow?
    var onDismissAlbumPanel: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismissAction
    @State private var heroStates: [String: MediaThumbnailState] = [:]
    @State private var thumbnailStates: [String: MediaThumbnailState] = [:]
    @State private var dragOffset: CGSize = .zero
    @State private var gestureLocked = false
    @State private var gestureTriggered = false
    @State private var gestureDirection: GestureDirection?
    @State private var gestureProgress: CGFloat = 0
    @State private var dragState = DecisionDragState()
    @State private var albumInteractionEnabled = false
    @State private var favoriteGestureStartState: Bool?
    @State private var errorMessage: String?
    @State private var isShowingBatchDeleteConfirmation = false
    @State private var isShowingDecisionActions = false
    @State private var photoScale: CGFloat = 1
    @State private var photoPan: CGSize = .zero
    @State private var zoomStartScale: CGFloat = 1
    @State private var panStartOffset: CGSize = .zero
    @GestureState private var isTouching = false

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geometry in
                ZStack(alignment: .top) {
                    VStack(spacing: 0) {
                        feedbackSpace
                        photoViewport
                    }
                    if let albumFlow {
                        Color.black.opacity(0.25 * panelProgress)
                            .contentShape(Rectangle())
                            .allowsHitTesting(albumInteractionEnabled && !operationInFlight)
                            .onTapGesture { onDismissAlbumPanel?() }
                        let panelHeight = max(0, min(360, geometry.size.height - 16))
                        InlineAlbumSelectionPanel(model: albumFlow, loader: loader, onClose: { onDismissAlbumPanel?() })
                            .frame(height: panelHeight)
                            .frame(height: panelHeight * panelProgress, alignment: .top)
                            .clipped()
                            .allowsHitTesting(albumInteractionEnabled)
                            .accessibilityHidden(!albumInteractionEnabled)
                    }
                }
                .clipped()
            }
            filmstrip
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .tabBar)
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .task { await loadThumbnails() }
        .task(id: model.currentDescriptor?.id) { await loadCurrentPhoto() }
        .onChange(of: albumFlow?.assetID) { _, id in
            if id == nil { albumInteractionEnabled = false }
            else if gestureDirection == nil { albumInteractionEnabled = true }
        }
        .onChange(of: model.currentDescriptor?.id) { _, _ in
            photoScale = 1
            photoPan = .zero
            zoomStartScale = 1
            panStartOffset = .zero
        }
        .onChange(of: isTouching) { _, touching in
            if !touching, gestureDirection != nil { resetDrag() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("decision-b01")
        .confirmationDialog("批量标记剩余截图？", isPresented: $isShowingBatchDeleteConfirmation, titleVisibility: .visible) {
            Button("标记为删除候选", role: .destructive) { batchDeleteRemaining() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这些截图未收藏且未编辑，标记后仍会进入统一删除复核。")
        }
        .sheet(isPresented: $isShowingDecisionActions) {
            DecisionActionsSheet(
                canBatchDeleteRemaining: model.canBatchDeleteRemaining,
                onDecision: { kind in
                    isShowingDecisionActions = false
                    decideFromGesture(kind)
                },
                onArchive: {
                    isShowingDecisionActions = false
                    model.requestArchive()
                },
                onBatchDelete: {
                    isShowingDecisionActions = false
                    isShowingBatchDeleteConfirmation = true
                }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }

    private var panelProgress: CGFloat {
        guard albumFlow != nil else { return 0 }
        guard gestureDirection == .down else { return 1 }
        return gestureProgress
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { dismissAction() } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                .accessibilityLabel("返回")
                .accessibilityIdentifier("decision-back")
                .disabled(operationInFlight)
            Spacer()
            VStack(spacing: 2) {
                Text(dateTitle).font(.headline)
                Text(dateSubtitle).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("decision-b01-position")
                    .accessibilityValue(model.positionText)
            }
            .multilineTextAlignment(.center)
            Spacer()
            HStack(spacing: 4) {
                Button { undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44) }
                    .disabled(!model.canUndo || operationInFlight || albumFlow != nil).accessibilityLabel("撤销")
                    .accessibilityIdentifier("decision-undo")
                Button {
                    isShowingDecisionActions = true
                } label: {
                    Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
                }
                .accessibilityLabel("更多操作")
                .accessibilityIdentifier("decision-more")
                .disabled(operationInFlight || albumFlow != nil || model.isCompleted)
            }
        }
        .foregroundStyle(.white).padding(.horizontal, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("decision-b01-header")
    }

    private var feedbackSpace: some View {
        ZStack {
            if let direction = gestureDirection {
                switch direction {
                case .left, .right:
                    EmptyView()
                case .up:
                    ZStack {
                        Image(systemName: "heart").font(.system(size: 28, weight: .medium))
                        Image(systemName: "heart.fill").font(.system(size: 28, weight: .medium))
                            .foregroundStyle(.blue)
                            .mask {
                                GeometryReader { proxy in
                                    VStack(spacing: 0) {
                                        Spacer(minLength: 0)
                                        Rectangle().frame(height: proxy.size.height * favoriteFeedbackFill)
                                    }
                                }
                            }
                    }
                    .foregroundStyle(.blue)
                    .accessibilityLabel(favoriteGestureStartState == true ? "取消收藏" : "收藏")
                case .down:
                    EmptyView()
                }
            } else if model.isCurrentFavorite {
                Image(systemName: "heart.fill").font(.caption).foregroundStyle(.blue)
                    .accessibilityLabel("已收藏")
                    .accessibilityIdentifier("decision-favorite-state")
            }
            if let message = errorMessage ?? model.favoriteErrorMessage {
                Text(message).font(.caption).foregroundStyle(.red).accessibilityIdentifier("decision-b01-error")
            }
        }
        .frame(height: 64)

    }

    private var photoViewport: some View {
        GeometryReader { proxy in
            if !model.isCompleted, let descriptor = model.currentDescriptor {
                if descriptor.availability != .local || isHeroUnavailable(descriptor.id) {
                    VStack(spacing: 16) {
                        ContentUnavailableView(
                            "照片暂不可用",
                            systemImage: "photo.badge.exclamationmark",
                            description: Text("当前照片无法访问，已保存的整理进度仍在。")
                        )
                        Button("重新载入照片") { Task { await loadCurrentPhoto() } }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("decision-photo-retry")
                    }
                    .foregroundStyle(.white)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("decision-unavailable")
                } else {
                  ZStack {
                    DecisionPhotoImage(state: heroStates[descriptor.id] ?? .loading)
                        .scaleEffect(photoScale)
                        .offset(photoPan)
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .gesture(decisionGesture)
                        .simultaneousGesture(zoomGesture)
                        .simultaneousGesture(panGesture(in: proxy.size))
                        .accessibilityHidden(true)
                  }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .offset(x: dragOffset.width, y: albumFlow != nil && gestureDirection == nil ? 24 : dragOffset.height)
                    .rotationEffect(.degrees(Double(dragOffset.width / 100) * 3))
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("decision-b01-photo")
                    .accessibilityLabel("当前照片，可向左标记待删除，向右保留")
                    .accessibilityAction(named: "待删除") { decideFromAccessibility(.deleteCandidate) }
                    .accessibilityAction(named: "保留") { decideFromAccessibility(.keep) }
                    .accessibilityAction(named: model.isCurrentFavorite ? "取消收藏" : "收藏") { model.requestFavoriteToggle() }
                    .accessibilityAction(named: "加入相册") { model.requestArchive() }
                    .accessibilityAction(named: "保护") { decideFromAccessibility(.protect) }
                    .accessibilityAction(named: "稍后决定") { decideFromAccessibility(.decideLater) }
                    .accessibilityAction(named: "重新载入照片") { Task { await loadCurrentPhoto() } }
                    .overlay(alignment: .leading) {
                        if gestureDirection == .left { horizontalFeedback(direction: .left) }
                    }
                    .overlay(alignment: .trailing) {
                        if gestureDirection == .right { horizontalFeedback(direction: .right) }
                    }
                }
            } else if model.isCompleted {
                ContentUnavailableView("已完成整理", systemImage: "checkmark.circle")
                    .foregroundStyle(.white).accessibilityIdentifier("decision-complete")
            } else {
                ContentUnavailableView("照片暂不可用", systemImage: "photo.badge.exclamationmark",
                    description: Text("当前照片无法访问，已保存的整理进度仍在。"))
                    .foregroundStyle(.white).accessibilityIdentifier("decision-unavailable")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .allowsHitTesting(!albumInteractionEnabled)
        .accessibilityHidden(albumInteractionEnabled)
    }

    private var favoriteFeedbackFill: CGFloat {
        guard let favoriteGestureStartState else { return gestureProgress }
        return favoriteGestureStartState ? 1 - gestureProgress : gestureProgress
    }

    private func horizontalFeedback(direction: GestureDirection) -> some View {
        let isDelete = direction == .left
        return VStack(spacing: 8) {
            Image(systemName: isDelete ? "trash" : "checkmark")
                .font(.system(size: 28, weight: .medium))
                .frame(width: 48, height: 48)
                .overlay {
                    Circle().trim(from: 0, to: gestureProgress)
                        .stroke(isDelete ? Color.red : Color.green, lineWidth: 2)
                        .rotationEffect(.degrees(-90))
                }
            Text(isDelete ? "待删除" : "保留").font(.caption)
        }
        .foregroundStyle(isDelete ? Color.red : Color.green)
        .frame(width: 72)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var filmstrip: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(model.allDescriptors.enumerated()), id: \.element.id) { index, descriptor in
                        Button {
                            if !model.select(index: index) { errorMessage = "无法切换到这张照片，请重试。" }
                        } label: {
                            DecisionPhotoImage(state: thumbnailStates[descriptor.id] ?? .loading)
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay {
                                    if index == model.currentIndex { RoundedRectangle(cornerRadius: 6).stroke(.white, lineWidth: 2) }
                                }
                                .overlay(alignment: .bottomTrailing) {
                                    if model.decisions[descriptor.id]?.kind == .deleteCandidate {
                                        Image(systemName: "trash.fill").font(.caption2)
                                            .padding(3).background(.black.opacity(0.7), in: Circle()).foregroundStyle(.red)
                                    }
                                }
                        }
                        .buttonStyle(.plain).id(descriptor.id).accessibilityLabel("第 \(index + 1) 张")
                    }
                }.padding(.horizontal, 16)
            }
            .frame(height: 72)
            .onChange(of: model.currentDescriptor?.id) { _, id in
                if let id { withAnimation(reduceMotion ? nil : .easeOut) { reader.scrollTo(id, anchor: .center) } }
            }
        }
        .accessibilityIdentifier("decision-b01-filmstrip").padding(.bottom, 4)
        .disabled(operationInFlight || albumFlow != nil)
        .accessibilityHidden(albumInteractionEnabled)
    }

    private var decisionGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .updating($isTouching) { _, touching, _ in touching = true }
            .onChanged { value in
                guard !gestureLocked, !albumInteractionEnabled, !model.isFavoriteOperationInFlight,
                      photoScale <= 1 else { return }
                let translation = value.translation
                let wasUndecided = dragState.direction == nil
                let triggeredDirection = dragState.update(x: translation.width, y: translation.height)
                gestureDirection = dragState.direction.map(Self.gestureDirection)
                guard let direction = gestureDirection else { return }
                if wasUndecided, direction == .down { model.requestArchivePreview() }
                if wasUndecided, direction == .up { favoriteGestureStartState = model.isCurrentFavorite }
                switch direction {
                case .left, .right:
                    gestureProgress = CGFloat(dragState.progress)
                    dragOffset = CGSize(width: (direction == .left ? -100 : 100) * gestureProgress, height: 0)
                case .up:
                    gestureProgress = CGFloat(dragState.progress)
                    dragOffset = CGSize(width: 0, height: -32 * gestureProgress)
                case .down:
                    gestureProgress = CGFloat(dragState.progress)
                    dragOffset = CGSize(width: 0, height: 24 * gestureProgress)
                }
                if let triggeredDirection, !gestureTriggered {
                    gestureTriggered = true
                    gestureLocked = true
                    trigger(Self.gestureDirection(triggeredDirection))
                }
            }
            .onEnded { _ in resetDrag() }
    }

    private func trigger(_ direction: GestureDirection) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        switch direction {
        case .left: decideFromGesture(.deleteCandidate)
        case .right: decideFromGesture(.keep)
        case .up: model.requestFavoriteToggle()
        case .down:
            model.requestArchive()
        }
    }

    private nonisolated static func gestureDirection(_ direction: DecisionDragDirection) -> GestureDirection {
        switch direction {
        case .left: .left
        case .right: .right
        case .up: .up
        case .down: .down
        }
    }

    private var dateTitle: String {
        guard let date = model.currentDescriptor?.creationDate else { return "照片整理" }
        return date.formatted(.dateTime.year().month())
    }

    private var dateSubtitle: String {
        let count = model.allDescriptors.count
        let progress = "已整理 \(model.pendingDecisionCount)/\(count)"
        guard let date = model.currentDescriptor?.creationDate else { return progress }
        return "\(date.formatted(.dateTime.month().day())) · \(progress)"
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if gestureDirection != nil && !gestureTriggered { resetDrag() }
                photoScale = min(4, max(1, zoomStartScale * value.magnification))
                if photoScale == 1 { photoPan = .zero; panStartOffset = .zero }
            }
            .onEnded { _ in
                zoomStartScale = photoScale
                if photoScale <= 1 { photoPan = .zero; panStartOffset = .zero }
            }
    }

    private func panGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard photoScale > 1 else { return }
                let maxX = size.width * (photoScale - 1) / 2
                let maxY = size.height * (photoScale - 1) / 2
                photoPan = CGSize(
                    width: min(maxX, max(-maxX, panStartOffset.width + value.translation.width)),
                    height: min(maxY, max(-maxY, panStartOffset.height + value.translation.height))
                )
            }
            .onEnded { _ in panStartOffset = photoPan }
    }

    private func loadThumbnails() async {
        let descriptors = model.allDescriptors
        guard !descriptors.isEmpty else { return }
        let localDescriptors = descriptors.filter { $0.availability == .local }
        let loaded = await loader.load(assetIDs: localDescriptors.map(\.id), maxPixelSize: 160)
        thumbnailStates = Dictionary(uniqueKeysWithValues: descriptors.map { descriptor in
            guard descriptor.availability == .local else {
                return (descriptor.id, MediaThumbnailState.unavailable)
            }
            return (descriptor.id, loaded.first(where: { $0.assetID == descriptor.id }).map(MediaThumbnailState.loaded) ?? .unavailable)
        })
    }

    private var operationInFlight: Bool {
        model.isFavoriteOperationInFlight || albumFlow?.isArchiving == true || albumFlow?.isCreatingAlbum == true
    }

    private func loadCurrentPhoto() async {
        guard let id = model.currentDescriptor?.id else { return }
        guard model.currentDescriptor?.availability == .local else {
            heroStates = [id: .unavailable]
            return
        }
        let loaded = await loader.load(assetIDs: [id], maxPixelSize: 1200)
        guard !Task.isCancelled, model.currentDescriptor?.id == id else { return }
        let thumbnail = loaded.first
        let heroState: MediaThumbnailState = if let thumbnail, UIImage(data: thumbnail.data) != nil {
            .loaded(thumbnail)
        } else {
            .unavailable
        }
        heroStates = [id: heroState]
    }

    private func isHeroUnavailable(_ id: String) -> Bool {
        if case .unavailable = heroStates[id] { return true }
        return false
    }

    private func resetDrag() {
        let shouldDismissShortArchivePreview = gestureDirection == .down && !gestureTriggered
        let openedAlbum = gestureDirection == .down && gestureTriggered
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            dragOffset = .zero; gestureProgress = 0; gestureDirection = nil
        }
        gestureTriggered = false; gestureLocked = false; favoriteGestureStartState = nil
        dragState.reset()
        if shouldDismissShortArchivePreview {
            albumInteractionEnabled = false
            onDismissAlbumPanel?()
        } else if openedAlbum {
            albumInteractionEnabled = true
        }
    }

    private func decideFromGesture(_ kind: PhotoDecisionKind) {
        guard !operationInFlight, albumFlow == nil else { return }
        do { try model.decide(kind); errorMessage = nil } catch { errorMessage = "无法保存决定，请重试。" }
    }

    private func undo() {
        do { try model.undo(); errorMessage = nil } catch { errorMessage = "无法撤销决定，请重试。" }
    }

    private func batchDeleteRemaining() {
        guard !operationInFlight, albumFlow == nil else { return }
        do { try model.decideRemainingAsDeleteCandidate(); errorMessage = nil }
        catch { errorMessage = "无法批量保存决定，请重试。" }
    }

    private func decideFromAccessibility(_ kind: PhotoDecisionKind) { decideFromGesture(kind) }
}

private struct DecisionActionsSheet: View {
    let canBatchDeleteRemaining: Bool
    let onDecision: (PhotoDecisionKind) -> Void
    let onArchive: () -> Void
    let onBatchDelete: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("保留") { onDecision(.keep) }
                        .accessibilityIdentifier("decision-keep")
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    Button("待删除") { onDecision(.deleteCandidate) }
                        .accessibilityIdentifier("decision-delete")
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    Button("加入相册") { onArchive() }
                        .accessibilityIdentifier("decision-archive")
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    Button("保护") { onDecision(.protect) }
                        .accessibilityIdentifier("decision-protect")
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    Button("稍后决定") { onDecision(.decideLater) }
                        .accessibilityIdentifier("decision-later")
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                if canBatchDeleteRemaining {
                    Section("批量操作") {
                        Button("批量标记删除", role: .destructive) { onBatchDelete() }
                            .accessibilityIdentifier("decision-batch-delete")
                            .accessibilityHint("仅标记未收藏且未编辑的剩余截图，之后仍需删除复核")
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                }
            }
            .navigationTitle("更多操作")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .accessibilityIdentifier("decision-actions-cancel")
                }
            }
        }
    }
}

private enum GestureDirection: Equatable { case left, right, up, down }

private struct InlineAlbumSelectionPanel: View {
    @Bindable var model: AlbumSelectionFlow
    let loader: BoundedThumbnailLoader
    let onClose: () -> Void
    @State private var searchText = ""
    @State private var isCreatingAlbum = false
    @State private var newAlbumName = ""
    @State private var coverStates: [String: MediaThumbnailState] = [:]

    private var albums: [PhotoAlbumDescriptor] {
        (model.recentAlbums + model.systemAlbums).filter {
            searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.title.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            panelHeader
            Divider()
            searchField
            albumList
            guidanceView
            submitButton
        }
        .background(Color(red: 0.96, green: 0.96, blue: 0.97))
        .foregroundStyle(.primary)
        .environment(\.colorScheme, .light)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 12).shadow(radius: 12)
        .sheet(isPresented: $isCreatingAlbum) {
            NavigationStack {
                VStack(spacing: 0) {
                    Form {
                        TextField("相册名称", text: $newAlbumName)
                            .accessibilityLabel("相册名称")
                            .accessibilityIdentifier("album-panel-create-name")
                    }
                    if let guidance = model.errorGuidance {
                        Text(guidance)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                            .accessibilityIdentifier("album-panel-create-error")
                    }
                }
                    .navigationTitle("新建相册").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { isCreatingAlbum = false }
                                .accessibilityIdentifier("album-panel-create-cancel")
                                .disabled(model.isCreatingAlbum)
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("创建") {
                                Task {
                                    if let id = await model.createAlbum(named: newAlbumName) {
                                        model.selectAlbumForAddition(id: id); isCreatingAlbum = false
                                    }
                                }
                            }
                            .accessibilityIdentifier("album-panel-create-confirm")
                            .disabled(
                                newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || model.isCreatingAlbum
                            )
                        }
                }
            }
            .interactiveDismissDisabled(model.isCreatingAlbum)
        }
        .overlay(alignment: .topLeading) {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityIdentifier("album-panel")
        }
        .task(id: albums.compactMap(\.coverAssetID)) { await loadAlbumCovers() }
    }

    private var panelHeader: some View {
        HStack {
            Text("加入相册").font(.headline)
            Spacer()
            Button(action: onClose) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                .accessibilityLabel("关闭相册面板")
                .disabled(model.isArchiving || model.isCreatingAlbum)
        }
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 12)
                .onEnded { value in
                    guard !model.isArchiving, !model.isCreatingAlbum,
                          value.translation.height < -70,
                          abs(value.translation.height) > abs(value.translation.width) else { return }
                    onClose()
                }
        )
    }

    private var searchField: some View {
        TextField("搜索相册", text: $searchText)
            .textFieldStyle(.roundedBorder)
            .padding(12)
            .accessibilityLabel("搜索相册")
            .accessibilityIdentifier("album-panel-search")
    }

    private var albumList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                createAlbumButton
                albumContent
            }
        }
        .frame(maxHeight: 300)
    }

    private var createAlbumButton: some View {
        Button {
            newAlbumName = ""
            isCreatingAlbum = true
        } label: {
            Label("新建相册", systemImage: "plus")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .accessibilityIdentifier("album-panel-create")
        .disabled(model.isArchiving || model.isCreatingAlbum)
    }

    @ViewBuilder
    private var albumContent: some View {
        if model.isLoading {
            ProgressView("正在载入相册").padding()
        } else if albums.isEmpty {
            Text("没有可访问的相册").foregroundStyle(.secondary).padding()
        } else {
            ForEach(albums) { album in albumRow(album) }
        }
    }

    private func albumRow(_ album: PhotoAlbumDescriptor) -> some View {
        let existing = model.existingAlbumIDs.contains(album.id)
        let selected = model.selectedAlbumIDs.contains(album.id)
        let value = existing ? "已在相册" : (selected ? "已选择" : "未选择")
        return Button { model.toggleAlbumSelection(id: album.id) } label: {
            HStack(spacing: 12) {
                AlbumCoverThumbnail(state: album.coverAssetID.flatMap { coverStates[$0] })
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title).foregroundStyle(.primary)
                    Text("\(album.assetCount) 张").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: (existing || selected) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(existing ? Color.secondary : Color.blue)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .disabled(existing || model.isArchiving || model.isCreatingAlbum)
        .accessibilityIdentifier("album-panel-row-\(album.id)")
        .accessibilityLabel("选择相册，\(album.title)")
        .accessibilityValue(value)
        .accessibilityAction { model.toggleAlbumSelection(id: album.id) }
    }

    @ViewBuilder
    private var guidanceView: some View {
        if let guidance = model.errorGuidance {
            Text(guidance)
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal, 16)
                .accessibilityIdentifier("album-panel-error")
            if model.requiresReselection {
                Button("重新选择相册") { Task { await model.reselectAlbum() } }
                    .accessibilityIdentifier("album-panel-retry")
                    .accessibilityValue("")
            }
        }
    }

    private var submitButton: some View {
        Button { Task { await model.submitSelectedAlbums() } } label: {
            Text("加入\(model.selectedAlbumCount > 0 ? "（\(model.selectedAlbumCount)）" : "")")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .padding(12)
        .disabled(!model.canSubmitSelection)
        .accessibilityIdentifier("album-panel-submit")
    }

    private func loadAlbumCovers() async {
        let ids = Array(Set(albums.compactMap(\.coverAssetID)))
        guard !ids.isEmpty else { return }
        let loaded = await loader.load(assetIDs: ids, maxPixelSize: 120)
        guard !Task.isCancelled else { return }
        coverStates = Dictionary(uniqueKeysWithValues: ids.map { id in
            let thumbnail = loaded.first { $0.assetID == id }
            let state: MediaThumbnailState = if let thumbnail, UIImage(data: thumbnail.data) != nil {
                .loaded(thumbnail)
            } else {
                .unavailable
            }
            return (id, state)
        })
    }

}

private struct AlbumCoverThumbnail: View {
    let state: MediaThumbnailState?

    var body: some View {
        ZStack {
            Color.gray.opacity(0.25)
            if case .loaded(let thumbnail) = state, let image = UIImage(data: thumbnail.data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "rectangle.stack").foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
    }
}

private struct DecisionPhotoImage: View {
    let state: MediaThumbnailState

    var body: some View {
        ZStack {
            Color.black
            switch state {
            case .loaded(let thumbnail):
                if let image = UIImage(data: thumbnail.data) {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            case .loading:
                ProgressView().tint(.white)
            case .unavailable:
                Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
            }
        }
        .accessibilityHidden(true)
    }
}
