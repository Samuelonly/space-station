import AppKit
import Combine
import Foundation

// Swift port of the HTML prototype's keybinding block (§19.4 / §21.9).
// Source: space-station.html lines 2203-2238 (KEY_DEFS / KEYS_LS / loadKeys /
// keyLabel / codeFromEvent / keyHit) and 2690-2715 (record + conflict reject).
//
// Pin changes (documented, same spirit as M1 Support.swift):
//  - localStorage -> UserDefaults (namespaced key, an installed app can't clash)
//  - browser KeyboardEvent -> NSEvent; `e.code` normalization folded into
//    `codeFrom(event:)` so the "Digit1 vs 1" bug (§21.9) cannot recur: macOS
//    `charactersIgnoringModifiers` already yields "1", never "Digit1".
//  - `Number` actions (⌘1…9) use a wildcard digit slot: the stored combo's
//    modifier prefix is the binding, the trailing digit is the item index.
//    This is how §19.3 "前 9 项直选" is expressible at all (prototype only
//    matched ⌘1 literally).

enum HotkeyID: String, CaseIterable, Codable, Identifiable {
    case paste, plain, pick, undo, quick, split, fav, compose, actions

    var id: String { rawValue }
}

/// One row in the settings · keymap panel. Mirrors the prototype's KEY_DEFS.
struct HotkeyDefinition: Identifiable {
    let id: HotkeyID
    let label: String
    let def: String
    let source: String
    let proto: Bool
}

/// Central, mutable, persisted keymap. The single source of truth for both the
/// KeyboardRouter (matching) and SettingsView (editing). Injected via the
/// environment so both see the same @Observable changes.
@MainActor
final class HotkeyStore: ObservableObject {
    static let shared = HotkeyStore()

    /// Order + defaults must match space-station.html:2204-2214 exactly.
    static let definitions: [HotkeyDefinition] = [
        .init(id: .paste,   label: "复制即粘贴",      def: "Alt+Enter",       source: "Maccy / ClipMan", proto: true),
        .init(id: .plain,   label: "无格式粘贴",      def: "Alt+Shift+Enter", source: "Maccy",           proto: true),
        .init(id: .pick,    label: "前 9 项直选",     def: "Meta+1",          source: "Maccy",           proto: true),
        .init(id: .undo,    label: "Clipboard Undo",  def: "Meta+Alt+Z",      source: "ClipBuddy",       proto: true),
        .init(id: .quick,   label: "超级 Quick Look", def: "Space",           source: "自有",            proto: false),
        .init(id: .split,   label: "Split 大爆炸",    def: "KeyS",            source: "自有",            proto: false),
        .init(id: .fav,     label: "Favorite 收藏",   def: "KeyF",            source: "自有",            proto: false),
        .init(id: .compose, label: "模拟复制",        def: "KeyN",            source: "自有（原型专用）", proto: false),
        .init(id: .actions, label: "Action 注册表",   def: "KeyA",            source: "自有",            proto: false)
    ]

    nonisolated(unsafe) private let ud = UserDefaults.standard
    private let storageKey = "com.samuelonly.spacestation.keymap"
    private(set) var map: [HotkeyID: String] = [:]

    init() { load() }

    // MARK: - Persistence (prototype loadKeys, :2216-2221)

    func load() {
        var saved: [String: String] = [:]
        if let dict = ud.dictionary(forKey: storageKey) as? [String: String] {
            saved = dict
        }
        var resolved: [HotkeyID: String] = [:]
        for def in Self.definitions {
            resolved[def.id] = saved[def.id.rawValue] ?? def.def
        }
        map = resolved
    }

    func combo(for id: HotkeyID) -> String {
        map[id] ?? Self.definitions.first(where: { $0.id == id })?.def ?? ""
    }

    /// Persist a new combo if it doesn't collide with another function.
    /// Returns false (and does not write) on conflict — prototype :2703-2710.
    @discardableResult
    func set(_ combo: String, for id: HotkeyID) -> Bool {
        if let clash = conflict(for: combo, excluding: id) {
            Logger(label: "com.samuelonly.spacestation").info(
                "Keymap conflict: \(combo) already bound to \(clash.rawValue)")
            return false
        }
        map[id] = combo
        var raw: [String: String] = [:]
        for (key, value) in map { raw[key.rawValue] = value }
        ud.set(raw, forKey: storageKey)
        objectWillChange.send()
        return true
    }

    func conflict(for combo: String, excluding id: HotkeyID) -> HotkeyID? {
        Self.definitions.first(where: { $0.id != id && map[$0.id] == combo })?.id
    }

    /// One-tap restore to §19.3 defaults (prototype :2260-2263).
    func resetAll() {
        var resolved: [HotkeyID: String] = [:]
        for def in Self.definitions { resolved[def.id] = def.def }
        map = resolved
        var raw: [String: String] = [:]
        for (key, value) in map { raw[key.rawValue] = value }
        ud.set(raw, forKey: storageKey)
        objectWillChange.send()
    }

    // MARK: - NSEvent -> combo string (prototype codeFromEvent, :2228-2237)

    /// Modifier prefix in the prototype's canonical order: Meta, Alt, Shift, Ctrl.
    static func modifierPrefix(_ flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.command) { parts.append("Meta") }
        if flags.contains(.option) { parts.append("Alt") }
        if flags.contains(.shift) { parts.append("Shift") }
        if flags.contains(.control) { parts.append("Ctrl") }
        return parts.joined(separator: "+")
    }

    /// The key token, normalized so digits are "1"…"9" (never "Digit1").
    static func keyToken(from event: NSEvent) -> String {
        if let chars = event.charactersIgnoringModifiers, let scalar = chars.unicodeScalars.first {
            let ch = Character(scalar)
            if ch.isNumber && chars.count == 1 { return String(ch) }        // "1"…"9"
            if ch == " " { return "Space" }
            if ch == "\r" || ch == "\n" { return "Enter" }
            if ch.isLetter && chars.count == 1 {
                return "Key" + String(ch).uppercased()
            }
        }
        // Arrow keys and function keys have no printable character.
        switch Int(event.keyCode) {
        case 123: return "ArrowLeft"
        case 124: return "ArrowRight"
        case 125: return "ArrowDown"
        case 126: return "ArrowUp"
        case 36:  return "Enter"
        case 49:  return "Space"
        default:  return "\(event.keyCode)"
        }
    }

    static func codeFrom(event: NSEvent) -> String {
        let prefix = modifierPrefix(event.modifierFlags)
        let token = keyToken(from: event)
        return prefix.isEmpty ? token : "\(prefix)+\(token)"
    }

    /// Exact hit (prototype keyHit, :2238).
    func hit(_ id: HotkeyID, event: NSEvent) -> Bool {
        combo(for: id) == Self.codeFrom(event: event)
    }

    /// Wildcard-digit hit for ⌘1…9: the stored combo's modifier prefix must
    /// match and its last token must be a digit slot; the event supplies 1…9.
    /// Returns the 1-based index, or nil.
    func numberedHit(_ id: HotkeyID, event: NSEvent) -> Int? {
        let stored = combo(for: id)
        let pieces = stored.split(separator: "+").map(String.init)
        guard let last = pieces.last, last.count == 1, let firstDigit = last.first, firstDigit.isNumber else {
            return nil
        }
        let storedPrefix = pieces.dropLast().joined(separator: "+")
        guard storedPrefix == Self.modifierPrefix(event.modifierFlags) else { return nil }
        guard let chars = event.charactersIgnoringModifiers,
              chars.count == 1, let ch = chars.unicodeScalars.first.map({ Character($0) }),
              ch.isNumber, let index = Int(String(ch)), (1...9).contains(index) else { return nil }
        return index
    }

    // MARK: - Display label (prototype keyLabel, :2223-2227)

    static func label(for combo: String) -> String {
        combo
            .replacingOccurrences(of: "+", with: " ")
            .replacingOccurrences(of: "Meta", with: "⌘")
            .replacingOccurrences(of: "Alt", with: "⌥")
            .replacingOccurrences(of: "Shift", with: "⇧")
            .replacingOccurrences(of: "Ctrl", with: "⌃")
            .replacingOccurrences(of: "Key", with: "")
            .replacingOccurrences(of: "Enter", with: "↵")
            .replacingOccurrences(of: "Space", with: "空格")
            .replacingOccurrences(of: "Arrow", with: "")
    }
}
