import SwiftUI

/// HTML §17.3 / §8 — the four-slot navigation bar: `Clip | Favorite | mini | +`.
/// The first three are real tabs; the 4th is a `+` BUTTON (HTML §966: "第四个
/// 不是 tab，是 +"), shown only on Favorite (§701) — it opens the note composer
/// for §8(b) "Favorite 页签 → + → 直接打字创建笔记卡". `mini` is lowercase on
/// purpose (§965: 让用户好奇再点开) and filters Favorite to folder cards.
///
/// **轴向（2026-11-18 第二次修正）**：纵向轨道不再“把文字竖着排”——
/// 竖排文字本身就是一种错误信号，用户会读成“这个栏是收起的”。
/// 现在纵向 = **44pt 纯图标侧栏**（macOS Sidebar 的做法），文字全部退进 tooltip。
/// 横向轨道照旧一行图标 + 文字，因为水平方向排文字是正常的。
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
                VStack(spacing: 2) {
                    tab(.clip, label: "Clip", symbol: "tray")
                    tab(.favorite, label: "Favorite", symbol: "star")
                    tab(.mini, label: "mini", symbol: "folder")
                    plusButton
                }
                .frame(width: StationMetrics.sidebarWidth)
            }
        }
        .animation(StationMetrics.gridAnimation, value: state.activeTab)
    }

    private var iconOnly: Bool { axis == .vertical }

    /// §701 / §966: `+` belongs to Favorite only, and is an action
    /// (author a note), never a state tab.
    @ViewBuilder
    private var plusButton: some View {
        if state.activeTab == .favorite {
            Button { openComposer() } label: {
                if iconOnly {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: StationMetrics.sidebarWidth - 8, height: 26)
                } else {
                    HStack(spacing: 5) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                }
            }
            .buttonStyle(.plain)
            .help("新建笔记卡（Favorite）")
            .transition(.scale.combined(with: .opacity))
        }
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
            if iconOnly {
                // 纯图标：整格 36×26，选中只换底与字重，不换尺寸（避免点击位移）。
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? Color.primary : Color.secondary)
                    .frame(width: StationMetrics.sidebarWidth - 8,
                           height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(active ? Color.accentColor.opacity(0.16) : Color.clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                HStack(spacing: 5) {
                    Image(systemName: symbol).font(.system(size: 10))
                    Text(label)
                        .font(.system(size: 11, weight: active ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
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
                .contentShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .help(label)
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
