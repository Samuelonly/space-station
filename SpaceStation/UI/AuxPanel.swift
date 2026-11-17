import AppKit
import SwiftUI

/// Lightweight auxiliary floating panel for M3 Split / Mini Finder (and M5
/// QuickLook). Unlike the main rail panel, this one does NOT close on focus
/// loss — dragging a Split fragment into another app must keep it alive until
/// the user dismisses it. Reused by every auxiliary surface.
@MainActor
final class AuxPanel: NSObject, NSWindowDelegate {
    static let shared = AuxPanel()

    /// Stable identifiers for the aux surfaces. Shared with KeyboardRouter so
    /// "space toggles QuickLook / Escape closes any aux panel" reads one name.
    static let quickLookID = "com.samuelonly.spacestation.quicklook"
    static let splitID = "com.samuelonly.spacestation.split"
    static let miniFinderID = "com.samuelonly.spacestation.minifinder"
    static let purifyID = "com.samuelonly.spacestation.purify"
    static let noteComposerID = "com.samuelonly.spacestation.notecomposer"
    static let translateID = "com.samuelonly.spacestation.translate"

    private var panel: NSPanel?
    private var onClose: (() -> Void)?
    /// Identifier of the currently presented surface, if any (M5 keyboard flow).
    private(set) var activeIdentifier: String?

    var isOpen: Bool { panel != nil }

    func isPresenting(_ identifier: String) -> Bool {
        panel?.identifier?.rawValue == identifier
    }

    func present<Content: View>(
        identifier: String,
        size: NSSize,
        anchoredAt point: NSPoint? = nil,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        dismiss()

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .resizable, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier(identifier)
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.auxiliary, .stationary, .moveToActiveSpace, .fullScreenAuxiliary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = .clear
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        standardButtonsHidden(panel)

        let dismissAction = onDismiss
        panel.contentView = NSHostingView(rootView:
            content()
                .environment(History.shared)
                .environment(\.auxDismiss) { AuxPanel.shared.dismiss(); dismissAction?() }
        )

        let origin = point ?? {
            let screen = NSScreen.main?.visibleFrame ?? .zero
            return NSPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2)
        }()
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()

        self.panel = panel
        self.activeIdentifier = identifier
        self.onClose = onDismiss
    }

    func dismiss() {
        panel?.close()
        panel = nil
        activeIdentifier = nil
        let cb = onClose
        onClose = nil
        cb?()
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === panel {
            panel = nil
            activeIdentifier = nil
        }
    }

    private func standardButtonsHidden(_ panel: NSPanel) {
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
    }
}

// MARK: - Dismiss environment value
private struct AuxDismissKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var auxDismiss: (() -> Void)? {
        get { self[AuxDismissKey.self] }
        set { self[AuxDismissKey.self] = newValue }
    }
}
