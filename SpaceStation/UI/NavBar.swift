import SwiftUI

/// HTML §17.3 / §8 — the four-slot navigation bar: `Clip | Favorite | mini | +`.
/// The first three are real tabs; the 4th is a `+` BUTTON (HTML §966: "第四个
/// 不是 tab，是 +"), shown only on Favorite (§701) — it opens the note composer
/// for §8(b) "Favorite 页签 → + → 直接打字创建笔记卡". `mini` is lowercase on
/// purpose (§965: 让用户好奇再点开) and filters Favorite to folder cards.
struct NavBar: View {
    @Bindable var state: StationState

    var body: some View {
        HStack(spacing: 4) {
            tab(.clip, label: "Clip", symbol: "tray")
            tab(.favorite, label: "Favorite", symbol: "star")
            tab(.mini, label: "mini", symbol: "folder")

            // §701 / §966: `+` belongs to Favorite only, and is an action
            // (author a note), never a state tab.
            if state.activeTab == .favorite {
                Button { openComposer() } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("新建笔记卡（Favorite）")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(StationMetrics.gridAnimation, value: state.activeTab)
    }

    private func tab(_ tab: StationState.StationTab, label: String, symbol: String) -> some View {
        let active = state.activeTab == tab
        return Button {
            withAnimation(StationMetrics.gridAnimation) {
                state.activeTab = tab
                state.selectedID = nil
                state.filterKind = nil
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 10))
                Text(label).font(.system(size: 11, weight: active ? .semibold : .regular))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(active ? Color.accentColor.opacity(0.22) : Color.clear)
            )
            .overlay(
                Capsule().strokeBorder(Color.primary.opacity(active ? 0.18 : 0.06), lineWidth: 1)
            )
            .foregroundStyle(active ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    private func openComposer() {
        AuxPanel.shared.present(
            identifier: AuxPanel.noteComposerID,
            size: NSSize(width: 360, height: 240),
            anchoredAt: CardGridView.anchorBelowRail(for: state.edge)
        ) {
            NoteComposer { title, body in
                History.shared.addNote(title: title, body: body)
                AuxPanel.shared.dismiss()
            }
        }
    }
}
