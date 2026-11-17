import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// M2 grid rail + M3 content wiring. Design logic from DockDoor
/// CardGridScrollView.swift:322-347; SwiftUI ScrollView + system damping.
/// All four edges share StationCard; only the scroll axis flips. M3 adds:
/// ActionExecutor dispatch, multi-representation cycling (no new card), and
/// Split / MiniFinder effect presentation. M4 lifts selection into StationState
/// so the keyboard router and the cards share one selected item.
struct CardGridView: View {
    let edge: EdgePosition
    @Bindable var history: History
    /// Shared selection: the keyboard router (outside SwiftUI) and the card
    /// grid must read/write the same selected card (M4 §21.9).
    @Bindable var stationState: StationState

    /// Per-card active representation index. Cycling this NEVER creates a new
    /// HistoryItem — only changes which `contents[]` entry is displayed (§21.7.3).
    @State private var flavorIndex: [PersistentIdentifier: Int] = [:]
    @State private var actionResult: ActionExecutor.Result?
    @State private var isDropTargeted = false

    /// §9 滚动几何：offset/content/viewport（沿实际滚动轴），驱动边缘指示器显隐。
    private struct RailGeometry: Equatable {
        var offset: CGFloat = 0
        var content: CGFloat = 0
        var viewport: CGFloat = 0
    }
    @State private var railGeometry = RailGeometry()
    /// §9: 持有底层 NSScrollView 供点击翻页。
    @State private var scrollBox = ScrollBox()

    private var allItems: [HistoryItem] { history.items }
    /// §8: cards in the current tab, before the All▾ filter. Used for the
    /// FilterBar counts and for distinguishing "empty cabin" from "no filter hit".
    private var tabItems: [HistoryItem] { stationState.items(forTab: stationState.activeTab, from: allItems) }
    /// §17.3 + §8: the rail shows only cards in this tab matching the filter.
    private var items: [HistoryItem] { stationState.visibleItems(from: allItems) }

    var body: some View {
        ContainerGlass(cornerRadius: StationMetrics.containerRadius) {
            VStack(spacing: 4) {
                NavBar(state: stationState)
                FilterBar(state: stationState, items: tabItems)
                Group {
                    if tabItems.isEmpty { cabinEmpty }        // this cabin has no cards yet
                    else if items.isEmpty { filteredEmpty }   // filter matched nothing
                    else { rail }
                }
            }
            .padding(StationMetrics.inset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // §8 (c): drag a file/folder onto the station → a Favorite card. A
        // folder becomes a real Mini Finder card; plain files a Favorite card.
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
            return true
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: StationMetrics.containerRadius, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.08))
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if let text = feedbackText {
                Text(text)
                    .font(.system(size: 10))
                    .padding(6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear {
                        Task {
                            try? await Task.sleep(nanoseconds: 2_400_000_000)
                            withAnimation {
                                self.$actionResult.wrappedValue = nil
                                self.stationState.notice = nil
                            }
                        }
                    }
            }
        }
    }

    /// ActionExecutor result wins; keyboard-driven notice is the fallback.
    private var feedbackText: String? {
        if let actionResult { return "\(actionResult.title) · \(actionResult.detail)" }
        return stationState.notice
    }

    @ViewBuilder
    private var rail: some View {
        ScrollView(edge.scrollsHorizontally ? .horizontal : .vertical) {
            railContent.padding(StationMetrics.inset)
            // §9: 零尺寸探针，拿到 SwiftUI ScrollView 底下的 NSScrollView。
            NSScrollViewCatcher(box: scrollBox).frame(width: 1, height: 1)
        }
        .scrollIndicators(.hidden)
        // §9 + §11: 一条几何流同时驱动「边缘指示器显隐」与「可见卡上报给缩略图缓存」。
        .onScrollGeometryChange(for: RailGeometry.self, of: { geo in
            edge.scrollsHorizontally
                ? RailGeometry(offset: geo.contentOffset.x,
                               content: geo.contentSize.width,
                               viewport: geo.bounds.size.width)
                : RailGeometry(offset: geo.contentOffset.y,
                               content: geo.contentSize.height,
                               viewport: geo.bounds.size.height)
        }, action: { _, new in
            railGeometry = new
            reportVisibleCards(geometry: new)
        })
        .mask {
            LinearGradient(
                colors: [.clear, .black, .black, .clear],
                startPoint: edge.scrollsHorizontally ? .leading : .top,
                endPoint: edge.scrollsHorizontally ? .trailing : .bottom
            )
        }
        // §9: 非可拖、0.55 透明、仅在对应方向还有内容时出现的翻页提示。
        .overlay(alignment: edge.scrollsHorizontally ? .leading : .top) {
            if canScrollBackward {
                EdgeChevron(symbol: edge.scrollsHorizontally
                            ? EdgeIndicatorIcon.leading : EdgeIndicatorIcon.upward,
                            axis: -1, box: scrollBox, horizontal: edge.scrollsHorizontally)
            }
        }
        .overlay(alignment: edge.scrollsHorizontally ? .trailing : .bottom) {
            if canScrollForward {
                EdgeChevron(symbol: edge.scrollsHorizontally
                            ? EdgeIndicatorIcon.trailing : EdgeIndicatorIcon.downward,
                            axis: 1, box: scrollBox, horizontal: edge.scrollsHorizontally)
            }
        }
    }

    /// §9: 该方向还有内容才显示（2pt 容差，规避浮点抖动）。
    private var canScrollBackward: Bool { railGeometry.offset > 2 }
    private var canScrollForward: Bool {
        railGeometry.offset + railGeometry.viewport < railGeometry.content - 2
    }

    /// §11: 把当前可见卡的位图 key 上报缓存，使滑出视野的条目进入 10 秒淘汰计时。
    /// 用几何估算可见区间（卡尺寸 + 间距），无需懒加载容器；上报是纯状态更新，不触发重绘。
    private func reportVisibleCards(geometry: RailGeometry) {
        let step = (edge.scrollsHorizontally ? edge.cardSize.width : edge.cardSize.height)
            + StationMetrics.itemSpacing
        guard step > 0 else { return }
        let start = max(0, Int((geometry.offset - StationMetrics.inset) / step) - 1)
        let count = Int((geometry.viewport / step).rounded(.up)) + 2
        let range = start..<min(items.count, start + count)
        let keys = range.compactMap { i -> String? in
            guard let data = items[i].imageData else { return nil }
            return ThumbnailCache.key(forData: data)
        }
        ThumbnailCache.shared.markVisible(keys)
    }

    @ViewBuilder
    private var railContent: some View {
        if edge.scrollsHorizontally {
            HStack(alignment: .top, spacing: StationMetrics.itemSpacing) { cards }
        } else {
            VStack(alignment: .leading, spacing: StationMetrics.itemSpacing) { cards }
        }
    }

    private var cards: some View {
        ForEach(items, id: \.persistentModelID) { item in
            StationCard(
                item: item,
                size: edge.cardSize,
                isSelected: stationState.selectedID == item.persistentModelID,
                onSelect: { stationState.selectedID = item.persistentModelID },
                onPaste: { Clipboard.shared.copy(item) },
                onAction: { run(actionID: $0, item: item) },
                onFlavor: { cycleFlavor(item) }
            )
        }
    }

    // MARK: - §8 (c) drop-to-Favorite

    private func handleDrop(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                // macOS hands back either a URL or a bookmark Data/NSData.
                var url: URL?
                if let direct = item as? URL { url = direct }
                else if let data = item as? Data {
                    url = try? URL(dataRepresentation: data, relativeTo: nil, isAbsolute: true)
                } else if let data = item as? NSData {
                    url = try? URL(dataRepresentation: data as Data, relativeTo: nil, isAbsolute: true)
                }
                if let url { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            History.shared.addFavoriteFiles(urls)
            let hasFolder = urls.contains { $0.hasDirectoryPath }
            withAnimation {
                stationState.activeTab = hasFolder ? .mini : .favorite
                stationState.notice = "已存入 Favorite · \(urls.count) 项"
            }
        }
    }

    // MARK: - M3 dispatch

    private func run(actionID: String, item: HistoryItem) {
        let outcome = ActionExecutor.run(id: actionID, item: item)
        withAnimation { actionResult = outcome.result }
        Self.present(effect: outcome.effect, edge: edge)
    }

    /// Shared effect presentation — used by both the click path (run above)
    /// and the M4 keyboard path (KeyboardRouter). Keeps one place for anchoring.
    static func present(effect: ActionExecutor.Effect, edge: EdgePosition) {
        switch effect {
        case .split(let target):
            AuxPanel.shared.present(
                identifier: AuxPanel.splitID,
                size: NSSize(width: 440, height: 360),
                anchoredAt: anchorBelowRail(for: edge)
            ) {
                SplitView(item: target, onDone: { AuxPanel.shared.dismiss() })
            }
        case .miniFinder(let urls):
            AuxPanel.shared.present(
                identifier: AuxPanel.miniFinderID,
                size: NSSize(width: 430, height: 320),
                anchoredAt: anchorBelowRail(for: edge)
            ) {
                MiniFinder(urls: urls, onDone: { AuxPanel.shared.dismiss() })
            }
        case .quickLook(let item):
            // M5 single preview module (§21.8). Centered, larger than the rail
            // aux panels; onDone closes via the shared AuxPanel dismiss path.
            AuxPanel.shared.present(
                identifier: AuxPanel.quickLookID,
                size: NSSize(width: 720, height: 520)
            ) {
                QuickLookView(item: item, onDone: { AuxPanel.shared.dismiss() })
            }
        case .purified(_, let url):
            // §17.6: single-button overlay. The cleaned link was already
            // written back to the card; this is only the predicted next step.
            AuxPanel.shared.present(
                identifier: AuxPanel.purifyID,
                size: NSSize(width: 460, height: 210),
                anchoredAt: anchorBelowRail(for: edge)
            ) {
                PurifyView(url: url)
            }
        case .none:
            break
        }
    }

    /// Cycle through this item's representations. Only touches `flavorIndex`,
    /// never History / storage — so no duplicate card is produced.
    private func cycleFlavor(_ item: HistoryItem) {
        let id = item.persistentModelID
        let count = max(1, item.contents.count)
        flavorIndex[id, default: 0] = (flavorIndex[id, default: 0] + 1) % count
        stationState.selectedID = id
        let current = item.contents[flavorIndex[id] ?? 0]
        withAnimation {
            actionResult = ActionExecutor.Result(
                title: "表示 \( (flavorIndex[id] ?? 0) + 1 )/\(count)",
                detail: current.type, copiableText: nil)
        }
    }

    /// Anchor auxiliary panels just below (or beside) the rail.
    static func anchorBelowRail(for edge: EdgePosition) -> NSPoint? {
        guard let screen = NSScreen.main?.visibleFrame else { return nil }
        switch edge {
        case .top:
            return NSPoint(x: screen.midX - 220, y: screen.maxY - edge.panelSize.height - 380)
        case .bottom:
            return NSPoint(x: screen.midX - 220, y: screen.minY + edge.panelSize.height + 20)
        case .left:
            return NSPoint(x: screen.minX + edge.panelSize.width + 20, y: screen.midY - 180)
        case .right:
            return NSPoint(x: screen.maxX - edge.panelSize.width - 460, y: screen.midY - 180)
        }
    }

    /// §8: empty state depends on the active cabin. Clip → clipboard prompt;
    /// Favorite → how to collect; mini → how to mount a folder.
    private var cabinEmpty: some View {
        VStack(spacing: 8) {
            Image(systemName: cabinSymbol)
                .font(.system(size: 28)).foregroundStyle(.secondary)
            Text(cabinTitle).font(.system(size: 12, weight: .medium))
            Text(cabinHint)
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var cabinSymbol: String {
        switch stationState.activeTab {
        case .clip: return "clipboard"
        case .favorite: return "star"
        case .mini: return "folder"
        }
    }
    private var cabinTitle: String {
        switch stationState.activeTab {
        case .clip: return "复制点什么，它会出现在这里"
        case .favorite: return "Favorite 还没东西"
        case .mini: return "mini 是文件夹舱"
        }
    }
    private var cabinHint: String {
        switch stationState.activeTab {
        case .clip: return "⌥-点菜单栏可暂停 · ⌥⇧-点忽略一次"
        case .favorite: return "卡片右上点 ⭐ 收藏 · 点 + 写笔记 · 或拖文件进站体"
        case .mini: return "把一个文件夹拖进站体，这里会出现可点开的 Mini Finder 卡"
        }
    }

    /// §17.3 prototype: "这个舱里没有该类型的 Clip。" — history has cards, but
    /// none match the active filter. Keep the All▾ bar visible so the user can
    /// switch back without losing context.
    private var filteredEmpty: some View {
        VStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 24)).foregroundStyle(.secondary)
            Text("没有该类型的 Clip")
                .font(.system(size: 12, weight: .medium))
            Text("点上方 All 切回全部")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
