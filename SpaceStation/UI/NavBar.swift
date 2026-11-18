import SwiftUI

/// HTML §17.3 / §8 — the four-slot navigation bar: `Clip | Favorite | mini | +`.
/// The first three are real tabs; the 4th is a `+` BUTTON (HTML §966: "第四个
/// 不是 tab，是 +"), shown only on Favorite (§701) — it opens the note composer
/// for §8(b) "Favorite 页签 → + → 直接打字创建笔记卡". `mini` is lowercase on
/// purpose (§965: 让用户好奇再点开) and filters Favorite to folder cards.
///
/// **轴向（2026-11-18）**：轨道在顶部/底部时横向排一行；轨道贴在左/右时，
/// 站体只有 ~208 宽，横排会把 `Clip` / `Favorite` 挤成两行（用户截图里就是
/// 那两个断词）。所以纵向轨道改成**单列**，每个 tab 一整行。
struct NavBar: View {
    @Bindable var state: StationState
    var axis: Axis = .horizontal

    var body: some View {
        Group {
            if axis == .horizontal {
                HStack(spacing: 4) {
                    tab(.clip, label: "Clip", symbol: "tray")
                    tab(.favorite, label: "Favorite", symbol: "star")
                    tab(.mini, label: "mini", symbol: "folder")
                    plusButton
                }
            } else {
                VStack(spacing: 3) {
                    tab(.clip, label: "Clip", symbol: "tray")
                    tab(.favorite, label: "Favorite", symbol: "star")
                    tab(.mini, label: "mini", symbol: "folder")
                    plusButton
                }
            }
        }
        .animation(StationMetrics.gridAnimation, value: state.activeTab)
    }

    /// §701 / §966: `+` belongs to Favorite only, and is an action
    /// (author a note), never a state tab.
    @ViewBuilder
    private var plusButton: some View {
        if state.activeTab == .favorite {
            Button { openComposer() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.accentColor)
                    if axis == .vertical {
                        Text("新笔记").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .frame(maxWidth: axis == .vertical ? .infinity : nil,
                       alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("新建笔记卡（Favorite）")
            .transition(.scale.combined(with: .opacity))
        }
    }

    private func tab(_ tab: StationState.StationTab, label: String, symbol: String) -> some View {
        let active = state.activeTab == tab
        let stacked = axis == .vertical
        return Button {
            withAnimation(StationMetrics.gridAnimation) {
                state.activeTab = tab
                state.selectedID = nil
                state.filterKind = nil
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10))
                // 单行、不换行：宁可截断也不许断成两行（断词比截断难看十倍）。
                Text(label)
                    .font(.system(size: 11, weight: active ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if stacked { Spacer(minLength: 0) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, stacked ? 4 : 3)
            // 纵向轨道：整行可点、整行高亮，像侧栏；横向轨道：胶囊包住文字。
            .frame(maxWidth: stacked ? .infinity : nil, alignment: .leading)
            .background(
                Capsule().fill(active ? Color.accentColor.opacity(0.22) : Color.clear)
            )
            .overlay(
                Capsule().strokeBorder(Color.primary.opacity(active ? 0.18 : 0.06), lineWidth: 1)
            )
            .foregroundStyle(active ? Color.primary : Color.secondary)
            .contentShape(Capsule())
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
