import AppKit
import SwiftUI

/// HTML §18.5 / §21.7.4 — four-edge docking. No competitor ships left/right
/// vertical-scroll, so this is our own logic: four edges share ONE StationCard
/// render; only the container's scroll axis + card aspect ratio flip.
enum EdgePosition: String, CaseIterable, Sendable {
    case top, bottom, left, right

    /// **开发基准轴 = 顶部横向**（2026-11-18 用户定案）。
    ///
    /// 四条边共用一套 `StationCard`，但**验收只在一条边上做**。理由很实际：
    /// 每轮都要「横的看一眼、竖的看一眼」，等于每轮开两次盲盒——
    /// 改一处布局，两边同时变，出问题时根本分不清是改动错了还是这条边不适用。
    ///
    /// 所以纪律是：
    /// - **基准期**：只改横向、只拍横向、只按横向判「成不成立」；
    /// - **派生期**：横向定稿后，纵向只允许改「由宽度推导出来的那几个数」
    ///   （卡宽、侧栏宽、面板宽），不许在纵向单独调字号/间距/控件形态。
    ///   一旦纵向需要单独调，说明基准里有个假设没被写出来，回去改基准。
    ///
    /// 这条不是文档里的口号，`--snapshot` 不带边时就拍它，L1 也断言它。
    static let developmentBaseline: EdgePosition = .top

    /// top/bottom → horizontal rail; left/right → vertical rail.
    var scrollsHorizontally: Bool {
        switch self {
        case .top, .bottom: return true
        case .left, .right: return false
        }
    }

    /// 卡的比例**由排列方向决定**：哪边是瓶颈就压哪边（见 `StationMetrics`）。
    /// 顶/底（横排）→ 3:4 竖版 90×120；左/右（纵排）→ 4:3 横版 120×90。
    var cardSize: CGSize {
        scrollsHorizontally ? StationMetrics.horizontalCard : StationMetrics.verticalCard
    }

    /// **图片卡：厚度固定，另一维 = 厚度 × 内容比例；撞闸门才收。**
    ///
    /// 这是 DockDoor 的做法（`Window Image Sizing Calculations.swift`），
    /// 但上一版我只抄了「clamp 到 dynamicMaxAspectRatio」这半句，漏掉了更重要的两件：
    ///
    /// 1. **它 clamp 的不是比例，是面板上限**。单卡尺寸走的是
    ///    `width = min(thickness × aspectRatio, maxWidth)`，另有一个 **50pt 最小边**兜底
    ///    （`dynamicSwitcherMinimumImageWidth = 50`）。所以 680×2000 的细长图不是被拉成
    ///    2:3 的卡再 cover（那样必裁一半），而是变成一张 52×120 的窄条，图 fit 进去、
    ///    左右各留 5pt 缝。**它不裁图。**
    ///
    /// 2. **clamp 完就 fit，不是 cover**。卡片形状已经贴合内容，fit 才不会留白；
    ///    先定死形状再 fit 才会变成一条缝。上一版两难是自己造的。
    ///
    /// 所以现在：
    /// - 顶/底（横排）：高度 = 卡高（120），宽度 = 120 × 比例，夹在 [52, 180]；
    /// - 左/右（纵排）：宽度 = 卡宽（120），高度 = 120 / 比例，夹在 [63, 135]。
    ///   纵排的瓶颈是高度，所以这里必须收得比横排更狠——用户原话「左右侧栏高度受限，
    ///   能放的卡片太少，所以它是 4:3 横版」。
    ///
    /// 卡宽不齐**不是缺陷**：DockDoor 的窗口预览就是一排宽窄不一的卡，
    /// 因为每张卡都完整地是自己的内容。等宽卡片只能靠裁切或留白换，
    /// 而这两个正是用户已经否掉的（「局部特写」和「一条缝」）。
    func cardSize(imageAspect: CGFloat?) -> CGSize {
        let base = cardSize
        guard let imageAspect, imageAspect.isFinite, imageAspect > 0 else { return base }

        if scrollsHorizontally {
            let thickness = base.height
            let raw = thickness * imageAspect
            let width = min(max(raw, StationMetrics.cardMinSide),
                            thickness * StationMetrics.cardMaxStretch)
            return CGSize(width: width.rounded(), height: thickness)
        } else {
            let thickness = base.width
            let raw = thickness / imageAspect
            // 纵排的下限比横排宽一点：卡高低于 63 就放不下 Info 行。
            let floor = max(StationMetrics.cardMinSide, base.height * 0.7)
            let height = min(max(raw, floor), thickness * StationMetrics.cardMaxStretch)
            return CGSize(width: thickness, height: height.rounded())
        }
    }

    /// Which screen edge the rail hugs.
    var isVerticalEdge: Bool { !scrollsHorizontally }

    /// 设置页显示名（短、顺口）。
    var cnLabel: String {
        switch self {
        case .top: return "顶部"
        case .bottom: return "底部"
        case .left: return "左侧"
        case .right: return "右侧"
        }
    }

    /// 设置页图标：箭头指向所贴的那条边。
    var symbolName: String {
        switch self {
        case .top: return "arrow.up.to.line"
        case .bottom: return "arrow.down.to.line"
        case .left: return "arrow.left.to.line"
        case .right: return "arrow.right.to.line"
        }
    }

    // MARK: - Preference persistence (UserDefaults, no SPM dependency)
    private static let storageKey = "com.samuelonly.spacestation.dockEdge"
    nonisolated(unsafe) private static let ud = UserDefaults.standard

    static var saved: EdgePosition {
        get {
            // 未存过 → 落在开发基准轴上（顶部）。首次安装的用户也自动在状态栏下方，
            // 先适应产品，而不是被扔到侧边一条谁也不知道的窄缝里。
            guard let raw = ud.string(forKey: storageKey),
                  let edge = EdgePosition(rawValue: raw) else { return developmentBaseline }
            return edge
        }
        set { ud.set(newValue.rawValue, forKey: storageKey) }
    }

    /// 按当前面板尺寸，首屏**完整**放得下的卡数（向下取整，不算被裁的半张）。
    ///
    /// 这条是产品口径的计算机版本：「一屏看得见 5 张」不是一个形容词，
    /// 是 `n × 卡位 + (n-1) × 间距 ≤ 可用长度` 这个不等式。放进 L1 自检，
    /// 以后谁把卡改大、把间距改宽，自检当场就红。
    var firstScreenCapacity: Int {
        let slot = (scrollsHorizontally ? cardSize.width : cardSize.height)
            + StationMetrics.innerPadding * 2
        let spacing = StationMetrics.itemSpacing
        let bleed = StationMetrics.railBleed * 2
        let usable: CGFloat
        if scrollsHorizontally {
            usable = panelSize.width - StationMetrics.inset * 2 - bleed
        } else {
            usable = panelSize.height - StationMetrics.inset * 2
                - StationMetrics.filterRowHeight - 4 - bleed
        }
        guard slot + spacing > 0 else { return 0 }
        return Int(((usable + spacing) / (slot + spacing)).rounded(.down))
    }

    /// Panel size **由“首屏 5 张”反推**，不是先拍一个窗口大小再往里塞卡片。
    ///
    /// 上一版顶/底写死 780 宽，208 的卡一屏只能露出 3 张半——
    /// 用户看到的就是“抽屉里翻东西”。现在宽度是算出来的：
    ///   5 × (卡宽 + 卡呼吸 12) + 4 × 间距 12 + 两侧 inset 24
    var panelSize: NSSize {
        let card = cardSize
        let n = CGFloat(StationMetrics.firstScreenCards)
        let gaps = CGFloat(StationMetrics.firstScreenCards - 1)
        // 每张卡自身的外框（StationCard 在卡体外留 innerPadding 供选中描边呼吸）
        let slotW = card.width + StationMetrics.innerPadding * 2
        let slotH = card.height + StationMetrics.innerPadding * 2
        let pad = StationMetrics.inset * 2
        let spacing = StationMetrics.itemSpacing
        let bleed = StationMetrics.railBleed * 2

        if scrollsHorizontally {
            let rail = n * slotW + gaps * spacing
            let height = pad
                + StationMetrics.headerRowHeight + 6
                + slotH + bleed
            return NSSize(width: pad + rail + bleed, height: height)
        } else {
            // 纵向：左侧 44pt 纯图标栏 + 6pt 缝 + 一列卡 + 右侧呼吸。
            let rail = n * slotH + gaps * spacing
            let width = pad + StationMetrics.sidebarWidth + 6 + slotW + 24
            let height = pad
                + StationMetrics.filterRowHeight + 4
                + rail + bleed
            return NSSize(width: width, height: height)
        }
    }
}
