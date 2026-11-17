import AppKit
import Foundation

/// HTML §21.7.2 — two-sided context prediction. Prototype `predict/whyFor/
/// predictApp` (space-station.html:1683-1689, 2059+): score passive actions by
/// rank + content boost + click history, minus a penalty for wildcard actions.
/// "Two-sided" = source app (from the clip) + target context (frontmost app now).
/// Output: predicted Action ID + human-readable reason, stored on the item
/// before入库 (pin #1 capture port).
struct PredictionEngine {
    /// Hit counts survive in memory for the session (prototype `state.actionHits`).
    nonisolated(unsafe) private static var actionHits: [String: Int] = [:]
    private static let lock = NSLock()

    struct Prediction: Sendable {
        let actionID: String
        let score: Int
        let reason: String
    }

    /// Pure scoring of all applicable passive actions, best first.
    static func rank(item: HistoryItem, kind: ClipKind, text: String, sourceApp: String) -> [Prediction] {
        let candidates = ActionRegistry.all.filter { $0.passive && $0.canUse(on: kind) }
        let scored: [Prediction] = candidates.map { action in
            let score = action.rank
                + boost(actionID: action.id, kind: kind, text: text)
                + hits(action.id)
                - (action.types == nil ? 5 : 0)
            return Prediction(actionID: action.id, score: score,
                              reason: reason(actionID: action.id, kind: kind, text: text, sourceApp: sourceApp))
        }
        return scored.sorted { $0.score > $1.score }
    }

    /// Top prediction for the capture port. Frontmost app is the "target side":
    /// if the user is looking at a browser and copies a URL, purify/open rank up.
    @MainActor
    static func predictForCapture(item: HistoryItem) -> Prediction? {
        let types = item.contents.map(\.type)
        let text = item.text ?? ""
        let kind = ClipKind.derive(types: types, text: text)
        let sourceApp = item.application ?? "未知 App"
        var ranked = rank(item: item, kind: kind, text: text, sourceApp: sourceApp)

        // Target side: nudge route/transform actions when the frontmost app
        // suggests an immediate destination. Kept small so source still wins.
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            switch (kind, front) {
            case (.url, let b) where b.contains("safari") || b.contains("chrome") || b.contains("firefox"):
                bump(&ranked, id: "openwith", by: 6)
            case (.code, let b) where b.contains("code") || b.contains("xcode"):
                bump(&ranked, id: "explain", by: 5)
            default: break
            }
        }
        return ranked.first
    }

    /// Side-effect: record a click so it nudges future predictions (prototype
    /// `state.actionHits[id]++` inside runAction).
    static func recordHit(_ actionID: String) {
        lock.lock(); defer { lock.unlock() }
        actionHits[actionID, default: 0] += 1
    }

    static func resetHits() {
        lock.lock(); defer { lock.unlock() }
        actionHits.removeAll()
    }

    // MARK: - internals
    private static func hits(_ id: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return min(20, (actionHits[id] ?? 0) * 7)
    }

    private static func bump(_ list: inout [Prediction], id: String, by: Int) {
        guard let idx = list.firstIndex(where: { $0.actionID == id }) else { return }
        list[idx] = Prediction(actionID: list[idx].actionID, score: list[idx].score + by, reason: list[idx].reason)
        list.sort { $0.score > $1.score }
    }

    private static func boost(actionID: String, kind: ClipKind, text: String) -> Int {
        switch actionID {
        case "ocr": return kind == .image ? 8 : 0
        case "explain": return 6
        case "translate": return text.range(of: "[A-Za-z]{18,}", options: .regularExpression) != nil ? 8 : 0
        case "split": return text.count > 80 ? 10 : 0
        case "purify":
            let lower = text.lowercased()
            if ["t.cn", "bit.ly", "s.click", "dwz.cn", "is.gd"].contains(where: { lower.contains($0) }) { return 14 }
            if ["utm_", "tag=", "ref_", "qid=", "spm="].contains(where: { lower.contains($0) }) { return 8 }
            return 0
        case "openwith":
            switch kind { case .file: return 8; case .url: return 6; case .code: return 5; default: return 0 }
        case "otp": return text.range(of: #"\b\d{4,8}\b"#, options: .regularExpression) != nil ? 25 : -30
        default: return 0
        }
    }

    private static func reason(actionID: String, kind: ClipKind, text: String, sourceApp: String) -> String {
        switch actionID {
        case "ocr": return "图片来自 \(sourceApp) · 系统 Vision 可本地识别"
        case "explain": return "代码块来自 \(sourceApp) · 通常要先知道它在干嘛"
        case "translate": return "长外文来自 \(sourceApp) · 本地翻译够用"
        case "split": return "长文本来自 \(sourceApp) · 通常只要其中一段"
        case "purify":
            let lower = text.lowercased()
            if ["t.cn", "bit.ly", "s.click"].contains(where: { lower.contains($0) }) {
                return "短链来自 \(sourceApp) · 需要先还原"
            }
            return "含追踪参数 · 来自 \(sourceApp)"
        case "openwith": return "类型 \(kind.cnLabel) + 来源 \(sourceApp) + 系统默认打开方式"
        case "otp": return "疑似一次性验证码 · 不该长期留在历史里"
        default: return "类型 \(kind.cnLabel) · 来源 \(sourceApp)"
        }
    }
}
