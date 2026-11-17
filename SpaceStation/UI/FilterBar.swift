import SwiftUI

/// HTML §17.3 — the `All ▾` type filter. There is deliberately NO search box
/// (§17.2): this is a filter dropdown, not a search field. Expanding shows the
/// seven content types with live counts, mirroring the prototype `FILTERS` +
/// `countsFor` (html:1692, 1890). Selection is shared with the keyboard router
/// through StationState.filterKind so the visible list and ⌘1-9 stay in sync.
struct FilterBar: View {
    @Bindable var state: StationState
    let items: [HistoryItem]

    @State private var expanded = false

    private var currentLabel: String { state.filterKind?.cnLabel ?? "All" }
    private var currentIcon: String { state.filterKind?.symbol ?? "◈" }

    private func count(for kind: ClipKind?) -> Int {
        guard let kind else { return items.count }
        return items.filter {
            ClipKind.derive(types: $0.contents.map(\.type), text: $0.text) == kind
        }.count
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(StationMetrics.gridAnimation) { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(currentIcon).font(.system(size: 11))
                    Text(currentLabel).font(.system(size: 11, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9))
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            if state.filterKind != nil {
                Button {
                    withAnimation(StationMetrics.gridAnimation) { state.filterKind = nil }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("显示全部")
            }

            Spacer()

            if state.filterKind != nil {
                Text("\(state.visibleItems(from: items).count) / \(items.count)")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .frame(height: 22)
        .overlay(alignment: .topLeading) {
            if expanded { menu }
        }
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 1) {
            menuRow(nil, icon: "◈", label: "All")
            Divider().padding(.vertical, 3)
            ForEach(ClipKind.allCases, id: \.self) { kind in
                menuRow(kind, icon: kind.symbol, label: kind.cnLabel)
            }
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .shadow(radius: 8, y: 4)
        .frame(width: 150, alignment: .leading)
        .offset(y: 26)
        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
        .zIndex(10)
    }

    private func menuRow(_ kind: ClipKind?, icon: String, label: String) -> some View {
        Button {
            withAnimation(StationMetrics.gridAnimation) {
                state.filterKind = kind
                expanded = false
            }
        } label: {
            HStack(spacing: 8) {
                Text(icon).font(.system(size: 12)).frame(width: 16)
                Text(label).font(.system(size: 11))
                Spacer()
                Text("\(count(for: kind))")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(state.filterKind == kind ? Color.accentColor.opacity(0.25) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
