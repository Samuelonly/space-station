import AppKit
import Foundation

/// Content kind used by the Action registry and prediction (HTML §21.7).
/// The prototype uses a `c.type` string (text/url/image/...); we derive it from
/// the `contents: [HistoryItemContent]` UTI values instead of storing a
/// duplicate field. Pure function → independently testable.
enum ClipKind: String, Sendable, CaseIterable {
    case text, url, image, video, file, code, note

    var cnLabel: String {
        switch self {
        case .text: return "文本"
        case .url: return "链接"
        case .image: return "图片"
        case .video: return "视频"
        case .file: return "文件"
        case .code: return "代码"
        case .note: return "笔记"
        }
    }

    /// Prototype FILTERS glyphs (html:1692-1693) — used by the All▾ dropdown.
    var symbol: String {
        switch self {
        case .text: return "📝"
        case .url: return "🔗"
        case .image: return "🖼"
        case .video: return "▶"
        case .file: return "📁"
        case .code: return "⌘"
        case .note: return "⭐"
        }
    }

    /// Derive from the stored UTI types + text payload. Order matters: images
    /// and files are structural; code/url are detected from the plain text.
    static func derive(types: [String], text: String?) -> ClipKind {
        let set = Set(types)
        let imageTypes: Set<String> = ["public.png", "public.tiff", "public.jpeg", "public.heic", "public.gif", "public.bmp"]
        let videoTypes: Set<String> = ["public.mpeg-4", "com.apple.quicktime-movie", "org.webmproject.webm", "public.movie"]
        if !set.isDisjoint(with: videoTypes) { return .video }
        if !set.isDisjoint(with: imageTypes) { return .image }
        if set.contains("public.file-url") { return .file }

        let body = text ?? ""
        if let url = firstURL(in: body), url.absoluteString == body.trimmingCharacters(in: .whitespacesAndNewlines) {
            return .url
        }
        if looksLikeCode(body) { return .code }
        return .text
    }

    /// First http(s) URL in a string. Used by both kind detection and purify.
    static func firstURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.firstMatch(in: text, range: range)?.url
    }

    private static func looksLikeCode(_ text: String) -> Bool {
        let markers = ["func ", "let ", "const ", "class ", "import ", "def ", "function ", "#include", "struct ", "var ", "return ", "public ", "interface ", "import \"", "package "]
        let sample = text.prefix(600)
        return markers.contains { sample.contains($0) } || sample.contains("{\n") || sample.contains(";\n")
    }
}
