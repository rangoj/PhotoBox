import SwiftUI
import UIKit

struct CleanupHomeView: View {
    @Bindable var model: AppModel
    let openDuplicates: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                Text("PhotoBox")
                    .font(.largeTitle.bold())
                    .foregroundStyle(HomePalette.text)
                    .accessibilityAddTraits(.isHeader)

                if model.authorization == .limited {
                    limitedAccessBanner
                }

                scanStatus
                collectionGrid

                if let notice = model.homeNotice {
                    noticeBanner(notice)
                }

                if model.isHomeInventoryReady {
                    if model.homeProjection.months.isEmpty, model.scan.phase == .completed {
                        emptyLibrary
                    } else {
                        monthTimeline
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(HomePalette.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityIdentifier("cleanup-home")
    }

    private var collectionGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
            alignment: .center,
            spacing: 8
        ) {
            collectionButton(
                title: "往年今日",
                source: .onThisDay,
                assetIDs: previewIDs(for: .onThisDay),
                identifier: "home-on-this-day"
            )
            collectionButton(
                title: "最近",
                source: .recent,
                assetIDs: previewIDs(for: .recent),
                identifier: "home-recent"
            )
            collectionButton(
                title: "随机",
                source: .random,
                assetIDs: previewIDs(for: .random),
                identifier: "home-random",
                showsShuffleBadge: true
            )

            Button(action: openDuplicates) {
                VStack(spacing: 7) {
                    HomeCollectionCover(
                        assetIDs: duplicatePreviewIDs,
                        loader: model.thumbnailLoader,
                        style: .split,
                        showsShuffleBadge: false
                    )
                    Text("重复项")
                        .font(.caption)
                        .foregroundStyle(HomePalette.text)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: 93, alignment: .top)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityIdentifier("home-duplicates")
            .accessibilityLabel("重复项")
            .accessibilityValue(duplicateTasks.isEmpty ? "没有可继续的重复照片任务" : "\(duplicateTasks.count) 个任务")
        }
    }

    private func collectionButton(
        title: String,
        source: CleanupHomeSource,
        assetIDs: [String],
        identifier: String,
        showsShuffleBadge: Bool = false
    ) -> some View {
        Button {
            model.startHomeCollection(source)
        } label: {
            VStack(spacing: 7) {
                HomeCollectionCover(
                    assetIDs: assetIDs,
                    loader: model.thumbnailLoader,
                    style: .single,
                    showsShuffleBadge: showsShuffleBadge
                )
                Text(title)
                    .font(.caption)
                    .foregroundStyle(HomePalette.text)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 93, alignment: .top)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .disabled(!model.isHomeInventoryReady || model.scan.isScanning)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(title)
        .accessibilityValue(collectionAccessibilityValue(for: source))
        .accessibilityHint("打开这组照片的整理任务")
    }

    @ViewBuilder
    private var scanStatus: some View {
        switch model.scan.phase {
        case .discovering, .checkingLocalAvailability:
            HomeStatusPanel(
                symbol: "photo.badge.arrow.down",
                title: model.isHomeInventoryReady ? "正在更新照片" : "正在载入照片",
                detail: "已处理 \(model.scan.processedCount) / \(model.scan.discoveredCount) 项"
            ) {
                ProgressView(value: model.scan.progress)
                    .tint(HomePalette.accent)
                    .accessibilityLabel("扫描进度")
                    .accessibilityValue(model.scan.progress.formatted(.percent.precision(.fractionLength(0))))
                Button("取消", action: model.cancelScan)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("scan-cancel")
            }
        case .cancelled:
            HomeStatusPanel(
                symbol: "pause.circle",
                title: "扫描已暂停",
                detail: "已保存当前进度"
            ) {
                Button("继续", action: model.resumeScan)
                    .buttonStyle(.borderedProminent)
                    .tint(HomePalette.accent)
                    .accessibilityIdentifier("scan-resume")
                Button("重新开始", action: model.restartScan)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("scan-restart")
            }
        case .failed:
            HomeStatusPanel(
                symbol: "exclamationmark.triangle",
                title: "扫描未完成",
                detail: model.scan.errorMessage ?? "请重试读取当前可访问的照片"
            ) {
                Button("重试", action: model.restartScan)
                    .buttonStyle(.borderedProminent)
                    .tint(HomePalette.accent)
                    .accessibilityIdentifier("scan-retry")
            }
        case .idle where !model.isHomeInventoryReady:
            HomeStatusPanel(
                symbol: "photo.on.rectangle",
                title: "正在准备照片",
                detail: "照片载入后即可开始整理"
            ) {
                Button("重新载入", action: model.restartScan)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("scan-retry")
            }
        case .idle, .completed:
            EmptyView()
        }
    }

    private var monthTimeline: some View {
        LazyVStack(alignment: .leading, spacing: 22) {
            ForEach(yearSections) { section in
                Text(section.title)
                    .font(.title2.bold())
                    .foregroundStyle(HomePalette.text)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("home-year-\(section.id)")

                ForEach(section.months) { month in
                    HomeMonthRow(
                        month: month,
                        loader: model.thumbnailLoader,
                        isEnabled: !model.scan.isScanning
                    ) {
                        model.startHomeCollection(month.source)
                    }
                }
            }
        }
    }

    private var emptyLibrary: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 32))
                .foregroundStyle(HomePalette.secondary)
            Text("没有可整理的照片")
                .font(.headline)
                .foregroundStyle(HomePalette.text)
            Text("当前可访问范围内没有照片、实况照片或全景照片。")
                .font(.subheadline)
                .foregroundStyle(HomePalette.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home-empty-state")
    }

    private var limitedAccessBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "photo.badge.exclamationmark")
                .foregroundStyle(HomePalette.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("仅显示已允许的照片")
                    .font(.subheadline.bold())
                    .foregroundStyle(HomePalette.text)
                Text("可在系统设置中更改访问范围")
                    .font(.caption)
                    .foregroundStyle(HomePalette.secondary)
            }
            Spacer(minLength: 8)
            Button("管理") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            .font(.subheadline.bold())
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityIdentifier("permission-manage-limited")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(HomePalette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("permission-limited-state")
    }

    private func noticeBanner(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(HomePalette.accent)
                .accessibilityHidden(true)
            Text(notice)
                .font(.subheadline)
                .foregroundStyle(HomePalette.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                model.homeNotice = nil
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
            }
            .foregroundStyle(HomePalette.secondary)
            .accessibilityLabel("关闭提示")
        }
        .padding(.leading, 12)
        .padding(.trailing, 2)
        .padding(.vertical, 2)
        .background(HomePalette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityIdentifier("home-notice")
    }

    private var yearSections: [HomeYearSection] {
        let groups = Dictionary(grouping: model.homeProjection.months) { $0.year }
        let years = groups.keys.compactMap { $0 }.sorted(by: >)
        var sections = years.map { year in
            HomeYearSection(
                id: String(year),
                title: String(year),
                months: (groups[year] ?? []).sorted { ($0.month ?? 0) > ($1.month ?? 0) }
            )
        }
        if let undated = groups[nil], !undated.isEmpty {
            sections.append(HomeYearSection(id: "undated", title: "日期未知", months: undated))
        }
        return sections
    }

    private var duplicateTasks: [CleanupTask] {
        model.cleanupTasks.filter {
            ($0.type == .duplicates || $0.type == .similar) && $0.isQualifyingCleanupCandidate
        }
    }

    private var duplicatePreviewIDs: [String] {
        duplicateTasks.lazy.map { uniquePrefix($0.assetIDs, count: 2) }
            .first(where: { $0.count == 2 }) ?? []
    }

    private func previewIDs(for source: CleanupHomeSource) -> [String] {
        let photos = model.homeProjection.photos(
            for: source,
            now: model.homeNow,
            calendar: model.homeCalendar
        )
        let preferred = photos.first(where: { $0.availability == .local }) ?? photos.first
        return preferred.map { [$0.id] } ?? []
    }

    private func collectionAccessibilityValue(for source: CleanupHomeSource) -> String {
        guard model.isHomeInventoryReady else { return "照片仍在载入" }
        let count = model.homeProjection.photos(
            for: source,
            now: model.homeNow,
            calendar: model.homeCalendar
        ).count
        return "\(count) 张照片"
    }
}

private struct HomeYearSection: Identifiable {
    let id: String
    let title: String
    let months: [CleanupHomeMonth]
}

private struct HomeMonthRow: View {
    let month: CleanupHomeMonth
    let loader: BoundedThumbnailLoader
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(monthTitle)
                            .font(.headline)
                            .foregroundStyle(HomePalette.text)
                        Text("\(month.assetIDs.count) 张照片")
                            .font(.caption)
                            .foregroundStyle(HomePalette.secondary)
                    }
                    Spacer(minLength: 8)
                    if month.isComplete {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(HomePalette.accent)
                            .accessibilityLabel("已完成")
                    } else if month.processedCount > 0 {
                        Text("已整理 \(month.processedCount)/\(month.assetIDs.count)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(HomePalette.accent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HomeThumbnailStrip(assetIDs: month.previewAssetIDs, loader: loader)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home-month-\(month.id)")
        .accessibilityLabel(monthTitle)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("打开这个月份的整理任务")
    }

    private var monthTitle: String {
        month.month.map { "\($0)月" } ?? "日期未知"
    }

    private var accessibilityValue: String {
        if month.isComplete { return "\(month.assetIDs.count) 张照片，已完成" }
        if month.processedCount > 0 {
            return "\(month.assetIDs.count) 张照片，已处理 \(month.processedCount) 张"
        }
        return "\(month.assetIDs.count) 张照片，尚未开始"
    }
}

private struct HomeThumbnailStrip: View {
    let assetIDs: [String]
    let loader: BoundedThumbnailLoader
    @State private var thumbnailData: [String: Data] = [:]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<4, id: \.self) { index in
                let assetID = assetIDs.indices.contains(index) ? assetIDs[index] : nil
                HomeThumbnailCell(data: assetID.flatMap { thumbnailData[$0] })
                    .aspectRatio(1, contentMode: .fit)
            }
        }
        .accessibilityHidden(true)
        .task(id: assetIDs) {
            thumbnailData = thumbnailData.filter { assetIDs.contains($0.key) }
            let thumbnails = await loader.load(assetIDs: assetIDs, maxPixelSize: 240)
            guard !Task.isCancelled else { return }
            thumbnailData = Dictionary(uniqueKeysWithValues: thumbnails.map { ($0.assetID, $0.data) })
        }
    }
}

struct HomeCollectionCover: View {
    enum Style { case single, split }

    let assetIDs: [String]
    let loader: BoundedThumbnailLoader
    let style: Style
    let showsShuffleBadge: Bool
    @State private var thumbnailData: [String: Data] = [:]

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                switch style {
                case .single:
                    HomeThumbnailCell(data: assetIDs.first.flatMap { thumbnailData[$0] })
                case .split:
                    HStack(spacing: 2) {
                        HomeThumbnailCell(data: assetIDs.first.flatMap { thumbnailData[$0] })
                        HomeThumbnailCell(data: assetIDs.dropFirst().first.flatMap { thumbnailData[$0] })
                    }
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            if showsShuffleBadge {
                Image(systemName: "shuffle")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(HomePalette.background)
                    .frame(width: 20, height: 20)
                    .background(HomePalette.accent, in: Circle())
                    .overlay { Circle().stroke(HomePalette.background, lineWidth: 2) }
                    .offset(x: 3, y: 3)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 64, height: 64)
        .accessibilityHidden(true)
        .task(id: assetIDs) {
            thumbnailData = thumbnailData.filter { assetIDs.contains($0.key) }
            let thumbnails = await loader.load(assetIDs: assetIDs, maxPixelSize: 160)
            guard !Task.isCancelled else { return }
            thumbnailData = Dictionary(uniqueKeysWithValues: thumbnails.map { ($0.assetID, $0.data) })
        }
    }
}

private struct HomeThumbnailCell: View {
    let data: Data?

    var body: some View {
        ZStack {
            HomePalette.placeholder
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(HomePalette.secondary)
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HomeStatusPanel<Actions: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder let actions: Actions

    init(
        symbol: String,
        title: String,
        detail: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(HomePalette.accent)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.bold())
                        .foregroundStyle(HomePalette.text)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(HomePalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("home-scan-status")
            HStack(spacing: 12) { actions }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HomePalette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private enum HomePalette {
    static let background = Color(red: 18 / 255, green: 19 / 255, blue: 22 / 255)
    static let surface = Color(red: 31 / 255, green: 33 / 255, blue: 38 / 255)
    static let placeholder = Color(red: 42 / 255, green: 44 / 255, blue: 50 / 255)
    static let text = Color(red: 227 / 255, green: 226 / 255, blue: 230 / 255)
    static let secondary = Color(red: 139 / 255, green: 145 / 255, blue: 160 / 255)
    static let accent = Color(red: 170 / 255, green: 199 / 255, blue: 255 / 255)
}

private func uniquePrefix(_ values: [String], count: Int) -> [String] {
    var seen: Set<String> = []
    var result: [String] = []
    for value in values where seen.insert(value).inserted {
        result.append(value)
        if result.count == count { break }
    }
    return result
}
