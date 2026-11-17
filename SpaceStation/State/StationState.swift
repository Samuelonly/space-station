import Observation
import SwiftData
import SwiftUI

/// Shared observable UI state for the docking edge and the keyboard-driven
/// selection. AppDelegate drives `edge` so the AppKit window frame and the
/// SwiftUI card orientation stay in lockstep (HTML §18.5 — four edges, one
/// card render, axis flip only). M4 lifts `selectedID` here from CardGridView's
/// local @State so the KeyboardRouter (outside SwiftUI) can read/write the
/// same selection the cards highlight (§21.9 keyboard flow).
@Observable
@MainActor
final class StationState {
    var edge: EdgePosition = .saved

    /// §17.3 / §8: the four-slot nav bar. `compose` is the 4th slot `+` — a
    /// button, not a tab (HTML §966): it is only shown on the Favorite tab and
    /// opens the note composer. mini is a Favorite sub-view of folder cards.
    enum StationTab: String, Sendable {
        case clip, favorite, mini
    }
    var activeTab: StationTab = .clip

    /// Current selected card. Shared truth between the grid UI and hotkeys.
    var selectedID: PersistentIdentifier?

    /// True while the settings / keymap window is recording a new combo. The
    /// KeyboardRouter yields to the recorder in this window (§19.4).
    var isRecordingHotkey = false

    /// One-line feedback produced by keyboard-driven actions (e.g. "已回退").
    /// The panel shows it as a transient toast; M4 §21.9.
    var notice: String?

    /// §17.3 content-type filter (`All ▾`). nil = All. Shared between the
    /// FilterBar UI and the keyboard router so ⌘1-9 / arrow navigation act on
    /// exactly the cards the user sees — no "selected but hidden" mismatch.
    var filterKind: ClipKind?

    /// §8: scope the source list by the active tab before applying the All▾
    /// filter. Single definition shared by UI + hotkeys so "what you see" is
    /// always "what ⌘1-9 / arrows act on".
    ///  - clip     : live flow — not favorited
    ///  - favorite : permanent cabin — all favorited cards (notes/files/clips)
    ///  - mini     : Favorite's folder cards only (§943 Mini Finder 是 Favorite 的一种卡)
    func items(forTab tab: StationTab, from items: [HistoryItem]) -> [HistoryItem] {
        switch tab {
        case .clip: return items.filter { !$0.isFavorite }
        case .favorite: return items.filter { $0.isFavorite }
        case .mini: return items.filter { $0.isFavorite && $0.isFolderCard }
        }
    }

    /// Apply the active filter to a source list. Pure; both UI and hotkeys use
    /// it so there is a single definition of "visible cards".
    func visibleItems(from items: [HistoryItem]) -> [HistoryItem] {
        let tabScoped = self.items(forTab: activeTab, from: items)
        guard let kind = filterKind else { return tabScoped }
        return tabScoped.filter { ClipKind.derive(types: $0.contents.map(\.type), text: $0.text) == kind }
    }
}
