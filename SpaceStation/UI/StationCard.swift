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

    @Environment(\.colorScheme) private var colorScheme

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
    private var isDark: Bool { colorScheme == .dark }
    private var isLandscape: Bool { size.width > size.height }
    /// 圆角随卡尺寸缩放（窄卡不许圆成胶囊）。
    private var radius: CGFloat { StationMetrics.cardRadius(for: size) }
    /// 内容井的圆角永远比卡小一圈。
    private var wellRadius: CGFloat { StationMetrics.imageRadius(for: size) }

    private var kind: ClipKind {
        ClipKind.derive(types: item.contents.map(\.type), text: item.text)
    }

    /// 卡宽 160 时给两个动作；90 的窄卡只给一个——再多就不是“快捷”，是把卡糊住。
    private var visibleActionCount: Int { size.width < 120 ? 1 : 2 }
    /// 窄卡上不放“换表示”和“预测”两个额外芯片（宽度真的没有）。
    private var showsExtraChips: Bool { size.width >= 120 }

    private var headActions: [ActionDefinition] {
        Array(ActionRegistry.headActions(for: kind).prefix(visibleActionCount))
    }

    /// 右上动作组件实际占宽：每个芯片 16 + 2 间距，外加胶囊左右各 4。
    /// 头部文字按这个值让位，小卡上也不会把名字挤到卡外。
    private var actionClusterReserve: CGFloat {
        var chips = headActions.count
        if showsExtraChips, item.contents.count > 1 { chips += 1 }
        if showsExtraChips, predictedAction != nil { chips += 1 }
        return CGFloat(max(chips, 1)) * 18 + 8
    }

    private var predictedAction: ActionDefinition? {
        guard let id = item.predictedActionID else { return nil }
        return ActionRegistry.byID[id]
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            background

            VStack(alignment: .leading, spacing: 6) {
                header
                content
                Spacer(minLength: 0)
                infoLine
            }
            .padding(contentPadding)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))

            // [A-3] 动作组件：右上角、hover 才显形（§17.4），不再占底部一行。
            actionCluster
                .padding(contentPadding - 2)
                .frame(width: size.width, height: size.height, alignment: .topTrailing)
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
                .animation(StationMetrics.hoverAnimation, value: isHovering)

            // [A-4] hover 只让**卡自己的边**亮起来（在上面 background 里画）；
            // 蓝色实线只属于“选中”，两者不再混用一套视觉。
            if isSelected { selectionBorder }
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
        // [A-3] 悬停“抬起”：几何缩放 1.025 + 同步加深的柔光。
        // 放在 contentShape 之后，命中区域仍是原尺寸，不会因为卡变大而抖。
        .scaleEffect(isHovering ? StationMetrics.hoverScale : 1)
        .zIndex(isHovering ? 10 : 0)
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

    // MARK: - 背景 / 选中 / 光效（§21.6 玻璃 + 描边）

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    /// 卡内边距随卡宽收放：90pt 的窄卡用 8 会把内容井压成一条缝。
    private var contentPadding: CGFloat { size.width < 120 ? 5 : 8 }

    /// **卡 = 实体纸片，不是第二层玻璃。**
    ///
    /// 这条是划清“原型感”和“产品感”的地方：一张纸能看出厚度，靠的不是透明度，
    /// 是**受光 + 投影**。所以卡片彻底退出玻璃体系——
    ///   ① 实色底（窗底色），桌面不再透上来；
    ///   ② 顶部受光：光从上方来，卡顶提亮、到中线消失（浅色模式才明显）；
    ///   ③ 两层阴影：接触阴影（贴地）+ 环境阴影（离地），静止时就存在；
    ///   ④ 1pt 内描边收住轮廓。
    /// 上一版卡是 72% 半透明 + 无阴影，等于“白纸贴在玻璃上”，一眼就是画的。
    /// 顺带的好处：5 张卡不再各占一个 `NSVisualEffectView`，少五层实时模糊。
    private var background: some View {
        shape
            .fill(Color(nsColor: .windowBackgroundColor))
            .overlay {
                // 受光：从顶部到底部中线，白光衰减到 0。
                shape.fill(
                    LinearGradient(
                        colors: [
                            .white.opacity(isDark ? 0.09 : 0.62),
                            .white.opacity(0),
                        ],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
            }
            .overlay {
                shape.strokeBorder(.primary.opacity(0.075), lineWidth: 1)
            }
            .padding(-StationMetrics.innerPadding)
            // 两层阴影：近距离的“接触”＋远距离的“环境”。只有一层会显脏，
            // 只有远层会显飘——真实物体的影子永远有这两个成分。
            .shadow(
                color: .black.opacity(isDark ? 0.38 : 0.10),
                radius: isHovering ? 2.5 : 1.5,
                y: isHovering ? 2 : 1
            )
            .shadow(
                color: .black.opacity(isDark ? 0.30 : (isHovering ? 0.16 : 0.10)),
                radius: isHovering ? 16 : 10,
                y: isHovering ? 7 : 4
            )
            // **hover = 渲染卡片自己的边缘**（用户 2026-11-18 反复强调）。
            // 不是盖一层半透明色块，也不是缩放把内容糊掉：只是让这一圈边亮起来，
            // 光从左上进来、往右下走。内容像素一个都不动。
            .overlay {
                shape
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(isHovering ? StationMetrics.hoverRimOpacity : 0),
                                     .white.opacity(isHovering ? StationMetrics.hoverRimOpacity * 0.15 : 0)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                    .padding(-StationMetrics.innerPadding)
                    .allowsHitTesting(false)
            }
    }

    /// 选中态 = **一圈算出来的蓝边**（画在卡自己的轮廓上，不向内垫、不盖蒙版）。
    /// 以前是“整卡盖 40% 蓝”＋“外圈描边”，等于给内容蒙了层蓝纱，越选越看不清。
    private var selectionBorder: some View {
        shape
            .strokeBorder(Color.accentColor, lineWidth: StationMetrics.selectionStrokeWidth)
            .shadow(color: Color.accentColor.opacity(0.35),
                    radius: StationMetrics.selectionGlowRadius)
            .allowsHitTesting(false)
    }

    // MARK: - [A-2] 头部：真图标 + 一级名字

    private var header: some View {
        HStack(spacing: 4) {
            iconView
            Text(displayName)
                .font(.system(size: size.width < 120 ? 9 : 10))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(height: StationMetrics.headerHeight)
        // hover 时给右上动作组件让位，文字尾部截断，绝不把按钮挤到卡外。
        .padding(.trailing, isHovering ? actionClusterReserve : 0)
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
                // 主色铺底：缩略图还没解码出来时，井里是一块从画面里取来的颜色，不是灰块。
                RoundedRectangle(cornerRadius: wellRadius, style: .continuous)
                    .fill(tintColor.opacity(0.55))

                if let thumbnail {
                    // **一律 cover（Instagram / 微博逻辑）+ 顶部锚点（2026-11-18）**：
                    // 井里没有留白；超出部分先裁底部、保住开头。
                    // 居中裁会让手机截图只剩中间一块空白——那才是最糟的取景。
                    Image(nsImage: thumbnail)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: ContentWellFill.contentMode)
                        .frame(width: well.width, height: well.height,
                               alignment: ContentWellFill.alignment)
                        .clipped()
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 18))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: well.width, height: well.height)
            .clipShape(RoundedRectangle(cornerRadius: wellRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: wellRadius, style: .continuous)
                    .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
            }
        }
    }

    private var tintColor: Color {
        if let thumbnailTint { return Color(nsColor: thumbnailTint) }
        return Color.primary.opacity(0.06)
    }

    private var textContent: some View {
        // 文字卡要像**一段摘录**，不像标题：字号压到 11、行距松一点、
        // 用满可用高度。上一版 12pt + 3 行，在 120 高的卡里显得又大又空。
        Text(bodyText)
            .font(.system(size: size.width < 120 ? 9.5 : 11))
            .tracking(size.width < 120 ? -0.15 : 0)
            .lineSpacing(1)
            .lineLimit(isLandscape ? 4 : 5)
            .truncationMode(.tail)
            // 窄卡上缩一点字、收一点字距，宁可挤也不许把 “SpaceStation.app” 拆成
            // “SpaceStation.ap / p”——断词比截断难看十倍（§17.3 的同一原则）。
            .allowsTightening(true)
            .minimumScaleFactor(0.86)
            .foregroundStyle(.primary.opacity(0.88))
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var bodyText: String {
        if kind == .url, let host = ClipKind.oneLevelDisplay(item.text ?? "") {
            // [A-3] 网址只留一级（主机名）。完整 URL 走 QuickLook / 复制，不在卡上铺三行。
            return host
        }
        return item.title.isEmpty ? "（\(kind.cnLabel)）" : item.title
    }

    // MARK: - [A-3] 左下 Info

    private var infoLine: some View {
        Text(infoText)
            .font(.system(size: size.width < 120 ? 8.5 : 9))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var infoText: String {
        var parts = [Self.relativeTime(item.lastCopiedAt)]
        // 窄卡（90pt）放不下“3 分钟前 · 1.2 MB · ×2”，只留时间与次数；
        // 反正完整信息 hover 有 tooltip、QuickLook 里有全貌。
        if size.width >= 120 {
            if let second = secondaryInfo { parts.append(second) }
        }
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
        HStack(spacing: 2) {
            ForEach(headActions) { action in
                Button { onAction(action.id) } label: {
                    Text(displayIcon(for: action))
                        .font(.system(size: StationMetrics.actionGlyphSize))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: StationMetrics.actionChipSize,
                               height: StationMetrics.actionChipSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(displayHelp(for: action))
            }

            if showsExtraChips, item.contents.count > 1 {
                chipButton(symbol: "square.on.square", help: "切换另一种表示") { onFlavor() }
            }

            if showsExtraChips, let predictedAction {
                chipButton(symbol: "arrow.up.forward.app", help: "预测：\(predictedAction.label)") {
                    withAnimation(StationMetrics.hoverAnimation) { showPrediction.toggle() }
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 1))
    }

    /// 动作组件里的 SF 图标：外框 16、图标 14（用户 2026-11-18 口径：
    /// 组件自身有 1pt 描边，所以图标取 14 才和 16 的源 App 图标视觉等重）。
    private func chipButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: StationMetrics.actionGlyphSize - 1, weight: .medium))
                .frame(width: StationMetrics.actionChipSize,
                       height: StationMetrics.actionChipSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
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
