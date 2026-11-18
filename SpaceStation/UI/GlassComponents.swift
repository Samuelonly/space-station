import AppKit
import SwiftUI

/// M2 glass primitives — design logic only, rewritten in our own SwiftUI with
/// no third-party source copied (see THIRD_PARTY_LICENSES).
///
/// **2026-11-18 更正：玻璃必须是 AppKit 的 `NSVisualEffectView`。**
/// 上一版全项目用 SwiftUI 的 `.regularMaterial` / `.ultraThinMaterial`，
/// 那是 SwiftUI 自己的近似磨砂——它只对“窗口内的兄弟视图”做模糊，
/// 而我们的面板是透明窗口，它拿不到身后的桌面，观感就永远是一层灰白雾。
/// DockDoor 用的是 `NSVisualEffectView`（BlurView.swift），Swift 占 1.73MB、
/// 零 CSS —— 跟我们同一套底层，不存在“它做得到我们做不到”。
/// 差别只在 `blendingMode`：`.behindWindow` 才会真正采样并模糊桌面。

/// 真·玻璃层。作为背景铺在任何 SwiftUI 形状底下。
struct VibrancyView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    var cornerRadius: CGFloat = 0
    /// 强调态（跟随系统 accent 提亮）。壳不用，卡片也不用——我们要的是“桌面透上来”。
    var isEmphasized: Bool = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        // **`.active` 是必须的**：面板大多数时间不是 key window，
        // 默认的 `.followsWindowActiveState` 会在失焦瞬间把玻璃塌成死灰。
        view.state = .active
        view.material = material
        view.blendingMode = blending
        view.isEmphasized = isEmphasized
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.state = .active
        view.material = material
        view.blendingMode = blending
        view.isEmphasized = isEmphasized
        // SwiftUI 的 clipShape 对 NSViewRepresentable 不总是生效，
        // 这里在 layer 上再兜一次底，圆角绝不溢出。
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = cornerRadius > 0
    }
}

// MARK: - borderedBackground
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

// MARK: - Glass surface
/// A rounded/capsule glass fill. On macOS 15 we use the system material
/// (the public fallback path for older OS versions).
struct GlassSurface<S: InsettableShape>: View {
    let shape: S
    var tintOpacity: CGFloat = 0.10

    var body: some View {
        ZStack {
            shape.fill(.ultraThinMaterial)
            // Black/white tint layer — BlurView.swift:454-458 updateTintColor.
            shape.fill(Color.primary.opacity(tintOpacity * 0.15))
        }
    }
}

// MARK: - Container glass shell (轨道壳)
/// **壳只做两件事：让桌面透上来、给一个“到此为止”的边。**
///
/// 上一版这里最后一行是 `.opacity(0.55)` —— 那是对**整棵内容树**降透明度，
/// 卡片、文字、图标一起变成 55% 不透明的灰，这才是“整体发灰”的真凶。
/// 现在：
///  - 真玻璃（`VibrancyView` + `.behindWindow`）负责“透”，不靠 alpha 模拟；
///  - 一层极淡的染色负责“定形”，避免玻璃在花哨桌面上糊成一片；
///  - 边缘只剩一条 1pt、opacity≈0.10 的高光 —— 淡到几乎看不见（用户口径）。
struct ContainerGlass<Content: View>: View {
    let cornerRadius: CGFloat
    let content: Content

    init(
        cornerRadius: CGFloat = StationMetrics.containerRadius,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        content
            .background {
                ZStack {
                    VibrancyView(
                        material: StationMetrics.shellMaterial,
                        blending: .behindWindow,
                        cornerRadius: cornerRadius
                    )
                    // 极淡染色：不是“半透明遮罩”，是给玻璃一个色温。
                    shape.fill(Color.primary.opacity(StationMetrics.shellTint))
                    shape.strokeBorder(
                        StationMetrics.shellRimGradient,
                        lineWidth: StationMetrics.borderWidth
                    )
                }
                .clipShape(shape)
            }
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
