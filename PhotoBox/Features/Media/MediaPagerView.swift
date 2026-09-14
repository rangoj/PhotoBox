import SwiftUI
import UIKit

struct MediaPagerScreen: View {
    let pages: [MediaPage]
    let loader: BoundedThumbnailLoader

    var body: some View {
        MediaPagerView(pages: pages, loader: loader)
            .navigationTitle("照片对比")
    }
}

struct MediaPagerView: View {
    @State private var model: MediaPagerModel

    init(pages: [MediaPage], loader: BoundedThumbnailLoader) {
        _model = State(initialValue: MediaPagerModel(pages: pages, loader: loader))
    }

    var body: some View {
        VStack(spacing: 16) {
            TabView(selection: pageSelection) {
                ForEach(Array(model.pages.enumerated()), id: \.element.id) { index, page in
                    MediaViewport(page: page, state: index == model.currentIndex ? model.thumbnailState : .loading)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .frame(height: 280)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("照片分页区域")
            .accessibilityIdentifier("media-viewport")

            HStack(spacing: 20) {
                Button(action: model.showPreviousPage) {
                    Image(systemName: "chevron.left")
                }
                .disabled(model.currentIndex == 0)
                .accessibilityLabel("上一张")
                .accessibilityIdentifier("media-previous-page")

                Text("\(model.currentIndex + 1) / \(model.pages.count)")
                    .font(.subheadline.monospacedDigit())
                    .accessibilityIdentifier("media-page-position")

                Button(action: model.showNextPage) {
                    Image(systemName: "chevron.right")
                }
                .disabled(model.currentIndex + 1 >= model.pages.count)
                .accessibilityLabel("下一张")
                .accessibilityIdentifier("media-next-page")
            }
            .frame(height: 44)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("media-page-controls")

            if let page = model.currentPage {
                MediaMetadataBadges(page: page)
            }
        }
        .padding()
        .task { model.loadCurrentPage() }
        .onDisappear(perform: model.cancelLoading)
    }

    private var pageSelection: Binding<Int> {
        Binding(
            get: { model.currentIndex },
            set: { model.selectPage(at: $0) }
        )
    }
}

struct MediaViewport: View {
    let page: MediaPage
    let state: MediaThumbnailState

    var body: some View {
        ZStack {
            switch state {
            case .loading:
                VStack(spacing: 8) {
                    ProgressView()
                    Text("正在载入缩略图")
                        .accessibilityIdentifier("media-thumbnail-loading-\(page.id)")
                }
            case .loaded(let thumbnail):
                if let image = UIImage(data: thumbnail.data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                        .accessibilityLabel("缩略图已载入")
                        .accessibilityIdentifier("media-thumbnail-loaded-\(page.id)")
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 52))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("缩略图已载入")
                        .accessibilityIdentifier("media-thumbnail-loaded-\(page.id)")
                }
            case .unavailable:
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 44))
                    Text("无法载入此缩略图")
                        .accessibilityIdentifier("media-thumbnail-unavailable-\(page.id)")
                }
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(page.descriptor.mediaType.title)缩略图")
        .accessibilityValue(thumbnailAccessibilityValue)
    }

    private var thumbnailAccessibilityValue: String {
        switch state {
        case .loading: "正在载入"
        case .loaded: "已载入"
        case .unavailable: "无法载入"
        }
    }
}

struct MediaMetadataBadges: View {
    let page: MediaPage

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { badges }
            VStack(alignment: .leading, spacing: 8) { badges }
        }
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var badges: some View {
        MediaBadge(
            title: page.descriptor.mediaType.title,
            symbol: page.descriptor.mediaType.symbol,
            identifier: page.descriptor.mediaType.accessibilityIdentifier + "-" + page.id
        )
        if page.descriptor.isFavorite {
            MediaBadge(title: "已收藏", symbol: "heart.fill", identifier: "media-badge-favorite-\(page.id)")
        }
        if page.descriptor.isEdited {
            MediaBadge(title: "已编辑", symbol: "slider.horizontal.3", identifier: "media-badge-edited-\(page.id)")
        }
        if page.isManuallyProtected {
            MediaBadge(title: "已保护", symbol: "lock.shield", identifier: "media-badge-protected-\(page.id)")
        }
    }
}

private struct MediaBadge: View {
    let title: String
    let symbol: String
    let identifier: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(identifier)
    }
}

private extension PhotoMediaType {
    var title: String {
        switch self {
        case .photo: "照片"
        case .video: "视频"
        case .livePhoto: "实况照片"
        case .panorama: "全景照片"
        }
    }

    var symbol: String {
        switch self {
        case .photo: "photo"
        case .video: "video"
        case .livePhoto: "livephoto"
        case .panorama: "pano"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .photo: "media-badge-photo"
        case .video: "media-badge-video"
        case .livePhoto: "media-badge-live-photo"
        case .panorama: "media-badge-panorama"
        }
    }
}
