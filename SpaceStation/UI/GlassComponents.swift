import SwiftUI

/// M2 glass primitives — design logic extracted from DockDoor (GPL), rewritten
/// in our own SwiftUI without copying GPL source. macOS 15 uses the public
/// `.ultraThinMaterial`; DockDoor's private NSGlassEffectView pipeline is
/// deliberately dropped (HTML §21.6.2 / §21.6.5).

// MARK: - borderedBackground (Extensions/View.swift:14-25)
extension View {
    func borderedBackground(
        _ style: some ShapeStyle,
        lineWidth: CGFloat = 1,
        shape: some InsettableShape
    ) -> some View {
        padding(lineWidth * 0.75)
            .background { shape.strokeBorder(style, lineWidth: lineWidth) }
            .clipShape(shape)
    }
}

// MARK: - Glass surface (BlurView.swift:74-108 fallback branch)
/// A rounded/capsule glass fill. On macOS 15 we use the system material,
/// which is exactly DockDoor's fallback for < macOS 26.
struct GlassSurface<S: InsettableShape>: View {
    let shape: S
    var tintOpacity: CGFloat = StationMetrics.tintOpacity

    var body: some View {
        ZStack {
            shape.fill(.ultraThinMaterial)
            // Black/white tint layer — BlurView.swift:454-458 updateTintColor.
            shape.fill(Color.primary.opacity(tintOpacity * 0.15))
        }
    }
}

// MARK: - Container glass shell (dockStyle.swift:75-106 synthetic branch)
/// BlurView + rim-light strokeBorder. The modern `glassEffect` overlay branch
/// is macOS 26+ private-API territory and is intentionally not ported.
struct ContainerGlass<Content: View>: View {
    let cornerRadius: CGFloat
    var opacity: CGFloat = StationMetrics.glassOpacity
    let content: Content

    init(
        cornerRadius: CGFloat = StationMetrics.containerRadius,
        opacity: CGFloat = StationMetrics.glassOpacity,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.opacity = opacity
        self.content = content()
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        content
            .background {
                ZStack {
                    GlassSurface(shape: shape)
                    shape.strokeBorder(
                        StationMetrics.borderGradient(),
                        lineWidth: StationMetrics.borderWidth
                    )
                }
                .clipShape(shape)
            }
            .opacity(opacity)
    }
}

// MARK: - Material pill (MaterialPill.swift:3-20)
/// Right-side action capsule shell. Content (our actions) goes inside.
struct MaterialPill<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(GlassSurface(shape: Capsule(style: .continuous)))
            .clipShape(Capsule(style: .continuous))
            .borderedBackground(
                .primary.opacity(0.1),
                lineWidth: StationMetrics.pillStroke,
                shape: Capsule(style: .continuous)
            )
    }
}

// MARK: - Stacked shadow (StackedShadow.swift:3-47)
/// `count` stacked shadows, each alpha = 1/count. Default off upstream
/// (showPreviewShadow = false); kept as an optional modifier for the shell.
struct StackedShadowModifier: ViewModifier {
    var count: Int
    var radius: CGFloat = 10
    var color: Color = .black

    func body(content: Content) -> some View {
        content.modifier(RecursiveShadow(count: count, radius: radius, color: color))
    }

    private struct RecursiveShadow: ViewModifier {
        var count: Int
        var radius: CGFloat
        var color: Color

        func body(content: Content) -> some View {
            Group {
                if count > 0 {
                    content
                        .shadow(color: color.opacity(1 / Double(count)), radius: radius)
                        .modifier(RecursiveShadow(count: count - 1, radius: radius, color: color))
                } else {
                    content
                }
            }
        }
    }
}

extension View {
    func stackedShadow(count: Int, radius: CGFloat = 10, color: Color = .black) -> some View {
        modifier(StackedShadowModifier(count: count, radius: radius, color: color))
    }
}
