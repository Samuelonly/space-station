import AppKit
import QuartzCore
import SwiftUI

/// Floating, non-activating panel. M0 keeps only the engine base's window traits:
/// status-bar level, keyable, no traffic lights, auto-close on focus loss.
/// The card shell and content layer arrive in M2/M3.
@MainActor
final class FloatingPanel<Content: View>: NSPanel, NSWindowDelegate {
    private(set) var isPresented = false
    /// 换边动画进行中：这期间窗口被隐藏/失焦都不算“用户收起”，不得触发 close。
    private var isSwitchingEdge = false
    /// 收起 → 换边 → 展开之间的静置时间。
    /// 窗口不可见时改尺寸，SwiftUI 会重排 6 张卡并按新朝向重新取图；
    /// 留一拍再显示，用户看到的就是“直接出现在新位置”，而不是一次可见的抖动。
    private let switchDelay: Duration = .milliseconds(160)
    private let collapseDuration: TimeInterval = 0.12
    private let expandDuration: TimeInterval = 0.14
    /// “收进”时朝屏幕边滑进去的距离（只平移、不改尺寸 —— 不会触发重排）。
    private let collapseSlide: CGFloat = 12
    private let statusBarButton: NSStatusBarButton?
    private var edge: EdgePosition
    private let stationState: StationState

    init(
        contentRect: NSRect,
        identifier: String,
        statusBarButton: NSStatusBarButton?,
        stationState: StationState,
        view: () -> Content
    ) {
        self.statusBarButton = statusBarButton
        self.edge = stationState.edge
        self.stationState = stationState
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .resizable, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.identifier = NSUserInterfaceItemIdentifier(identifier)
        delegate = self
        animationBehavior = .none
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.auxiliary, .stationary, .moveToActiveSpace, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        titlebarSeparatorStyle = .none
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        // **玻璃的先决条件**：窗口必须声明自己不是不透明的。
        // 少了这一行，`NSVisualEffectView` 的 `.behindWindow` 采样会被窗口挡住，
        // 玻璃退化成一块纯色 —— 上一版“看不到桌面”有一半是这里的原因。
        isOpaque = false
        hasShadow = true

        // **面板固定深色外观**（2026-11-18 对齐 HTML）。
        //
        // HTML 原型的整套语言是深色的：站体是深色玻璃、卡是深色玻璃、文字是白色。
        // 之前跟随系统外观，在浅色模式下 `NSVisualEffectView` 直接退化成一层白雾，
        // 白卡 + 白底 = 用户说的「连 HTML 原型都不如」。玻璃要有“透”，背后必须是暗的。
        // 这不是“强制暗黑模式”，是这类常驻工具面板的惯例（DockDoor、Raycast 同款）。
        appearance = NSAppearance(named: .darkAqua)

        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        let root = view()
            .environment(History.shared)
            .environment(stationState)
        contentView = NSHostingView(rootView: root)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeKey: Bool { true }

    func toggle() {
        if isPresented {
            close()
        } else {
            open()
        }
    }

    func open() {
        // 面板重新打开：还没落地的“收起后整理”作废，否则会在用户正在看的时候动手。
        MemoryTidy.cancelPending()
        NSApp.activate(ignoringOtherApps: true)
        // stationState is the source of truth: a dock-edge change made between
        // init and open (e.g. QA hook or settings) must be reflected here.
        edge = stationState.edge
        applyEdge(edge)
        alphaValue = 1
        orderFrontRegardless()
        makeKey()
        isPresented = true
        statusBarButton?.isHighlighted = true
    }

    /// Switch dock edge (M2 four-edge docking).
    ///
    /// **换边必须“收进 → 等 → 在新位置展开”**（用户 2026-11-18 口径）：
    /// 直接改一个可见窗口的尺寸，等于在用户眼前做一次重排（6 张卡 × 新朝向 ×
    /// 缩略图重取），那就是肉眼可见的一顿。拆成三段后，重活全发生在窗口不可见期间。
    ///
    /// 1. **收进**：朝当前贴的屏幕边滑 12pt + 淡出（只平移不改尺寸，不会触发 SwiftUI 重排）；
    /// 2. **静置** `switchDelay`：窗口已 orderOut，此时改尺寸、重新定位、让新朝向布局落地；
    /// 3. **展开**：在新边淡入并 makeKey。
    /// 面板本来就收着的话，没有“收进”可言，直接改尺寸就完事。
    func switchEdge(to newEdge: EdgePosition) {
        guard newEdge != edge else { return }

        guard isPresented, isVisible, !isSwitchingEdge else {
            edge = newEdge
            applyEdge(newEdge)
            return
        }

        isSwitchingEdge = true
        // 换边不是“收起”，不触发行整理（否则用户来回切位置会被反复清缓存）。
        MemoryTidy.cancelPending()

        let slide = Self.slideVector(for: edge, distance: collapseSlide)
        let collapsed = frame.offsetBy(dx: slide.width, dy: slide.height)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = collapseDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
            animator().setFrame(collapsed, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.orderOut(nil)          // 彻底收起，不再吃焦点
                self.alphaValue = 0
                self.edge = newEdge
                self.applyEdge(newEdge)     // 不可见时改尺寸 + 换边定位
                try? await Task.sleep(for: self.switchDelay)
                self.orderFrontRegardless()
                self.makeKey()
                self.isPresented = true
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = self.expandDuration
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    self.animator().alphaValue = 1
                } completionHandler: { [weak self] in
                    Task { @MainActor in self?.isSwitchingEdge = false }
                }
            }
        }
    }

    /// 朝该边“滑进去”的方向向量（屏幕坐标：y 向上）。
    private static func slideVector(for edge: EdgePosition, distance: CGFloat) -> CGSize {
        switch edge {
        case .top:    return CGSize(width: 0, height: distance)
        case .bottom: return CGSize(width: 0, height: -distance)
        case .left:   return CGSize(width: -distance, height: 0)
        case .right:  return CGSize(width: distance, height: 0)
        }
    }

    private func applyEdge(_ edge: EdgePosition) {
        let size = edge.panelSize
        setContentSize(size)
        setFrameOrigin(Self.origin(for: size, edge: edge, statusBarButton: statusBarButton))
    }

    override func close() {
        super.close()
        isPresented = false
        statusBarButton?.isHighlighted = false
        // 收起后安排一次“悄悄整理”（频率门 / 电源门 / 静置门见 MemoryTidy）。
        MemoryTidy.scheduleAfterCollapse()
    }

    func windowDidResignKey(_ notification: Notification) {
        // 换边过程中窗口会被主动 orderOut，这不是用户收起，不能连锁 close。
        guard !isSwitchingEdge else { return }
        close()
    }

    /// HTML §18.5 — position follows the dock edge. Horizontal rails hug
    /// top/bottom (menu-bar anchor X retained on top); vertical rails hug
    /// left/right, vertically centered. Each is clamped into visibleFrame.
    private static func origin(
        for size: NSSize,
        edge: EdgePosition,
        statusBarButton: NSStatusBarButton?
    ) -> NSPoint {
        let screen = NSScreen.main?.visibleFrame ?? .zero

        switch edge {
        case .top:
            // **默认家在状态栏正下方**（用户 2026-11-18：顶部、状态栏下面、磁吸卡位）。
            // visibleFrame.maxY 本来就等于菜单栏下沿，所以这里只留 4pt ——
            // 视觉上是“吸在菜单栏底下”，而不是“浮在屏幕上半部分”。
            let anchorX = statusBarButton?.window?.frame.midX ?? screen.midX
            let x = min(max(anchorX - size.width / 2, screen.minX), max(screen.maxX - size.width, screen.minX))
            return NSPoint(x: x, y: screen.maxY - size.height - 4)
        case .bottom:
            let anchorX = statusBarButton?.window?.frame.midX ?? screen.midX
            let x = min(max(anchorX - size.width / 2, screen.minX), max(screen.maxX - size.width, screen.minX))
            return NSPoint(x: x, y: screen.minY + 4)
        case .left:
            return NSPoint(x: screen.minX + 4,
                           y: screen.midY - size.height / 2)
        case .right:
            return NSPoint(x: screen.maxX - size.width - 4,
                           y: screen.midY - size.height / 2)
        }
    }
}
