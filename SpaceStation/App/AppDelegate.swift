import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var stationState = StationState()
    private var panel: FloatingPanel<StationPanel>!

    @objc private lazy var statusItem: NSStatusItem = {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.behavior = .removalAllowed
        statusItem.button?.image = Self.icon(for: .normal)
        statusItem.button?.imagePosition = .imageLeft
        // Right-click must also reach our action so we can open Settings
        // (self-developed; right-click handler is our addition, §21.10).
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.target = self
        statusItem.button?.action = #selector(performStatusItemClick)
        Self.applyPillBackground(statusItem.button)
        return statusItem
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = statusItem

        panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: stationState.edge.panelSize),
            identifier: "com.samuelonly.spacestation.panel",
            statusBarButton: statusItem.button,
            stationState: stationState
        ) {
            StationPanel()
        }

        // M4: panel-local keyboard flow. Gated on the panel actually being open.
        KeyboardRouter.shared.install(state: stationState) { [weak self] in
            self?.panel.isPresented ?? false
        }

        // M1 engine startup: storage healing -> load -> capture hook -> timer.
        Task { @MainActor in
            try? Storage.shared.cleanupOrphanedContents()
            try? Storage.shared.removeUnpersistableContents()
            try? Storage.shared.sanitizeTitles()
            try? await History.shared.load()
            History.shared.cleanupExpired() // §17.10 retention (pin-exempt, 0=never)

            // HTML §21.4 pin #1 (capture port). M3: prediction metadata.
            // M4: consume Undo's one-shot suppression (so the restore write
            // doesn't create a card), then record each real clip for Undo.
            Clipboard.shared.onNewCopy { item in
                if ClipboardUndo.shared.shouldSuppressCapture() { return }
                if let prediction = PredictionEngine.predictForCapture(item: item) {
                    item.predictedActionID = prediction.actionID
                    item.predictionReason = prediction.reason
                }
                History.shared.add(item)
                ClipboardUndo.shared.record(item)
            }
            Clipboard.shared.start()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        togglePanel()
        return true
    }

    // MARK: - Status item gestures (modifier logic per §21.10;
    // right-click / pill background are our additions).

    @objc private func performStatusItemClick() {
        let event = NSApp.currentEvent
        // Right-click -> Settings (self-developed).
        if event?.type == .rightMouseUp || event?.type == .rightMouseDown {
            SettingsWindowController.shared.show(state: stationState)
            return
        }

        let modifierFlags = (event?.modifierFlags ?? [])
            .union(NSEvent.modifierFlags)
            .intersection(.deviceIndependentFlagsMask)

        if modifierFlags.contains(.option) {
            SS.ignoreEvents.toggle()
            if modifierFlags.contains(.shift) {
                SS.ignoreOnlyNextEvent = SS.ignoreEvents
            }
            refreshStatusIcon()
            return
        }

        togglePanel()
    }

    @objc private func togglePanel() {
        panel.toggle()
    }

    // MARK: - Icon three states + gray pill contrast (§21.10 self-developed)

    private enum IconState { case normal, paused, ignoreOnce }

    private func refreshStatusIcon() {
        let state: IconState = SS.ignoreEvents
            ? .paused
            : (SS.ignoreOnlyNextEvent ? .ignoreOnce : .normal)
        statusItem.button?.image = Self.icon(for: state)
    }

    private static func icon(for state: IconState) -> NSImage? {
        let name: String
        switch state {
        case .normal:     name = "clipboard"
        case .paused:     name = "clipboard.fill"     // visually distinct paused state
        case .ignoreOnce: name = "clipboard.badge.clock"
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: "Space Station")
    }

    /// Gray pill底 raises contrast against the menu bar without showing counts.
    private static func applyPillBackground(_ button: NSStatusBarButton?) {
        guard let button else { return }
        button.wantsLayer = true
        button.layer?.cornerRadius = 5
        button.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.18).cgColor
    }
}
