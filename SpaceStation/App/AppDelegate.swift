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
        // Right-click -> context menu (Settings + Capture entry, §阶段三).
        if event?.type == .rightMouseUp || event?.type == .rightMouseDown {
            let menu = NSMenu()
            let capture = NSMenuItem(title: "截图 / 标注", action: #selector(startCapture), keyEquivalent: "")
            capture.target = self
            menu.addItem(capture)
            let captureTranslate = NSMenuItem(title: "截图并原图翻译", action: #selector(startCaptureTranslate), keyEquivalent: "")
            captureTranslate.target = self
            menu.addItem(captureTranslate)
            menu.addItem(NSMenuItem.separator())
            let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: "")
            settings.target = self
            menu.addItem(settings)
            // 直接弹出，避免给 button 挂 menu 后 performClick 再次触发本方法（递归）。
            if let button = statusItem.button {
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
            }
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

    @objc private func openSettings() {
        SettingsWindowController.shared.show(state: stationState)
    }

    /// 阶段三：全屏框选 → 标注 → 入库。截图结果作为图片卡插入 History。
    @objc private func startCapture() {
        Task { @MainActor in
            _ = await CaptureIntegration.captureToHistory()
        }
    }

    /// 阶段三：全屏框选 → 原图 OCR + 翻译 → 磨砂覆盖层展示。
    @objc private func startCaptureTranslate() {
        Task { @MainActor in
            guard let result = await CaptureService.shared.captureRegion() else { return }
            await TranslateOverlayController.shared.translate(image: result.image)
        }
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
