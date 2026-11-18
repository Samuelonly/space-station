import AppKit
import SwiftUI

/// M2 card-shell design tokens. Design logic only — no third-party source copied
/// (see THIRD_PARTY_LICENSES). Values are tuned defaults per §21.
/// We target macOS 15+ and use the public `.ultraThinMaterial`; private-API glass
/// pipelines are intentionally dropped (HTML §21.6.2 / §21.6.5).
enum StationMetrics {
    // MARK: - Radii
    static let innerPadding: CGFloat = 6
    static let imageRadiusBase: CGFloat = 18.2
    static let containerRadius: CGFloat = 34      // 20 + 20×0.7

    /// 卡圆角**随短边缩放**（2026-11-18 用户口径：窄卡被拉得像胶囊）。
    /// 死写一个数会出现“156 宽的卡圆得像药丸，208 宽的反而不够圆”。
    static func cardRadius(for size: CGSize) -> CGFloat {
        min(24.2, min(size.width, size.height) * 0.135)
    }

    /// 内容井的圆角永远比卡小一圈，视觉上才是“卡里嵌了一层”。
    static func imageRadius(for size: CGSize) -> CGFloat {
        max(10, cardRadius(for: size) - 5)
    }

    /// 外框（轨道壳）圆角：跟着**宽度**走，窄轨道不会因为一个死数显成橄榄形。
    static func containerRadius(for width: CGFloat) -> CGFloat {
        guard width > 0 else { return containerRadius }
        return min(containerRadius, width * 0.155)
    }

    // MARK: - Spacing
    /// 间距回到 **16**（HTML `--rail-gap:16px`）。
    /// 12 是我之前为了"塞下 5 张"硬压的；其实卡变小之后 16 更对——
    /// 卡片之间要能看见桌面，卡才不会糊成一条。
    static let itemSpacing: CGFloat = 16
    static let inset: CGFloat = 12
    static let dockStyleOuter: CGFloat = 2
    /// 纵向轨道左侧的纯图标栏宽（不再放文字，见 NavBar）。
    static let sidebarWidth: CGFloat = 44
    /// 横向轨道上控件行的实际高度。导航与筛选**合并成一行**——
    /// 上一版两行共 56pt，占掉 208 高的 27%，读者第一眼看到的是一条工具条，
    /// 而不是五张卡。合并后只剩 26pt，卡片重新成为主体。
    static let headerRowHeight: CGFloat = 24
    static let navRowHeight: CGFloat = 22
    static let filterRowHeight: CGFloat = 22
    /// 滚动区四周给**阴影**留的呼吸（每边）。卡片现在有 radius 10 的环境阴影，
    /// 若让 ScrollView 贴着卡边裁，影子会被切掉半截，卡立刻“贴”回墙上。
    static let railBleed: CGFloat = 6

    // MARK: - 首屏张数（这是硬指标，不是感觉）
    /// **一屏必须看得见 5 张卡**（用户 2026-11-18：只能看到 2.5 张就不对）。
    /// 面板尺寸一律由这个数反推，而不是先拍一个窗口大小再往里塞。
    static let firstScreenCards = 5

    // MARK: - Glass
    /// **壳 = 真玻璃，不靠 alpha 模拟**（2026-11-18 重做）。
    /// 上一版把 `.opacity(0.55)` 加在整棵内容树上，卡片文字跟着一起变灰——
    /// 那是“整体发灰”的病根，不是调参能救的。现在透明度归 `NSVisualEffectView`。
    static let shellMaterial: NSVisualEffectView.Material = .underWindowBackground
    /// 给玻璃一个色温（不是遮罩、不是半透明白）。0.035 刚好能定形，看不出有层膜。
    static let shellTint: CGFloat = 0.035
    static let borderWidth: CGFloat = 1

    /// 壳的边缘：**淡到几乎看不见**（用户口径：“边框可以淡到看不见，是用 Glass 完成的”）。
    /// 只保留左上受光、右下收暗的一点点方向感，不再画一圈“框”。
    static var shellRimGradient: LinearGradient {
        LinearGradient(
            colors: [
                .white.opacity(0.16),
                .white.opacity(0.05),
                .white.opacity(0.015),
                .white.opacity(0.06),
                .white.opacity(0.11),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - HTML 原型的视觉语言（2026-11-18 对齐）
    //
    /// **这一组数是 `space-station.html` 的 `:root` / `.station` / `.group` / `.viewport`
    /// 直接搬过来的，不是重新调的。**
    ///
    /// 用户评语：「别说和 DockDoor 不一样了，它甚至还不如 HTML 呢。」
    /// 查下来不是参数问题，是**整套语言没实现**：HTML 是深色玻璃站 + 深色玻璃卡 +
    /// 暗底 viewport + 内层纸 sheet；我做的是系统浅色 + 白卡 + 单层。捡了数字，丢了体系。
    ///
    /// HTML 里同一件事有两层玻璃：
    ///   站体 `.station` = 白 0.115→0.042 + blur 32 + saturate 165% + 边 0.175 + 影 0 26 72
    ///   卡片 `.group`   = 白 0.125→0.045 + blur 14 + saturate 150% + 边 0.18 + 影 0 9 24
    /// 卡片比站体**更亮一点**（0.125 vs 0.115），所以卡是浮在站体上的，不是贴在墙上。
    enum Glass {
        /// 站体玻璃渐变上端 / 下端（HTML `.station`）。
        static let shellTop: CGFloat = 0.115
        static let shellBottom: CGFloat = 0.042
        /// 卡片玻璃渐变上端 / 下端（HTML `.group`）。比站体略亮 → 卡浮起来。
        static let cardTop: CGFloat = 0.125
        static let cardBottom: CGFloat = 0.045
        /// 卡片描边（HTML `.group` border）。这一条是“卡有形”的主要来源。
        static let cardBorder: CGFloat = 0.18
        /// 卡片顶部 1px 受光（HTML `inset 0 1px 0 rgba(255,255,255,.25)`）。
        static let cardTopHighlight: CGFloat = 0.25

        /// 内容井（HTML `.viewport`）：**暗底**，让缩略图/文字从暗处浮出来。
        static let viewportFill: CGFloat = 0.16     // rgba(0,0,0,.16)
        static let viewportBorder: CGFloat = 0.075
        /// 内层纸（HTML `.sheet`）：viewport 里再嵌一张更亮的薄纸。
        static let sheetFill: CGFloat = 0.045
        /// viewport 底部压暗的渐变高度（HTML `.viewport::after` height:30px）。
        static let viewportFadeHeight: CGFloat = 30

        /// 站体投影（HTML `0 26px 72px rgba(0,0,0,.46)`）。
        static let shellShadowRadius: CGFloat = 26
        static let shellShadowOpacity: CGFloat = 0.46
        static let shellShadowY: CGFloat = 14
        /// 卡片投影（HTML `0 9px 24px rgba(0,0,0,.30)`）。
        static let cardShadowRadius: CGFloat = 12
        static let cardShadowOpacity: CGFloat = 0.30
        static let cardShadowY: CGFloat = 5
        /// hover 时卡片投影加深（HTML `0 14px 30px rgba(0,0,0,.4)`）。
        static let cardShadowHoverRadius: CGFloat = 16
        static let cardShadowHoverOpacity: CGFloat = 0.40
        static let cardShadowHoverY: CGFloat = 7

        /// 选中/hover 的蓝（HTML `--blue:#0A84FF`）。
        static let accent = Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255)
        /// 蓝边宽度（HTML `border: 1.5px solid var(--blue)`）。
        static let accentBorderWidth: CGFloat = 1.5
        /// 外圈光晕（HTML `0 0 0 3px rgba(10,132,255,.13)`）。
        static let accentHaloWidth: CGFloat = 3
        static let accentHaloOpacity: CGFloat = 0.22
        /// hover 抬起（HTML `transform: scale(1.012)` + 卡上移 2px）。
        static let hoverScale: CGFloat = 1.012
        static let hoverLift: CGFloat = 2
    }

    // MARK: - Rim-light stroke (dockStyle.swift:112-125)
    /// 保留旧接口：少量辅助面板还在用“稍微明显一点”的边。
    static func borderGradient(opacity: CGFloat = 0.15) -> LinearGradient {
        let scale = opacity / 0.15
        return LinearGradient(
            colors: [
                .white.opacity(0.35 * scale),
                .white.opacity(0.12 * scale),
                .white.opacity(0.05 * scale),
                .white.opacity(0.12 * scale),
                .white.opacity(0.28 * scale),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Selection / hover (WindowPreview.swift:847-879, :912-925)
    /// **选中不拉蒙版**（2026-11-18 用户口径）：以前是在整张卡上盖 40% 的蓝，
    /// 内容直接被染成一片，越选越看不清。现在只换**边**——蓝描边是“算出来的一圈线”，
    /// 不是覆盖层，内容像素一点不动。
    static let selectionStrokeWidth: CGFloat = 2
    static let selectionGlowRadius: CGFloat = 5
    /// 保留给极端调试用（0 = 不盖任何颜色，别再往回调）。
    static let selectionFillOpacity: CGFloat = 0
    static let hoverAnimation = Animation.snappy(duration: 0.175)

    /// [A-3] 悬停**停留延迟**：鼠标扫过时不能立即高亮/出按钮，
    /// 否则快速划过整条轨道会连续点着几十张卡（动画 + 布局全部重算，肉眼可见地卡）。
    /// 120ms 是“像 DockDoor 那样跟手”与“不误触发”的分界。
    static let hoverDwell: Duration = .milliseconds(120)

    /// [A-3] 悬停光效（DockDoor 观感：贴外的柔光 + 顶部受光边）
    static let hoverGlowRadius: CGFloat = 14
    static let hoverGlowOpacity: CGFloat = 0.26
    static let hoverRimOpacity: CGFloat = 0.28
    /// [A-3] 悬停“抬起”：**1.025 的几何缩放**。
    /// 注意：这与 §21.6 原始口径（DockDoor 无几何缩放）不同——用户明确要求
    /// “悬停要看得见”。2.5% 是能感知又不会挤到邻卡的上限；配合同步加深的柔光，
    /// 观感是“卡浮起来”而不是“卡变大”。要退回无缩放，只改这一个数到 1.0。
    static let hoverScale: CGFloat = 1.025

    // MARK: - Card 内元素尺寸（0.5.0 统一 16pt）
    /// 单一标尺 **16**：源 App 图标、动作组件的外框都按这个走，视觉才等重。
    static let glyphSize: CGFloat = 16
    /// 动作图标在图 16 的框内取 **14**——动作外面还有一圈胶囊描边，
    /// 16 的框 + 1pt 描边 = 视觉 18，正好压住 16 的源图标，不会显大。
    static let actionChipSize: CGFloat = 16
    static let actionGlyphSize: CGFloat = 14
    static let headerHeight: CGFloat = 18
    /// 右上动作组件在 hover 时占掉的宽度，头部文字据此让位，避免挤掉按钮。
    /// 4 个 16pt 芯片 + 间距 + 胶囊内边距 ≈ 78，留 6pt 余量。
    /// 右上动作组件在 hover 时占掉的宽度由卡宽现算（见 StationCard.actionClusterReserve），
    /// 这里只留一个下限，供旧调用方参考。
    static let actionClusterReserve: CGFloat = 44

    // MARK: - Card background stroke (WindowPreview.swift:853, MaterialPill.swift:12)
    static let cardBgStroke: CGFloat = 1.75          // .primary.opacity(0.1)
    static let pillStroke: CGFloat = 1.5

    // MARK: - Shadow (consts.swift:188-189, L131) — off by default upstream
    static let shadowRadius: CGFloat = 8
    static let shadowOpacityScale: CGFloat = 0.2

    // MARK: - Grid scroll (CardGridScrollView.swift:107, :128-129, :152)
    static let gridAnimation = Animation.easeOut(duration: 0.15)
    static let commitDelay: Double = 0.12
    static let scrollDeltaMultiplier: CGFloat = 10

    // MARK: - Card body size per dock edge (HTML §18.5 / §9)
    /// **卡的比例由「排列方向」决定**（2026-11-18 用户第二次校准，这次是最终口径）。
    ///
    /// 逻辑只有一句：**哪边是瓶颈，就把哪边压小。**
    /// - 顶/底 = 横向排一列 → **宽度**是瓶颈 → 卡压窄 → **3:4 竖版 90×120**：一排放得下 5 张。
    /// - 左/右 = 纵向排一列 → **高度**是瓶颈 → 卡压矮 → **4:3 横版 120×90**：一列放得下 5 张。
    ///
    /// 上一版我把这条接反了（顶/底做成 160×120 横卡、左右做成 90×120 竖卡），
    /// 结果横排放不下、纵排放不下，两边都在"抽屉里翻东西"。
    /// 注意这不是"转置"：横版和竖版是在**不同的边**上为了不同的瓶颈各自压出来的，
    /// 所以不要求两边面积相等，只要求**两边首屏都能装 5 张**。
    static let horizontalCard = CGSize(width: 90, height: 120)    // 3:4 竖版（顶/底）
    static let verticalCard = CGSize(width: 120, height: 90)      // 4:3 横版（左/右）

    /// 内容井 = 卡内扣掉头部 18pt、Info 行与内边距后的可用区，比例**跟随卡本身**。
    /// 填充方式见 `ContentWellFill`（一律 cover，微博 / Instagram 逻辑：先看信息，不是先看图）。

    /// 卡内三段（头部 / 内容槽 / Info）之间的纵向间距。
    /// HTML `.group` 是 `gap:9px`，但它的卡高 236；我们的卡高 160，
    /// 按比例折到 5——9 会在这张卡上把内容槽吃掉一成。
    static let cardInnerSpacing: CGFloat = 5
}
