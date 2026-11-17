import AppKit
import SwiftUI

/// Floating, non-activating panel. M0 keeps only the engine base's window traits:
/// status-bar level, keyable, no traffic lights, auto-close on focus loss.
/// The card shell and content layer arrive in M2/M3.
@MainActor
final class FloatingPanel<Content: View>: NSPanel, NSWindowDelegate {
    private(set) var isPresented = false
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
        NSApp.activate(ignoringOtherApps: true)
        // stationState is the source of truth: a dock-edge change made between
        // init and open (e.g. QA hook or settings) must be reflected here.
        edge = stationState.edge
        applyEdge(edge)
        orderFrontRegardless()
        makeKey()
        isPresented = true
        statusBarButton?.isHighlighted = true
    }

    /// Switch dock edge (M2 four-edge docking). Resizes the panel and repositions
    /// it on the chosen screen edge; live even while the panel is open.
    func setEdge(_ newEdge: EdgePosition) {
        edge = newEdge
        if isPresented { applyEdge(newEdge) }
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
    }

    func windowDidResignKey(_ notification: Notification) {
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
        let margin: CGFloat = 10

        switch edge {
        case .top:
            let anchorX = statusBarButton?.window?.frame.midX ?? screen.midX
            let x = min(max(anchorX - size.width / 2, screen.minX), max(screen.maxX - size.width, screen.minX))
            return NSPoint(x: x, y: screen.maxY - size.height - margin)
        case .bottom:
            let anchorX = statusBarButton?.window?.frame.midX ?? screen.midX
            let x = min(max(anchorX - size.width / 2, screen.minX), max(screen.maxX - size.width, screen.minX))
            return NSPoint(x: x, y: screen.minY + margin)
        case .left:
            return NSPoint(x: screen.minX + margin,
                           y: screen.midY - size.height / 2)
        case .right:
            return NSPoint(x: screen.maxX - size.width - margin,
                           y: screen.midY - size.height / 2)
        }
    }
}
