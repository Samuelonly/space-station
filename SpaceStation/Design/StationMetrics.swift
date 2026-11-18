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
    /// 所以这里不需要写死比例，只写填充策略的容差。
    ///
    /// [A-1] 填充策略（社交软件那套，2026-11-18 修）：
    /// - 图与井比例差 ≤ `contentCoverTolerance` → **cover 填满**（裁一点点，视觉最满）；
    /// - 超出 → **模糊底 + 完整前景**：底层用同一张图放大模糊铺满整个井，
    ///   前景按比例完整放下。井 100% 被画面占满（不再是灰条+小图），
    ///   内容也一张不裁——「看得清」和「看得全」两个都要。
    static let contentCoverTolerance: CGFloat = 0.25
}
