import SwiftUI

struct AlbumContentView: View {
    let collectionID: String
    @Bindable var appModel: AppModel
    @State private var content: AlbumContentModel?
    @State private var contentRevision = -1

    var body: some View {
        Group {
            if contentRevision != appModel.albumHome.revision {
                ProgressView("正在载入相册")
            } else if let content {
                if content.isLoading {
                    ProgressView("正在载入照片").accessibilityIdentifier("album-content-loading")
                } else if let error = content.errorMessage {
                    VStack(spacing: 16) {
                        ContentUnavailableView("无法载入相册", systemImage: "exclamationmark.triangle", description: Text(error))
                        Button("重试") { Task { await content.load() } }
                            .frame(minHeight: 44).accessibilityIdentifier("album-content-retry")
                    }
                } else if content.assets.isEmpty {
                    ContentUnavailableView("暂无照片或视频", systemImage: "photo.on.rectangle")
                        .accessibilityIdentifier("album-content-empty")
                } else {
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                            ForEach(content.assets) { asset in
                                AlbumThumbnailView(assetID: asset.id, loader: appModel.thumbnailLoader)
                                    .overlay(alignment: .bottomTrailing) {
                                        if asset.mediaType == .video {
                                            Label(duration(asset.duration), systemImage: "video.fill")
                                                .font(.caption2).padding(4)
                                                .background(.black.opacity(0.7))
                                        }
                                    }
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel(mediaLabel(asset))
                                    .accessibilityIdentifier("album-content-asset-\(asset.id)")
                            }
                        }
                    }
                    .accessibilityIdentifier("album-content-grid")
                }
            } else {
                ContentUnavailableView("此相册已不可用", systemImage: "rectangle.stack.badge.minus")
                    .accessibilityIdentifier("album-content-unavailable")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 18 / 255, green: 19 / 255, blue: 22 / 255))
        .navigationTitle(content?.collection.title ?? "相册")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: appModel.albumHome.revision) { await reloadContent() }
    }

    private func reloadContent() async {
        content?.invalidate()
        let replacement = appModel.makeAlbumContentModel(collectionID: collectionID)
        content = replacement
        contentRevision = appModel.albumHome.revision
        await replacement?.load()
    }

    private func duration(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func mediaLabel(_ asset: PhotoAssetDescriptor) -> String {
        let kind: String = switch asset.mediaType {
        case .video: "视频，\(duration(asset.duration))"
        case .livePhoto: "实况照片"
        case .panorama: "全景照片"
        case .photo: "照片"
        }
        return asset.availability == .iCloudOnly ? "\(kind)，仅云端可用" : kind
    }
}

struct AlbumThumbnailView: View {
    let assetID: String?
    let loader: BoundedThumbnailLoader
    @State private var image: UIImage?

    var body: some View {
        Color(white: 0.15)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    GeometryReader { geometry in
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    }
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .clipped()
            .accessibilityHidden(true)
            .task(id: assetID) {
                image = nil
                guard let assetID else { return }
                let thumbnails = await loader.load(assetIDs: [assetID], maxPixelSize: 480)
                guard !Task.isCancelled else { return }
                image = thumbnails.first.flatMap { UIImage(data: $0.data) }
            }
    }
}
