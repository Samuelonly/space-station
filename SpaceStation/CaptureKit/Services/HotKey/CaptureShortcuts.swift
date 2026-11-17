import AppKit
import Foundation

/// 轻量快捷键配置：替代 snap-flow 的 SettingsStore 中「面板内局部快捷键」部分。
/// 默认值直接取 LocalShortcutAction.defaultChord，用户自定义可覆盖（UserDefaults 持久化）。
/// 全局热键（HotKeyManager）按 Spec 暂缓，不在此列。
@MainActor
final class CaptureShortcuts {
    static let shared = CaptureShortcuts()

    private let defaults: UserDefaults
    private let key = "ss.capture.localShortcuts"
    private var overrides: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.overrides = (defaults.dictionary(forKey: key) as? [String: String]) ?? [:]
    }

    /// 用户配置或动作的默认 chord。
    func shortcut(for action: LocalShortcutAction) -> String {
        overrides[action.rawValue] ?? action.defaultChord
    }

    func setShortcut(_ chord: String, for action: LocalShortcutAction) {
        overrides[action.rawValue] = chord
        defaults.set(overrides, forKey: key)
    }

    func resetAll() {
        overrides.removeAll()
        defaults.removeObject(forKey: key)
    }

    /// 事件是否匹配该动作的 chord。
    func matches(_ action: LocalShortcutAction, event: NSEvent) -> Bool {
        LocalShortcutMatcher.matches(event, chord: shortcut(for: action))
    }

    /// 已解析（非空）的 chord。
    func resolvedChord(for action: LocalShortcutAction) -> String {
        let chord = shortcut(for: action).trimmingCharacters(in: .whitespacesAndNewlines)
        return chord.isEmpty ? action.defaultChord : chord
    }

    /// 展示文案：`标题（⇧⌘P）`。
    func tooltip(_ title: String, action: LocalShortcutAction) -> String {
        ShortcutDisplay.tooltip(title, chord: resolvedChord(for: action))
    }

    func tooltip(_ title: String, actions: LocalShortcutAction...) -> String {
        ShortcutDisplay.tooltip(title, chords: actions.map { resolvedChord(for: $0) })
    }
}
