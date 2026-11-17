import AppKit
import Foundation

// Panel-local keyboard flow (HTML §21.9 / §19.3, prototype lines 2690-2769).
// Global hotkey registration is intentionally avoided (§21.5.5); these hotkeys
// are all "panel open + selected
// item" operations, so a local keyDown monitor on the key panel is the faithful
// and permission-free equivalent. Returning nil from the monitor consumes the
// key; returning the event lets the system / focused control handle it.
//
// The keymap is the single source of truth; every match goes through
// HotkeyStore so rebinding takes effect immediately (§19.4).

@MainActor
final class KeyboardRouter {
    static let shared = KeyboardRouter()

    private var monitor: Any?
    private weak var state: StationState?

    /// Install once at launch. All reads are gated on `panel.isPresented`
    /// through `isPanelOpen`, so hotkeys never fire while the panel is closed.
    func install(state: StationState, isPanelOpen: @escaping () -> Bool) {
        self.state = state
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event, isPanelOpen: isPanelOpen)
        }
    }

    private func handle(_ event: NSEvent, isPanelOpen: () -> Bool) -> NSEvent? {
        // Recording mode: the settings window owns keys while capturing a combo.
        if let state, state.isRecordingHotkey { return event }

        let aux = AuxPanel.shared
        let auxOpen = aux.isOpen
        // M5: once QuickLook is open the rail panel may have resigned key and
        // closed, so hotkeys must stay live while any aux surface is presented.
        guard isPanelOpen() || auxOpen else { return event }

        let store = HotkeyStore.shared
        // §17.3: hotkeys act on the same filtered list the rail displays, so
        // ⌘1-9 and arrow navigation never pick a card hidden by the All▾ filter.
        let items = state?.visibleItems(from: History.shared.items) ?? History.shared.items

        // Escape closes the topmost aux surface (QuickLook / Split / Mini Finder),
        // matching the prototype's "Esc 关闭" hint. Doesn't need a selection.
        if event.keyCode == 53, auxOpen { // 53 = Escape
            aux.dismiss()
            return nil
        }

        // ⌘1…9 — direct pick from the visible list (wildcard digit slot).
        // Needs the rail panel (items are only meaningful there).
        if isPanelOpen(),
           let index = store.numberedHit(.pick, event: event), index - 1 < items.count {
            let item = items[index - 1]
            state?.selectedID = item.persistentModelID
            Clipboard.shared.copy(item)
            state?.notice = "已取第 \(index) 项"
            return nil
        }

        // Space again while QuickLook is open closes it (prototype toggle).
        // Checked before the selection guard so it works even without one.
        if store.hit(.quick, event: event), aux.isPresenting(AuxPanel.quickLookID) {
            aux.dismiss()
            return nil
        }

        // Every other hotkey needs the rail panel and a selected card.
        guard isPanelOpen() else { return event }
        guard let selectedID = state?.selectedID,
              let item = items.first(where: { $0.persistentModelID == selectedID }) else {
            return nil
        }

        if store.hit(.paste, event: event) {
            // Copy-and-paste: write full item to clipboard, then synthesize ⌘V.
            Clipboard.shared.copy(item)
            Clipboard.shared.paste()
            return nil
        }
        if store.hit(.plain, event: event) {
            Clipboard.shared.copy(item, removeFormatting: true)
            Clipboard.shared.paste()
            return nil
        }
        if store.hit(.undo, event: event) {
            if ClipboardUndo.shared.undo() {
                state?.notice = "Clipboard Undo · 已回退到上一次复制"
            } else {
                state?.notice = "没有更早的剪贴板记录"
            }
            return nil
        }
        if store.hit(.split, event: event) {
            let outcome = ActionExecutor.run(id: "split", item: item)
            CardGridView.present(effect: outcome.effect, edge: state?.edge ?? .saved)
            state?.notice = "\(outcome.result.title) · \(outcome.result.detail)"
            return nil
        }
        if store.hit(.fav, event: event) {
            // Prototype :2774/:2779 — F toggles Favorite on the selected card.
            History.shared.toggleFavorite(item)
            state?.notice = item.isFavorite ? "已收藏到 Favorite ⭐" : "已移回 Clip"
            return nil
        }
        if store.hit(.quick, event: event) {
            // M5: route through runAction (single dispatcher, records prediction
            // hit) then present the single preview module via the shared path.
            let outcome = ActionExecutor.run(id: "quicklook", item: item)
            CardGridView.present(effect: outcome.effect, edge: state?.edge ?? .saved)
            state?.notice = "\(outcome.result.title) · 空格 / Esc 关闭"
            return nil
        }

        // Arrow-key navigation moves the shared selection (prototype :2749-2757).
        if event.keyCode == 123 || event.keyCode == 124 { // left / right
            guard !items.isEmpty else { return nil }
            let current = items.firstIndex(where: { $0.persistentModelID == selectedID }) ?? 0
            let next = event.keyCode == 124
                ? min(items.count - 1, current + 1)
                : max(0, current - 1)
            state?.selectedID = items[next].persistentModelID
            return nil
        }
        if event.keyCode == 125 || event.keyCode == 126 { // down / up (vertical rails)
            guard !items.isEmpty else { return nil }
            let current = items.firstIndex(where: { $0.persistentModelID == selectedID }) ?? 0
            let next = event.keyCode == 126
                ? min(items.count - 1, current + 1)
                : max(0, current - 1)
            state?.selectedID = items[next].persistentModelID
            return nil
        }

        // Plain Enter (no modifiers) copies the selected item (prototype :2758).
        if event.keyCode == 36,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            Clipboard.shared.copy(item)
            state?.notice = "已复制"
            return nil
        }

        return event
    }
}
