import SwiftUI

struct AlbumSelectionScreen: View {
    @Bindable var model: AlbumSelectionFlow

    @State private var isCreatingAlbum = false
    @State private var newAlbumName = ""

    var body: some View {
        List {
            Section {
                Text("为当前照片选择归档相册")
                    .accessibilityIdentifier("album-current-asset")
                    .accessibilityLabel("当前照片")
                    .accessibilityValue("等待选择归档相册")
            }

            if model.isLoading {
                Section {
                    ProgressView("正在载入相册")
                        .accessibilityIdentifier("album-loading-state")
                }
            }

            if !model.recentAlbums.isEmpty {
                Section {
                    ForEach(model.recentAlbums) { album in
                        albumButton(album, identifier: "album-recent-row-\(album.id)")
                    }
                } header: {
                    Text("最近使用")
                        .accessibilityIdentifier("album-recent-section")
                }
            }

            Section {
                if model.systemAlbums.isEmpty && !model.isLoading {
                    Text("没有其他可访问的系统相册")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("album-system-empty")
                } else {
                    ForEach(model.systemAlbums) { album in
                        albumButton(album, identifier: "album-system-row-\(album.id)")
                    }
                }
            } header: {
                Text("系统相册")
                    .accessibilityIdentifier("album-system-section")
            }

            if model.isArchiving {
                Section {
                    ProgressView("正在归档")
                        .accessibilityIdentifier("album-archive-progress")
                }
            }

            if let guidance = model.errorGuidance {
                Section {
                    Text(guidance)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("album-error-guidance")
                    if model.requiresReselection {
                        Button("重新选择相册") {
                            Task { await model.reselectAlbum() }
                        }
                        .accessibilityIdentifier("album-reselection-action")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("album-list")
        .navigationTitle("选择相册")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newAlbumName = ""
                    isCreatingAlbum = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .accessibilityLabel("新建相册")
                .accessibilityIdentifier("album-create-command")
                .disabled(model.isArchiving)
            }
        }
        .sheet(isPresented: $isCreatingAlbum) {
            createAlbumSheet
        }
    }

    private func albumButton(_ album: PhotoAlbumDescriptor, identifier: String) -> some View {
        Button {
            Task { await model.selectAlbum(id: album.id) }
        } label: {
            HStack {
                Label(album.title, systemImage: "rectangle.stack")
                Spacer()
                Text(album.assetCount, format: .number)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityIdentifier(identifier)
        .accessibilityLabel("选择相册，\(album.title)")
        .accessibilityValue("包含 \(album.assetCount) 项")
        .accessibilityHint("将当前照片归档到此相册")
        .disabled(model.isArchiving)
    }

    private var createAlbumSheet: some View {
        NavigationStack {
            Form {
                Section("相册名称") {
                    TextField("新相册", text: $newAlbumName)
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("album-create-name")
                        .accessibilityLabel("相册名称")
                    if let guidance = model.errorGuidance {
                        Text(guidance)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("album-create-error")
                    }
                }
            }
            .navigationTitle("新建相册")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { isCreatingAlbum = false }
                        .accessibilityIdentifier("album-create-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        Task {
                            await model.createAndArchive(named: newAlbumName)
                            if model.hasCompletedArchive || model.requiresReselection {
                                isCreatingAlbum = false
                            }
                        }
                    }
                    .accessibilityIdentifier("album-create-confirm")
                    .disabled(model.isArchiving)
                }
            }
        }
        .interactiveDismissDisabled(model.isArchiving)
    }
}
