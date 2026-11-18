import AppKit
import SwiftUI

/// 卡片壳 + 内容层（四边共用，HTML §21.7.4）。
///
/// 0.5.0 / A 组的四处改动都落在这一个文件：
///  - [A-1] 图片卡真的画图：走 ThumbnailCache 的卡片级降采样；**井比 4:5**，
///          比例接近就填满、差太多就完整放下（Mac 截图不许被裁掉两侧），留白处用主色铺底。
///  - [A-2] 来源 App 显示真图标 + 真名字（SourceAppResolver），不再是 `com.apple.Safari`。
///  - [A-3] 布局归位：右上角动作组件（hover 淡入）、左下 Info（相对时间 · 可选信息 · ×N）、
///          右下留空；悬停带 **120ms 停留延迟 + 柔光**，鼠标快速划过不抖动。
///  - [A-3] 头部只留**一级名字**（App 名 / 网址只留主机名），并给右上组件让位。
struct StationCard: View {
    let item: HistoryItem
    let size: CGSize
    let isSelected: Bool
    let onSelect: () -> Void
    let onPaste: () -> Void
    let onAction: (String) -> Void
    let onFlavor: () -> Void

    /// hover 真值（带停留延迟，用于高亮 + 按钮显形 + 光效）
    @State private var isHovering = false
    /// 延迟计时进行中（防止鼠标微动反复重启计时，导致永远不触发）
    @State private var hoverPending = false
    @State private var hoverTask: Task<Void, Never>?

    @State private var showPrediction = false
    @State private var thumbnail: NSImage?
    @State private var thumbnailTint: NSColor?
    @State private var appInfo: SourceAppResolver.Info?

    private var effectiveSelected: Bool { isSelected || isHovering }
    private var isLandscape: Bool { size.width > size.height }

    private var kind: ClipKind {
        ClipKind.derive(types: item.contents.map(\.type), text: item.text)
    }

    private var headActions: [ActionDefinition] {
        Array(ActionRegistry.headActions(for: kind).prefix(2))
    }

    private var predictedAction: ActionDefinition? {
        guard let id = item.predictedActionID else { return nil }
        return ActionRegistry.byID[id]
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            background
            if effectiveSelected { selectionFill }

            VStack(alignment: .leading, spacing: 6) {
                header
                content
                Spacer(minLength: 0)
                infoLine
            }
            .padding(8)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: StationMetrics.imageRadius, style: .continuous))
            .opacity(effectiveSelected ? 1 : 0.78)
            .animation(.easeInOut(duration: 0.15), value: effectiveSelected)

            // [A-3] 动作组件：右上角、hover 才显形（§17.4），不再占底部一行。
            actionCluster
                .padding(6)
                .frame(width: size.width, height: size.height, alignment: .topTrailing)
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
                .animation(StationMetrics.hoverAnimation, value: isHovering)

            if effectiveSelected { selectionBorder }
        }
        .overlay(alignment: .bottomLeading) {
            if showPrediction, let predictedAction {
                predictionFloat(predictedAction)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            }
        }
        .frame(width: size.width + StationMetrics.innerPadding * 2,
               height: size.height + StationMetrics.innerPadding * 2)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active: beginHoverDwell()
            case .ended: endHover()
            @unknown default: endHover()
            }
        }
        .onDisappear { hoverTask?.cancel() }
        .onTapGesture { onSelect(); onPaste() }
        .animation(StationMetrics.hoverAnimation, value: effectiveSelected)
        .task(id: item.persistentModelID) { await loadSurfaces() }
        .onReceive(NotificationCenter.default.publisher(for: .sourceAppResolved)) { note in
            guard let changed = note.object as? String, changed == item.application else { return }
            appInfo = SourceAppResolver.shared.info(for: changed)
        }
    }

    // MARK: - 悬停：停留才高亮（快速划过不触发）

    private func beginHoverDwell() {
        guard !isHovering, !hoverPending else { return }
        hoverPending = true
        hoverTask?.cancel()
        hoverTask = Task { @MainActor in
            try? await Task.sleep(for: StationMetrics.hoverDwell)
            guard !Task.isCancelled else { return }
            hoverPending = false
            withAnimation(StationMetrics.hoverAnimation) { isHovering = true }
        }
    }

    private func endHover() {
        hoverTask?.cancel()
        hoverTask = nil
        hoverPending = false
        guard isHovering else { return }
        withAnimation(StationMetrics.hoverAnimation) {
            isHovering = false
            showPrediction = false
        }
    }

    // MARK: - 背景 / 选中 / 光效（§21.6 玻璃 + 描边，不做几何缩放）

    private var background: some View {
        RoundedRectangle(cornerRadius: StationMetrics.cardRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: StationMetrics.cardRadius, style: .continuous))
            .borderedBackground(
                .primary.opacity(0.1),
                lineWidth: StationMetrics.cardBgStroke,
                shape: RoundedRectangle(cornerRadius: StationMetrics.cardRadius, style: .continuous)
            )
            .padding(-StationMetrics.innerPadding)
            // [A-3] DockDoor 式观感：贴外柔光 + 顶部受光边，只改光不改几何。
            .shadow(
                color: .black.opacity(isHovering ? StationMetrics.hoverGlowOpacity : 0),
                radius: isHovering ? StationMetrics.hoverGlowRadius : 0,
                y: isHovering ? 3 : 0
            )
            .overlay {
                RoundedRectangle(cornerRadius: StationMetrics.cardRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(isHovering ? StationMetrics.hoverRimOpacity : 0),
                                     .white.opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                    .padding(-StationMetrics.innerPadding)
                    .allowsHitTesting(false)
            }
    }

    private var selectionFill: some View {
        RoundedRectangle(cornerRadius: StationMetrics.cardRadius, style: .continuous)
            .fill(Color.accentColor.opacity(StationMetrics.selectionFillOpacity))
            .padding(-StationMetrics.innerPadding)
    }

    private var selectionBorder: some View {
        RoundedRectangle(cornerRadius: StationMetrics.cardRadius, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: StationMetrics.selectionStrokeWidth)
            .padding(-StationMetrics.innerPadding)
            .allowsHitTesting(false)
    }

    // MARK: - [A-2] 头部：真图标 + 一级名字

    private var header: some View {
        HStack(spacing: 4) {
            iconView
            Text(displayName)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(height: StationMetrics.headerHeight)
        // hover 时给右上动作组件让位，文字尾部截断，绝不把按钮挤到卡外。
        .padding(.trailing, isHovering ? StationMetrics.actionClusterReserve : 0)
        .animation(StationMetrics.hoverAnimation, value: isHovering)
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon = appInfo?.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: StationMetrics.glyphSize, height: StationMetrics.glyphSize)
        } else {
            Image(systemName: kindSymbol(kind))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: StationMetrics.glyphSize, height: StationMetrics.glyphSize)
        }
    }

    /// 只显示一级：解析到的 App 名；未解析完成时退到 bundle id 的最后一段（`Safari` 而不是 `com.apple.Safari`）。
    private var displayName: String {
        if let name = appInfo?.name { return name }
        guard let bundleID = item.application, !bundleID.isEmpty else { return "未知 App" }
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }

    // MARK: - [A-1] 内容层

    @ViewBuilder
    private var content: some View {
        if kind == .image {
            imageContent
        } else {
            textContent
        }
    }

    private var imageContent: some View {
        GeometryReader { geo in
            let well = geo.size
            ZStack {
                // 主色铺底：比例不匹配时留白处也是“画面的一部分”，不是灰条。
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tintColor.opacity(0.55))

                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: fillMode(well: well))
                        .frame(width: well.width, height: well.height)
                        .clipped()
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 18))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: well.width, height: well.height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
            }
        }
    }

    private var tintColor: Color {
        if let thumbnailTint { return Color(nsColor: thumbnailTint) }
        return Color.primary.opacity(0.06)
    }

    /// 图与井比例接近 → 填满（裁一点点，视觉更满）；差太多 → 完整放下（截图两侧不许被裁）。
    private func fillMode(well: CGSize) -> ContentMode {
        guard let thumbnail, thumbnail.size.height > 0, well.height > 0 else { return .fill }
        let imageAspect = thumbnail.size.width / thumbnail.size.height
        let wellAspect = well.width / well.height
        let delta = abs(imageAspect - wellAspect) / wellAspect
        return delta <= StationMetrics.imageFillTolerance ? .fill : .fit
    }

    private var textContent: some View {
        Text(bodyText)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(isLandscape ? 3 : 5)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var bodyText: String {
        if kind == .url, let url = ClipKind.firstURL(in: item.text ?? "") {
            // [A-3] 网址只留一级（主机名）。完整 URL 走 QuickLook / 复制，不在卡上铺三行。
            if let host = url.host, !host.isEmpty { return host }
        }
        return item.title.isEmpty ? "（\(kind.cnLabel)）" : item.title
    }

    // MARK: - [A-3] 左下 Info

    private var infoLine: some View {
        Text(infoText)
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var infoText: String {
        var parts = [Self.relativeTime(item.lastCopiedAt)]
        if let second = secondaryInfo { parts.append(second) }
        if item.numberOfCopies > 1 { parts.append("×\(item.numberOfCopies)") }
        return parts.joined(separator: " · ")
    }

    /// 第二信息只在真有意义时出现（文本没有大小就不显示）。
    private var secondaryInfo: String? {
        switch kind {
        case .image:
            guard let data = item.imageData else { return nil }
            return Self.byteText(data.count)
        case .file:
            let count = item.fileURLs.count
            return count > 1 ? "\(count) 项" : nil
        case .url, .video, .text, .code, .note:
            // 网址的主机名已经是一级标题，这里不再重复。
            return nil
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private static func relativeTime(_ date: Date) -> String {
        let interval = Date.now.timeIntervalSince(date)
        if interval < 60 { return "刚刚" }
        return relativeFormatter.localizedString(for: date, relativeTo: Date.now)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.isAdaptive = true
        return formatter
    }()

    private static func byteText(_ bytes: Int) -> String {
        byteFormatter.string(fromByteCount: Int64(bytes))
    }

    // MARK: - [A-3] 右上动作组件

    private var actionCluster: some View {
        HStack(spacing: 4) {
            ForEach(headActions) { action in
                Button { onAction(action.id) } label: {
                    Text(displayIcon(for: action)).font(.system(size: StationMetrics.glyphSize))
                }
                .buttonStyle(.plain)
                .help(displayHelp(for: action))
            }

            if item.contents.count > 1 {
                Button { onFlavor() } label: {
                    Image(systemName: "square.on.square").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("切换另一种表示")
            }

            if let predictedAction {
                Button {
                    withAnimation(StationMetrics.hoverAnimation) { showPrediction.toggle() }
                } label: {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("预测：\(predictedAction.label)")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 1))
    }

    private func predictionFloat(_ action: ActionDefinition) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("预测：\(action.icon) \(action.label)")
                .font(.system(size: 10, weight: .semibold))
            Text(item.predictionReason ?? "")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(width: max(160, size.width), alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.ultraThinMaterial))
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .allowsHitTesting(false)
    }

    // MARK: - 加载（后台，不阻塞首帧）

    private struct BoxedThumb: @unchecked Sendable {
        let image: NSImage
        let tint: NSColor
    }

    private func loadSurfaces() async {
        appInfo = SourceAppResolver.shared.info(for: item.application)

        guard kind == .image, thumbnail == nil, let data = item.imageData else { return }
        let boxed = await Task.detached(priority: .userInitiated) { () -> BoxedThumb? in
            guard let image = ThumbnailCache.shared.image(forData: data) else { return nil }
            let tint = ThumbnailCache.shared.tint(forData: data, image: image)
            return BoxedThumb(image: image, tint: tint)
        }.value
        if let boxed {
            thumbnail = boxed.image
            thumbnailTint = boxed.tint
        }
    }

    // MARK: - 图标 / 文案

    private func displayIcon(for action: ActionDefinition) -> String {
        if action.id == "favorite" { return item.isFavorite ? "⭐" : "☆" }
        return action.icon
    }

    private func displayHelp(for action: ActionDefinition) -> String {
        if action.id == "favorite" {
            return item.isFavorite ? "移回 Clip — 取消永久收藏" : "收藏到 Favorite — 永久保存"
        }
        return "\(action.label) — \(action.desc)"
    }

    private func kindSymbol(_ kind: ClipKind) -> String {
        switch kind {
        case .text: return "doc.text"
        case .url: return "link"
        case .image: return "photo"
        case .video: return "play.rectangle"
        case .file: return "folder"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .note: return "note.text"
        }
    }
}
