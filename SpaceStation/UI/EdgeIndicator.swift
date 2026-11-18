import AppKit
import SwiftUI

/// HTML §9 边缘指示器 + §12 AppKit 对照（NSImageView + NSTrackingArea）。
/// 半透明 0.55、非可拖、仅在该方向还有内容时显示、点击滚动视口宽度 1/3。
/// 图标可配置：改 `leadingSymbol` / `trailingSymbol` 两个常量即可替换宇航员图标。

/// 可配置图标（§9「EDGE_INDICATOR_ICON_LEFT / RIGHT，改一个变量即可」）。
enum EdgeIndicatorIcon {
    static let leading = "chevron.left"
    static let trailing = "chevron.right"
    static let upward = "chevron.up"
    static let downward = "chevron.down"
    static let pointSize: CGFloat = 10   // §9: 6–12pt；原 11 在 22pt 宽的按钮里偏大
    static let opacity: Double = 0.42    // §9: 半透明；0.55 在卡上太抢眼
    /// 按钮热区。**不能太宽**：这个箭头是浮在卡片上的，22pt 宽会实实在在压掉
    /// 最后一张卡右侧一条（用户截图里那个 `>` 就长在卡上）。
    static let hitWidth: CGFloat = 14
    static let hitHeight: CGFloat = 30
}

/// 持有 SwiftUI ScrollView 底下的 NSScrollView，供点击时做像素级翻页
/// （ScrollPosition 只支持按 id 跳，无法按视口宽度 1/3 滚动）。
final class ScrollBox {
    weak var scrollView: NSScrollView?
}

/// 挂进 rail 内容里的零尺寸探针，拿到 enclosingScrollView。
struct NSScrollViewCatcher: NSViewRepresentable {
    let box: ScrollBox

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { box.scrollView = view.enclosingScrollView }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        // SwiftUI 可能重建底层 NSScrollView；刷新弱引用，避免翻页失效。
        DispatchQueue.main.async { box.scrollView = view.enclosingScrollView }
    }
}

/// 单个边缘提示按钮：0.55 透明、chevron、点击翻 1/3 视口。
/// `axis` 决定朝哪个方向滚（-1 = 向前/left/up，+1 = 向后/right/down）。
struct EdgeChevron: View {
    let symbol: String
    let axis: CGFloat
    let box: ScrollBox
    let horizontal: Bool

    @State private var hovering = false

    var body: some View {
        Button {
            page(direction: axis)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: EdgeIndicatorIcon.pointSize, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: EdgeIndicatorIcon.hitWidth,
                       height: EdgeIndicatorIcon.hitHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(hovering ? 1.0 : EdgeIndicatorIcon.opacity)
        .onHover { hovering = $0 }
        .help(axis < 0 ? "向前翻 1/3" : "向后翻 1/3")
        .accessibilityLabel(axis < 0 ? "向前翻页" : "向后翻页")
    }

    /// 滚动视口宽度（横向）或高度（纵向）的 1/3；到边界时硬停、不回弹（§9/§18.5）。
    private func page(direction: CGFloat) {
        guard let scrollView = box.scrollView else { return }
        let origin = scrollView.contentView.bounds.origin
        let viewport = scrollView.contentView.bounds.size
        let target: NSPoint
        if horizontal {
            target = NSPoint(x: origin.x + direction * viewport.width / 3, y: origin.y)
        } else {
            target = NSPoint(x: origin.x, y: origin.y + direction * viewport.height / 3)
        }
        scrollView.contentView.scroll(to: target)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}
