import AppKit
import Foundation

/// HTML §21.7.1 — central `runAction` dispatcher. Handlers are registered in a
/// dictionary (id → closure), NOT a hardcoded switch, so new actions plug in.
/// Pure/transport actions really execute (copy, purify, plain, format, reveal,
/// open link, Split); cloud/demo ones return a clear "pending" result. This
/// mirrors the CopyCore lesson: behavior lives in a testable layer, UI only calls it.
@MainActor
enum ActionExecutor {
    /// Result shown by the UI (M3 uses a compact toast/panel; M5 expands it).
    struct Result: Sendable {
        let title: String
        let detail: String
        let copiableText: String?
    }

    /// Side effects the UI must perform (open a panel/window) after runAction.
    /// Consumed synchronously on @MainActor; carries a non-Sendable @Model item,
    /// so intentionally NOT Sendable (never crosses an actor boundary).
    enum Effect {
        case split(HistoryItem)          // open Split field for this card
        case miniFinder([URL])           // open Mini Finder at these URLs
        case quickLook(HistoryItem)      // M5: single preview module
        case purified(HistoryItem, String) // §17.6: purified link overlay (one button)
        case none
    }

    struct Outcome {
        let result: Result
        let effect: Effect
    }

    /// Callback used by handlers that need the UI to present something.
    static func run(id: String, item: HistoryItem) -> Outcome {
        PredictionEngine.recordHit(id)
        if let handler = handlers[id] {
            return handler(item)
        }
        return Outcome(
            result: Result(title: ActionRegistry.byID[id]?.label ?? id,
                           detail: "规格占位 · 真机接系统 API", copiableText: nil),
            effect: .none
        )
    }

    // MARK: - Handler registry
    private static let handlers: [String: (HistoryItem) -> Outcome] = [
        "copyall": { item in
            // Reuse copy(item) so all representations + source marker
            // are preserved — don't flatten to string.
            Clipboard.shared.copy(item)
            let text = item.text ?? item.title
            return Outcome(result: Result(title: "已复制", detail: text.shortened(to: 60), copiableText: text), effect: .none)
        },
        "plain": { item in
            let plain = (item.text ?? item.title)
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            Self.writePlain(plain)
            return Outcome(result: Result(title: "去格式纯文本", detail: plain.shortened(to: 80), copiableText: plain), effect: .none)
        },
        "format": { item in
            let raw = item.text ?? ""
            var out = raw
            if let data = raw.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
                out = String(data: pretty, encoding: .utf8) ?? raw
            }
            return Outcome(result: Result(title: "格式化 / 压缩", detail: out.shortened(to: 120), copiableText: out), effect: .none)
        },
        "transform": { item in
            let out = (item.text ?? "").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            return Outcome(result: Result(title: "文本变换", detail: out.shortened(to: 100), copiableText: out), effect: .none)
        },
        "purify": { item in
            let original = item.text ?? ""
            let out = LinkPurifier.purify(original)
            // §17.6: purify writes the cleaned link BACK to the card, so
            // tapping the card itself copies the purified link (not the
            // original tracking URL). Only mutate storage when it changed.
            if out != original, out != original.trimmingCharacters(in: .whitespacesAndNewlines) {
                Self.writeBack(out, to: item)
            }
            return Outcome(
                result: Result(title: "链接净化", detail: out.shortened(to: 120), copiableText: out),
                effect: .purified(item, out)
            )
        },
        "extractlinks": { item in
            let out = LinkPurifier.extractLinks(item.text ?? "").joined(separator: "\n")
            return Outcome(result: Result(title: "提取全部链接", detail: out.shortened(to: 120), copiableText: out), effect: .none)
        },
        "split": { item in
            Outcome(result: Result(title: "Split 大爆炸", detail: "点一块复制 · 拖一块进目标 App", copiableText: nil),
                    effect: .split(item))
        },
        "codechunk": { item in
            Outcome(result: Result(title: "按代码块切", detail: "Split 智能粒度", copiableText: nil), effect: .split(item))
        },
        "flavor": { item in
            Outcome(result: Result(title: "切换另一种表示", detail: "同一 Clip 的多 flavor", copiableText: nil), effect: .none)
        },
        "folder": { item in
            Outcome(result: Result(title: "打开文件夹", detail: "Mini Finder", copiableText: nil),
                    effect: .miniFinder(item.fileURLs))
        },
        "reveal": { item in
            let urls = item.fileURLs
            if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            return Outcome(result: Result(title: "在 Finder 中显示", detail: urls.first?.lastPathComponent ?? "无文件", copiableText: nil), effect: .none)
        },
        "openwith": { item in
            let url = ClipKind.firstURL(in: item.previewableText)
            if let url, url.scheme != nil { NSWorkspace.shared.open(url) }
            return Outcome(result: Result(title: "预测目标 App", detail: url?.absoluteString ?? "无可打开内容", copiableText: nil), effect: .none)
        },
        "quicklook": { item in
            Outcome(result: Result(title: "超级 Quick Look", detail: "只读预览 · 一键复制 · 空格关闭", copiableText: nil), effect: .quickLook(item))
        },
        "ocr": { item in
            // M1 HistoryItem.generateTitle already runs Vision OCR; reuse it.
            let text = item.title.isEmpty ? "（未识别到文字）" : item.title
            return Outcome(result: Result(title: "OCR 提取文字", detail: text.shortened(to: 120), copiableText: text), effect: .none)
        },
        "otp": { item in
            let code = item.text?.range(of: #"\b\d{4,8}\b"#, options: .regularExpression).map { String(item.text![$0]) }
            return Outcome(result: Result(title: "验证码", detail: code ?? "未识别到验证码 · 60 秒策略见 §16", copiableText: code), effect: .none)
        },
        "favorite": { item in
            // §8: Clip card → Favorite cabin (and back). Permanent, no new card.
            History.shared.toggleFavorite(item)
            let nowFavorite = item.isFavorite
            return Outcome(
                result: Result(title: nowFavorite ? "已收藏到 Favorite ⭐" : "已移回 Clip",
                               detail: nowFavorite ? "永久保存 · 不受过期影响" : "回到剪贴板流",
                               copiableText: nil),
                effect: .none
            )
        }
    ]

    /// §17.6: persist the purified URL back onto the card's string
    /// representation. Tap-to-copy then yields the cleaned link. Other
    /// representations (RTF/HTML/image) are left intact — only the `.string`
    /// slot is rewritten, matching "同一 Clip 多表示" (§21.7.3).
    private static func writeBack(_ purified: String, to item: HistoryItem) {
        let data = purified.data(using: .utf8)
        let stringType = NSPasteboard.PasteboardType.string.rawValue
        if let slot = item.contents.first(where: { $0.type == stringType }) {
            slot.value = data
        } else {
            item.contents.append(HistoryItemContent(type: stringType, value: data))
        }
        item.title = purified
        let context = Storage.shared.context
        context.processPendingChanges()
        try? context.save()
    }

    /// Write a derived plain string to the system clipboard without going
    /// through the History capture path (avoids a new card for the result).
    private static func writePlain(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }
}

/// Pure link helpers (independently testable; prototype doPurify / extractlinks).
enum LinkPurifier {
    static func purify(_ text: String) -> String {
        guard let url = ClipKind.firstURL(in: text), var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return text
        }
        let tracking = ["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "tag", "ref", "spm", "qid", "fbclid", "gclid"]
        comps.queryItems = comps.queryItems?.filter { !tracking.contains($0.name.lowercased()) }
        return comps.string ?? text
    }

    static func extractLinks(_ text: String) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).compactMap { $0.url?.absoluteString }
    }
}
