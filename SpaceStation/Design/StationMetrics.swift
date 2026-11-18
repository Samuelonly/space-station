import SwiftUI

/// M2 card-shell design tokens. Design logic only — no third-party source copied
/// (see THIRD_PARTY_LICENSES). Values are tuned defaults per §21.
/// We target macOS 15+ and use the public `.ultraThinMaterial`; private-API glass
/// pipelines are intentionally dropped (HTML §21.6.2 / §21.6.5).
enum StationMetrics {
    // MARK: - Radii
    static let innerPadding: CGFloat = 6          // CardRadius.innerPadding
    static let cardRadius: CGFloat = 24.2         // 20 + 6×0.7
    static let imageRadius: CGFloat = 18.2        // card − 6
    static let containerRadius: CGFloat = 34      // 20 + 20×0.7

    // MARK: - Spacing (scaled for our panel;
    //         HTML §21.6.4 leaves spacing/inset to us)
    static let itemSpacing: CGFloat = 16
    static let inset: CGFloat = 12
    static let dockStyleOuter: CGFloat = 2

    // MARK: - Glass (consts.swift:197-207 + BlurView.swift:165-173)
    static let glassOpacity: CGFloat = 0.95       // dockGlassOpacity
    static let tintOpacity: CGFloat = 0.18        // dockBackgroundTintOpacity
    static let borderOpacity: CGFloat = 0.15      // dockBackgroundBorderOpacity
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
    static let selectionFillOpacity: CGFloat = 0.4   // accent.opacity(0.4)
    static let selectionStrokeWidth: CGFloat = 2.5   // strokeBorder 2.5
    static let hoverAnimation = Animation.snappy(duration: 0.175)

    /// [A-3] 悬停**停留延迟**：鼠标扫过时不能立即高亮/出按钮，
    /// 否则快速划过整条轨道会连续点着几十张卡（动画 + 布局全部重算，肉眼可见地卡）。
    /// 120ms 是“像 DockDoor 那样跟手”与“不误触发”的分界。
    static let hoverDwell: Duration = .milliseconds(120)

    /// [A-3] 悬停光效（DockDoor 观感：贴外的柔光 + 顶部受光边，不做几何缩放）
    static let hoverGlowRadius: CGFloat = 12
    static let hoverGlowOpacity: CGFloat = 0.22
    static let hoverRimOpacity: CGFloat = 0.28

    // MARK: - Card 内元素尺寸（0.5.0 统一 16pt）
    static let glyphSize: CGFloat = 16
    static let headerHeight: CGFloat = 18
    /// 右上动作组件在 hover 时占掉的宽度，头部文字据此让位，避免挤掉按钮。
    static let actionClusterReserve: CGFloat = 92

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
    /// top/bottom → portrait card (height > width); left/right → landscape.
    /// [A-1] 容器固定 **3:2**（132×198 / 198×132）：四边共用同一把尺，
    /// 换边时只旋转轴不换比例，滚动时卡宽恒定、不会忽宽忽窄。
    static let cardAspect: CGFloat = 3.0 / 2.0
    static let portraitCard = CGSize(width: 132, height: 198)
    static let landscapeCard = CGSize(width: 198, height: 132)

    /// [A-1] 图片「井」的比例 = **4:5**（去掉头部 18pt、Info 行与内边距后的实际可用区）。
    /// 依据：竖卡内容区 ≈ 116×143 ≈ 0.81；4:5 是社交与手机截图的主流竖比，
    /// 也是 Copy'em / 相册网格的容器惯例——缩略图按这个比例取景，四边留白最均衡。
    static let imageWellAspect: CGFloat = 4.0 / 5.0
    /// 图与井比例差在 ±12% 内用“填满”（裁一点点、视觉更满），超出则“完整放下”，
    /// 保证 16:10 的 Mac 截图不会被裁掉两侧。
    static let imageFillTolerance: CGFloat = 0.12
}
