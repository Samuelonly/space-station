import AppKit
import SwiftUI

/// HTML §18.5 / §21.7.4 — four-edge docking. No competitor ships left/right
/// vertical-scroll, so this is our own logic: four edges share ONE StationCard
/// render; only the container's scroll axis + card aspect ratio flip.
enum EdgePosition: String, CaseIterable, Sendable {
    case top, bottom, left, right

    /// top/bottom → horizontal rail; left/right → vertical rail.
    var scrollsHorizontally: Bool {
        switch self {
        case .top, .bottom: return true
        case .left, .right: return false
        }
    }

    /// 卡的比例**随边反转**：顶/底（横排）→ 4:3 横版；左/右（纵排）→ 3:4 竖版。
    var cardSize: CGSize {
        scrollsHorizontally ? StationMetrics.horizontalCard : StationMetrics.verticalCard
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
            guard let raw = ud.string(forKey: storageKey),
                  let edge = EdgePosition(rawValue: raw) else { return .top }
            return edge
        }
        set { ud.set(newValue.rawValue, forKey: storageKey) }
    }

    /// Panel size derived from the rail direction: horizontal rails are wide &
    /// short, vertical rails are narrow & tall. Padding leaves room for the
    /// glass container shell + inset.
    var panelSize: NSSize {
        let card = cardSize
        let outer = StationMetrics.inset * 2
            + StationMetrics.innerPadding * 2
            + StationMetrics.dockStyleOuter * 2
        if scrollsHorizontally {
            // One card tall + a little breathing room for the rim/gradient.
            return NSSize(width: 780, height: card.height + outer + 12)
        } else {
            return NSSize(width: card.width + outer + 12, height: 640)
        }
    }
}
