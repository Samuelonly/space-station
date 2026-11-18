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

    // MARK: - Spacing (scaled for our panel;
    //         HTML §21.6.4 leaves spacing/inset to us)
    static let itemSpacing: CGFloat = 16
    static let inset: CGFloat = 12
    static let dockStyleOuter: CGFloat = 2

    // MARK: - Glass
    /// **层级反转（2026-11-18 修正）**：原来轨道壳 0.95、卡片又叠一层 0.78 透明度，
    /// 结果是“壳太实、卡太淡、整体发灰”。正确的关系是：
    ///  轨道壳 = 几乎没有（只要一层薄胶 + 一条亮边，让桌面透上来）
    ///  卡片   = 比壳更实（`.regularMaterial`，不透明度 1），这样卡是浮在桌面上的实物
    static let glassOpacity: CGFloat = 0.55       // 轨道壳的材质不透明度（原 0.95）
    static let tintOpacity: CGFloat = 0.10        // 轨道壳的染色（原 0.18）
    static let borderOpacity: CGFloat = 0.24      // 轨道壳亮边（原 0.15，加深让轮廓清晰）
    static let borderWidth: CGFloat = 1           // dockBackgroundBorderWidth

    // MARK: - Rim-light stroke (dockStyle.swift:112-125)
    /// 5 white stops; scale = opacity / 0.15, direction topLeading→bottomTrailing.
    static func borderGradient(opacity: CGFloat = StationMetrics.borderOpacity) -> LinearGradient {
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
    static let actionClusterReserve: CGFloat = 84

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
    /// **比例随边反转**（2026-11-18 用户口径，替换原来接反的一版）：
    /// - 轨道在**顶部 / 底部**（横向排一列卡）→ 卡是 **4:3 横版**，像 DockDoor 的窗口预览；
    /// - 轨道在**左侧 / 右侧**（纵向排一列卡）→ 卡是 **3:4 竖版**，像一叠卡片。
    /// 两个方向互为转置，同一把尺子，换边只换朝向不换体积。
    static let horizontalCard = CGSize(width: 208, height: 156)   // 4:3 横版（顶/底）
    static let verticalCard = CGSize(width: 156, height: 208)     // 3:4 竖版（左/右）

    /// 内容井 = 卡内扣掉头部 18pt、Info 行与内边距后的可用区，比例**跟随卡本身**。
    /// 填充方式见 `ContentWellFill`（一律 cover，2026-11-18 定案）。
}
