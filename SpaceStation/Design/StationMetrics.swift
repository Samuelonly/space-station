import SwiftUI

/// M2 card-shell design tokens. Extracted from DockDoor design logic only (GPL):
/// every value below is a real source-read default with its file:line citation.
/// We are macOS 15+ — DockDoor's Liquid Glass modern pipeline is gated to
/// macOS 26/27 and leans on private APIs (dlsym / NSGlassEffectView._variant).
/// Per HTML §21.6.2 we keep the *design logic* (layer stack, rim gradient,
/// radii, spacing, animation curves) and render the glass with the public
/// `.ultraThinMaterial`; the private-API探测 layer is intentionally dropped.
enum StationMetrics {
    // MARK: - Radii (dockStyle.swift:4-43, defaults uniform=true/base=20/mult=0.7)
    static let innerPadding: CGFloat = 6          // CardRadius.innerPadding
    static let cardRadius: CGFloat = 24.2         // 20 + 6×0.7
    static let imageRadius: CGFloat = 18.2        // card − 6
    static let containerRadius: CGFloat = 34      // 20 + 20×0.7

    // MARK: - Spacing (BaseHoverContainer.swift:5-13, but scaled for our panel;
    //         HTML §21.6.4 leaves spacing/inset to us — DockDoor never hardcodes it)
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
    static let portraitCard = CGSize(width: 132, height: 200)
    static let landscapeCard = CGSize(width: 200, height: 132)
}
