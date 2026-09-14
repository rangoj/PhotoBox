import SwiftUI

struct AlbumCreationSheet: View {
    @Bindable var model: AlbumHomeModel
    @FocusState private var nameIsFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("相册名称", text: $model.creationName)
                    .focused($nameIsFocused)
                    .disabled(model.isCreating || model.creationNeedsRefresh)
                    .accessibilityIdentifier("album-creation-name")
                if model.isCreating {
                    ProgressView("正在创建相册")
                        .accessibilityIdentifier("album-creation-loading")
                }
                if let error = model.creationError {
                    Text(error).foregroundStyle(.red)
                        .accessibilityIdentifier("album-creation-error")
                }
                if model.creationNeedsRefresh {
                    Button("刷新确认") { Task { await model.recoverCreation() } }
                        .disabled(model.isLoading)
                        .accessibilityIdentifier("album-creation-recover")
                }
            }
            .navigationTitle("新建相册")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { model.cancelCreation() }
                        .disabled(model.isCreating)
                        .accessibilityIdentifier("album-creation-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") { Task { await model.createAlbum() } }
                        .disabled(model.isCreating || model.creationNeedsRefresh
                            || model.creationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("album-creation-submit")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(model.isCreating)
        .onAppear { nameIsFocused = true }
    }
}
