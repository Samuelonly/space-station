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
    @State private var fileIcon: NSImage?

    private var effectiveSelected: Bool { isSelected || isHovering }
    /// 是不是「正在被指着/选中」——投影加深用。语义上等于 effectiveSelected。
    private var isEmphasized: Bool { effectiveSelected }
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

            // **两种卡是两种结构，不是同一套缩排换内容。**
            //
            // 图片卡照 DockDoor：**整张卡就是图**，来源与时间作为浮层压在图上。
            // 之前我把图塞进「头部 + 内容槽 + Info 行」三行里，内容槽只剩一小块，
            // 一张截图再 cover 进去就变成局部特写——用户原话「太奇怪了」。
            // 卡片本身已经按图片比例伸缩（见 EdgePosition.cardSize(imageAspect:)），
            // 所以图铺满整卡时裁切量很小，不需要那个"窗口"。
            if kind == .image {
                imageCard
            } else if kind == .file {
                fileCard
            } else {
                textCard
            }

            // [A-3] 动作组件：右上角、hover 才显形（§17.4）。
            actionCluster
                .padding(contentPadding - 2)
                .frame(width: size.width, height: size.height, alignment: .topTrailing)
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
                .animation(StationMetrics.hoverAnimation, value: isHovering)

            // [A-4] 选中与 hover 共用一圈蓝边（HTML 口径），内容像素一点都不动。
            if effectiveSelected { accentBorder }
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
        // [A-3] 悬停“抬起”：HTML `.card:hover{transform:translateY(-2px)}` +
        // `.group{scale(1.012)}`。比之前的 1.025 更克制——卡已经很小，再放大会挤到邻卡。
        .scaleEffect(isHovering ? StationMetrics.Glass.hoverScale : 1)
        .offset(y: isHovering ? -StationMetrics.Glass.hoverLift : 0)
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

    /// 卡内边距：90pt 的窄卡用 8 会把内容压成一条缝，收到 5。
    private var contentPadding: CGFloat { min(size.width, size.height) < 100 ? 5 : 7 }
    /// Info 行的让位高度。注意这是 **padding**，不是一条布局行——
    /// 文本卡里已经没有 VStack 三段了（见 `textCard`）。
    private var infoHeight: CGFloat { 11 }

    /// **卡 = 玻璃 + 渐变 + 顶部受光 + 描边 + 投影**，直接照 HTML `.group` 搬。
    ///
    /// 上一版我把卡改成「不透明窗底色 + 单层受光」，理由是“纸才有厚度”。
    /// 那个判断是错的，而且方向正好相反：**HTML 里卡就是玻璃，纸是里面那层 `sheet`。**
    /// 卡如果是不透明实色，它和站体之间就没有“同一块玻璃上浮着一层”的关系，
    /// 整个界面立刻变成“显示器上贴了几张便利贴”——这就是用户说的“不如 HTML”。
    ///
    /// 现在对齐 HTML `.group`：
    ///   背景 `linear-gradient(180deg, 白 .125, 白 .045)`（比站体的 .115/.042 略亮 → 卡浮起来）
    ///   `backdrop-filter: blur(14)`            → `VibrancyView(.hudWindow)`
    ///   `border: 1px rgba(255,255,255,.18)`    → 卡“有形”的主要来源
    ///   `inset 0 1px 0 rgba(255,255,255,.25)`  → 顶部一条 1px 受光
    ///   `0 9px 24px rgba(0,0,0,.30)`           → 投影
    private var background: some View {
        ZStack {
            // 真玻璃。`.hudWindow` 是深色 HUD 材质，跟 HTML 的深色玻璃最接近。
            VibrancyView(
                material: .hudWindow,
                blending: .behindWindow,
                cornerRadius: radius
            )
            // 渐变：上亮下暗。这一层让玻璃“有厚度”，不是一块均匀的磨砂。
            shape.fill(
                LinearGradient(
                    colors: [
                        .white.opacity(StationMetrics.Glass.cardTop),
                        .white.opacity(StationMetrics.Glass.cardBottom),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            // 描边 0.18（HTML border）—— 卡有没有“形”，全靠这一条。
            shape.strokeBorder(
                .white.opacity(StationMetrics.Glass.cardBorder),
                lineWidth: 1
            )
            // 顶部 1px 受光：只在上边缘，往下 1pt 就消失（HTML inset 0 1px 0 .25）。
            shape.strokeBorder(
                LinearGradient(
                    colors: [
                        .white.opacity(StationMetrics.Glass.cardTopHighlight),
                        .white.opacity(0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
        }
        .clipShape(shape)
        .padding(-StationMetrics.innerPadding)
        .shadow(
            color: .black.opacity(isEmphasized
                ? StationMetrics.Glass.cardShadowHoverOpacity
                : StationMetrics.Glass.cardShadowOpacity),
            radius: isEmphasized
                ? StationMetrics.Glass.cardShadowHoverRadius
                : StationMetrics.Glass.cardShadowRadius,
            y: isEmphasized
                ? StationMetrics.Glass.cardShadowHoverY
                : StationMetrics.Glass.cardShadowY
        )
    }

    /// 选中与 hover **共用一套蓝边**（HTML `.card:hover .group, .card.is-selected .group`）。
    ///
    /// 用户之前说过「hover 只渲染边缘、不要遮罩」——对，但颜色我给错了：
    /// 我做成了白光边，把蓝色留给了选中。HTML 里两者都是 `1.5px var(--blue)`
    /// 加 `0 0 0 3px rgba(10,132,255,.13)` 的外圈光晕，只是 hover 会 `scale(1.012)` 抬起来。
    /// 蓝色就是“我要用这张卡”的通用信号，不该分裂成两套语义。
    private var accentBorder: some View {
        shape
            .strokeBorder(
                StationMetrics.Glass.accent,
                lineWidth: StationMetrics.Glass.accentBorderWidth
            )
            .shadow(
                color: StationMetrics.Glass.accent.opacity(0.40),
                radius: 4
            )
            .allowsHitTesting(false)
    }

    // MARK: - [A-2] 头部：真图标 + 一级名字

    private var header: some View {
        HStack(spacing: 4) {
            iconView
            Text(displayName)
                .font(.system(size: 9))
                .lineLimit(1)
                .truncationMode(.tail)
                // 深色玻璃卡上用白色半透明（HTML `.app-name` 是 `rgba(255,255,255,.72)`）。
                .foregroundStyle(.white.opacity(0.70))
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

    // MARK: - [A-1] 图片卡：整卡就是图（DockDoor 结构）

    /// 图片卡**没有**「头部行 / 内容槽 / Info 行」这三段。
    ///
    /// DockDoor 的窗口预览卡是：**图片铺满整张卡**，窗口标题与按钮以 pill 形式
    /// 浮在图上（`WindowPreview.swift:244-289`）。它敢这么做的前提是卡片尺寸已按
    /// 图片比例算好（`WindowPreview Supporting/DynamicWindowFrameModifier.swift`），
    /// 所以图既不会被裁成一条缝，也不会变成局部特写。
    ///
    /// 我们照做。上一版把图塞进一个小内容槽，90pt 的卡里槽只剩 78×70，
    /// 一张手机截图 cover 进去就是「局部特写」——这正是用户说“太奇怪了”的东西。
    ///
    /// 信息用最小代价浮在图上：
    ///   左上 = 来源 App 图标（圆形暗底，保证在任何亮度的图上都看得见）
    ///   左下 = 相对时间（底部 28% 渐变托底，不是给整张卡盖蒙版）
    private var imageCard: some View {
        ZStack(alignment: .bottomLeading) {
            // 信箱底：主色 + 一层暗。fit 之后只有撞闸门的极端比例才会看见它，
            // 但必须存在——否则那种图周围是透明的，卡会出现“破洞”。
            Rectangle()
                .fill(tintColor.opacity(0.30))
                .overlay(Color.black.opacity(0.18))

            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: imageContentMode)
                    .frame(width: size.width, height: size.height,
                           alignment: imageAlignment)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.30))
                    .frame(width: size.width, height: size.height)
            }

            // 底部渐变压暗：只压最后 28%，保证时间可读，不碰内容主体。
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                LinearGradient(
                    colors: [.clear, .black.opacity(0.55)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: max(18, size.height * 0.28))
            }
            .allowsHitTesting(false)

            Text(infoText)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 5)
                .padding(.bottom, 4)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        // 来源图标：浮层，不占布局。去掉上一版的圆形暗底——那在浅色图上是个黑点，
        // 在深色图上又看不见。改成“图标自带投影”，任何底上都立得住且不抢镜。
        .overlay(alignment: .topLeading) {
            iconView
                .shadow(color: .black.opacity(0.55), radius: 2, y: 0.5)
                .padding(6)
        }
    }

    // MARK: - 文件卡：大图标 + 文件名（不是路径）

    /// **文件卡以前把 `file:///Users/samuelonly/Documents/...` 整条 URL 印在卡上。**
    ///
    /// 原因在 `HistoryItem.previewableText`：它对文件卡返回 `absoluteString`，
    /// 于是 `generateTitle()` 把 URL 存成了 title，卡上就照抄。
    /// 一张 90pt 的卡里印三行路径，等于什么都没说——用户认的是图标和文件名。
    ///
    /// 现在结构跟图片卡同一套：**内容（大图标 + 名字）铺满，浮层（时间）压底**。
    /// 图标用 `NSWorkspace` 的真图标，不是 SF Symbol —— 文档、文件夹、.app、图片
    /// 一眼就能分开，这才是 Finder 的语言。
    private var fileCard: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 5) {
                Group {
                    if let fileIcon {
                        Image(nsImage: fileIcon)
                            .resizable()
                            .interpolation(.high)
                    } else {
                        Image(systemName: item.isFolderCard ? "folder.fill" : "doc.fill")
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(.white.opacity(0.34))
                    }
                }
                .frame(width: fileIconSide, height: fileIconSide)

                Text(fileDisplayName)
                    .font(.system(size: size.width < 100 ? 8.5 : 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.75)
            }
            .padding(.horizontal, contentPadding)
            .padding(.top, contentPadding)
            .padding(.bottom, contentPadding + infoHeight + 2)
            .frame(width: size.width, height: size.height, alignment: .top)

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                infoLine
                    .padding(.horizontal, contentPadding)
                    .padding(.bottom, contentPadding)
            }
            .frame(width: size.width, height: size.height, alignment: .bottomLeading)
            .allowsHitTesting(false)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
    }

    /// 图标边长：卡 90 宽 → 40；卡 120 宽 → 52。永远比卡窄一圈，四边留气。
    private var fileIconSide: CGFloat {
        max(28, min(size.width * 0.46, size.height * 0.40))
    }

    /// 文件名只留**最后一段**，多选时给出数量。绝不显示 `file://`。
    private var fileDisplayName: String {
        let urls = item.fileURLs
        guard let first = urls.first else {
            // 兜底：title 里可能已经存了 URL（老数据），剥掉协议头再取末段。
            return Self.fileName(fromStoredTitle: item.title)
        }
        if urls.count > 1 { return "\(first.lastPathComponent) 等 \(urls.count) 项" }
        return first.lastPathComponent
    }

    /// 老数据兜底：title 存的是 `file:///a/b/c.png` 时，取出 `c.png`。
    private static func fileName(fromStoredTitle title: String) -> String {
        let head = title.split(separator: "\n").first.map(String.init) ?? title
        guard head.hasPrefix("file://") || head.hasPrefix("/") else { return title }
        let decoded = head.removingPercentEncoding ?? head
        if let url = URL(string: decoded), !url.lastPathComponent.isEmpty {
            return url.lastPathComponent
        }
        return (decoded as NSString).lastPathComponent
    }

    // MARK: - 文本卡：文字直接印在卡上（没有内层纸）

    /// **不再有「薄纸」这一层。**
    ///
    /// 上一版是 `VStack { header / textContent(带一张 sheet 背景) / infoLine }`。
    /// 用户一眼看穿：「你这相当于给内容槽加了个安全区，它太大了，纯浪费地方留白」。
    /// 对，那张 `sheet` 就是安全区的边界——卡在外、纸在内，等于卡里又开了一个窗口。
    ///
    /// HTML 原型里那张 `.sheet` 之所以成立，是因为它宽 186、高 236，纸和卡之间有 9px
    /// 的余量可以看。我们的卡只有 90×120，还要塞 header + sheet + info 三段，
    /// 结果每一段都只剩一条缝。
    ///
    /// 现在结构跟图片卡统一成**两层**：
    ///   第一层 = 内容（文字从卡边加 padding 开始，直接印在玻璃上）
    ///   第二层 = 浮层（顶部来源图标与名字、底部时间、右上动作；都带小面积压暗托底，
    ///            但**不占布局高度**，所以内容不会因为它们而缩小）
    ///
    /// 唯一保留的"让位"是文字顶部的 `headerHeight` —— 否则第一行字会被图标压住。
    /// 但它是 padding，不是一条分割线，视觉上不再有"卡里分了区"的感觉。
    private var textCard: some View {
        ZStack(alignment: .topLeading) {
            textContent
                .padding(.horizontal, contentPadding)
                .padding(.top, contentPadding + StationMetrics.headerHeight)
                .padding(.bottom, contentPadding + infoHeight)
                .frame(width: size.width, height: size.height, alignment: .topLeading)

            // 顶部 26pt 的轻微压暗：图标与名字在任何亮度的玻璃上都立得住。
            // 这是**托底**，不是遮罩——它只覆盖最上面一条，且透明度 ≤ 0.18。
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.black.opacity(0.18), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: StationMetrics.headerHeight + 8)
                Spacer(minLength: 0)
            }
            .allowsHitTesting(false)

            header
                .padding(.horizontal, contentPadding)
                .padding(.top, contentPadding)

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                infoLine
                    .padding(.horizontal, contentPadding)
                    .padding(.bottom, contentPadding)
            }
            .frame(width: size.width, height: size.height, alignment: .bottomLeading)
            .allowsHitTesting(false)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
    }

    private var tintColor: Color {
        if let thumbnailTint { return Color(nsColor: thumbnailTint) }
        return Color.primary.opacity(0.06)
    }

    /// 图片一律 cover，锚点顶部。
    ///
    /// 之前"cover 会裁成局部特写 / fit 会变成一条缝"的两难，根源不在填充方式，
    /// 而在**卡的形状没有贴合图片**。现在卡宽已经按图片比例算过
    /// （`EdgePosition.cardSize(imageAspect:)`），clamp 在 2:3 ~ 3:2，
    /// 所以 cover 最多只裁掉 1/3，两个极端都不会出现。
    private var imageContentMode: ContentMode { ContentWellFill.contentMode }

    private var imageAlignment: Alignment { ContentWellFill.alignment }

    private var textContent: some View {
        Text(bodyText)
            .font(.system(size: textPointSize))
            .tracking(size.width < 100 ? -0.15 : 0)
            .lineSpacing(1)
            .lineLimit(isLandscape ? 3 : 5)
            .truncationMode(.tail)
            // 窄卡上缩字、收字距，宁可挤也不许把 “SpaceStation.app” 拆成两行断词。
            .allowsTightening(true)
            .minimumScaleFactor(0.82)
            .foregroundStyle(.white.opacity(0.90))
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// 文本字号：90pt 宽的卡用 9，120pt 用 10（HTML 在 186pt 卡上是 10.5）。
    private var textPointSize: CGFloat {
        let short = min(size.width, size.height)
        return short < 100 ? 9 : 10
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
            .font(.system(size: 8))
            // HTML `.status` 是 `rgba(255,255,255,.46)`。
            .foregroundStyle(.white.opacity(0.46))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var infoText: String {
        var parts = [Self.relativeTime(item.lastCopiedAt)]
        // 窄卡放不下“3 分钟前 · 1.2 MB · ×2”，只留时间与次数；
        // 反正完整信息 hover 有 tooltip、QuickLook 里有全貌。
        if size.width >= 100 {
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
        // HTML `.action-cluster`：`rgba(255,255,255,.075)` + 边框 0.13。
        // 不用 `.regularMaterial`——那是第二个材质层，在玻璃卡上会糊成一片。
        .background(
            Capsule().fill(.white.opacity(0.10))
        )
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
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

        // 文件卡：真图标（NSWorkspace）。走缓存，同一路径只问一次系统。
        if kind == .file, fileIcon == nil, let url = item.fileURLs.first {
            fileIcon = FileIconCache.icon(for: url.path)
        }

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

// MARK: - 文件图标缓存

/// `NSWorkspace.icon(forFile:)` 每次都是磁盘 IO（拿 .app 图标要走 bundle 解析）。
/// 滚动时一屏 5 张卡各问一次就够卡了，所以按路径缓存。
///
/// 不做异步：图标请求本身有系统缓存，首次 ~5ms，之后 <1ms；
/// 而异步会带来“先灰块再变图标”的闪烁，比慢 5ms 更难看。
enum FileIconCache {
    nonisolated(unsafe) private static let cache = NSCache<NSString, NSImage>()

    @MainActor
    static func icon(for path: String) -> NSImage? {
        if let hit = cache.object(forKey: path as NSString) { return hit }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 64, height: 64)
        cache.setObject(icon, forKey: path as NSString)
        return icon
    }
}
