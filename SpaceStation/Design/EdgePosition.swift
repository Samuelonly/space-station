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

    /// Portrait card on top/bottom, landscape card on left/right.
    var cardSize: CGSize {
        scrollsHorizontally ? StationMetrics.portraitCard : StationMetrics.landscapeCard
    }

    /// Which screen edge the rail hugs.
    var isVerticalEdge: Bool { !scrollsHorizontally }

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
