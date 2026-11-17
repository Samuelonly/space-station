import Foundation

/// 统一把 chord / LocalShortcutAction 格式化成 UI 可读快捷键文案。
enum ShortcutDisplay {
    /// `cmd+shift+p` → `⇧⌘P`；空 chord 返回 `""`。
    static func label(chord: String) -> String {
        let trimmed = chord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return HotKeyChord.displayString(from: trimmed)
    }

    /// 标题 + 快捷键：`钉住窗口（⇧⌘P）`；无 chord 时仅标题。
    static func tooltip(_ title: String, chord: String) -> String {
        let key = label(chord: chord)
        return key.isEmpty ? title : "\(title)（\(key)）"
    }

    /// 多个可选关闭键：`关闭（⎋ / ⌘W）`
    static func tooltip(_ title: String, chords: [String]) -> String {
        let keys = chords.map(label(chord:)).filter { !$0.isEmpty }
        guard !keys.isEmpty else { return title }
        // 去重保持顺序
        var seen = Set<String>()
        let unique = keys.filter { seen.insert($0).inserted }
        return "\(title)（\(unique.joined(separator: " / "))）"
    }
}
