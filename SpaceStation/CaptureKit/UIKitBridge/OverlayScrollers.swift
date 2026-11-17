import AppKit
import SwiftUI

/// 强制使用 macOS 叠加式（overlay）滚动条：默认淡出/隐藏，滚动或悬停时再出现。
/// 用于覆盖系统「始终显示滚动条」时的粗 legacy 轨道。
struct OverlayScrollersModifier: ViewModifier {
    func body(content: Content) -> some View {
        // 不能依赖 enclosingScrollView：`.background` 探测视图通常是 ScrollView 的兄弟节点，
        // 不在 NSScrollView 子树内，必须向上/旁支查找。
        content.background(OverlayScrollerConfigurator())
    }
}

extension View {
    /// 优先叠加式细滚动条，静止时弱存在感。
    /// `nonisolated`：`historyListCard` 等 free function 可能在 nonisolated 上下文调用。
    nonisolated func overlayScrollersPreferred() -> some View {
        modifier(OverlayScrollersModifier())
    }
}

private struct OverlayScrollerConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> OverlayScrollerProbeView {
        let view = OverlayScrollerProbeView()
        // 勿用 isHidden：隐藏视图更难参与层级查找；用零尺寸透明视图即可。
        view.alphaValue = 0
        view.onNeedConfigure = { [weak view] in
            guard let view else { return }
            OverlayScrollerApplicator.applyNearest(from: view)
        }
        return view
    }

    func updateNSView(_ nsView: OverlayScrollerProbeView, context: Context) {
        nsView.scheduleConfigure()
    }
}

/// 在挂到窗口 / 布局变化后查找邻近 NSScrollView 并强制 overlay。
private final class OverlayScrollerProbeView: NSView {
    var onNeedConfigure: (() -> Void)?
    private var retryWorkItem: DispatchWorkItem?
    private var styleObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startObservingPreferredStyle()
            scheduleConfigure(retries: 8)
        } else {
            stopObservingPreferredStyle()
            retryWorkItem?.cancel()
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview != nil {
            scheduleConfigure(retries: 6)
        }
    }

    override func layout() {
        super.layout()
        scheduleConfigure(retries: 2)
    }

    func scheduleConfigure(retries: Int = 4) {
        retryWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.onNeedConfigure?()
            // SwiftUI 可能稍后才插入真正的 NSScrollView，短重试几次。
            if retries > 0, OverlayScrollerApplicator.nearestScrollView(from: self) == nil {
                self.scheduleConfigure(retries: retries - 1)
            }
        }
        retryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: work)
    }

    private func startObservingPreferredStyle() {
        guard styleObserver == nil else { return }
        styleObserver = NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onNeedConfigure?()
        }
    }

    private func stopObservingPreferredStyle() {
        if let styleObserver {
            NotificationCenter.default.removeObserver(styleObserver)
            self.styleObserver = nil
        }
    }
}

enum OverlayScrollerApplicator {
    /// 供设置窗等顶层入口在 `onAppear` 时扫一遍。
    static func apply(in root: NSView?) {
        guard let root else { return }
        for scroll in allScrollViews(in: root) {
            apply(to: scroll)
        }
    }

    static func applyNearest(from view: NSView) {
        if let scroll = nearestScrollView(from: view) {
            apply(to: scroll)
        }
        // 同窗扫一遍，避免个别 ScrollView 探测失败仍留 legacy 粗条
        if let root = view.window?.contentView {
            apply(in: root)
        }
    }

    private static func allScrollViews(in root: NSView) -> [NSScrollView] {
        var result: [NSScrollView] = []
        var queue: [NSView] = [root]
        while !queue.isEmpty {
            let node = queue.removeFirst()
            if let scroll = node as? NSScrollView {
                result.append(scroll)
            }
            queue.append(contentsOf: node.subviews)
        }
        return result
    }

    static func nearestScrollView(from view: NSView) -> NSScrollView? {
        if let scroll = view.enclosingScrollView {
            return scroll
        }
        // 常见结构：Hosting 下 ScrollView 与 background 探测视图为兄弟 / 近亲。
        var current: NSView? = view
        while let node = current {
            if let scroll = node as? NSScrollView {
                return scroll
            }
            if let scroll = firstScrollView(in: node) {
                return scroll
            }
            if let parent = node.superview {
                for sibling in parent.subviews where sibling !== node {
                    if let scroll = sibling as? NSScrollView {
                        return scroll
                    }
                    if let scroll = firstScrollView(in: sibling) {
                        return scroll
                    }
                }
            }
            current = node.superview
        }
        return nil
    }

    private static func firstScrollView(in root: NSView) -> NSScrollView? {
        var queue: [NSView] = root.subviews
        var depth = 0
        while !queue.isEmpty, depth < 12 {
            let levelCount = queue.count
            for _ in 0..<levelCount {
                let node = queue.removeFirst()
                if let scroll = node as? NSScrollView {
                    return scroll
                }
                queue.append(contentsOf: node.subviews)
            }
            depth += 1
        }
        return nil
    }

    static func apply(to scroll: NSScrollView) {
        if scroll.scrollerStyle != .overlay {
            scroll.scrollerStyle = .overlay
        }
        if !scroll.autohidesScrollers {
            scroll.autohidesScrollers = true
        }
        scroll.scrollerKnobStyle = .default
        // 必须保留竖向 scroller，否则 overlay 无实体可淡入。
        if !scroll.hasVerticalScroller {
            scroll.hasVerticalScroller = true
        }
        if scroll.hasHorizontalScroller {
            scroll.hasHorizontalScroller = false
        }
        scroll.horizontalScrollElasticity = .none
        scroll.scrollerInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 2)

        if let vertical = scroll.verticalScroller {
            vertical.controlSize = .small
            // legacy 粗轨道时 knobStyle / controlSize 不够；强制走 overlay 绘制路径
            if vertical.scrollerStyle != .overlay {
                vertical.scrollerStyle = .overlay
            }
        }
    }
}
