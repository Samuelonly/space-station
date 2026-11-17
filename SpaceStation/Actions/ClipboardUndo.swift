import AppKit
import Foundation

// Self-developed Clipboard Undo (HTML §19.3 / §21.9, from ClipBuddy).
// The prototype keeps a `CLIP_HISTORY` array of copied strings; ⌘⌥Z pops the
// latest and restores the previous one to the clipboard. Our version stores a
// snapshot of each captured clip (all UTI representations, not just text) so
// undo restores rich content too, and caps the stack at 100.
//
// Re-entrancy: writing the restored value back to NSPasteboard advances
// changeCount, which makes the Maccy capture chain fire `onNewCopy` again.
// `shouldSuppressCapture()` is consumed exactly once at the capture hook so
// the restore neither creates a duplicate card nor records itself as a step.

@MainActor
final class ClipboardUndo {
    static let shared = ClipboardUndo()

    private struct Snapshot {
        let entries: [(type: String, value: Data?)]
        let application: String?
    }

    private var stack: [Snapshot] = []
    private var suppressNextCapture = false
    private let cap = 100

    /// Record a clip that just entered History. Called from the capture hook
    /// AFTER the item has been added, so undo always has the newest state.
    func record(_ item: HistoryItem) {
        let entries = item.contents.map { (type: $0.type, value: $0.value) }
        guard !entries.isEmpty else { return }
        stack.append(Snapshot(entries: entries, application: item.application))
        if stack.count > cap { stack.removeFirst(stack.count - cap) }
    }

    /// Consume the one-shot suppression flag at the capture hook. Returns true
    /// when this capture is our own undo restore and must be ignored.
    func shouldSuppressCapture() -> Bool {
        if suppressNextCapture {
            suppressNextCapture = false
            return true
        }
        return false
    }

    /// ⌘⌥Z — roll back the clipboard to the previous captured clip.
    /// Returns false (with no side effect) when there is nothing to roll back.
    @discardableResult
    func undo() -> Bool {
        guard stack.count >= 2 else { return false }
        stack.removeLast()
        let previous = stack[stack.count - 1]

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let pasteItem = NSPasteboardItem()
        for entry in previous.entries {
            // File URLs need `writeObjects` with URL objects; deferred to a
            // later milestone. Text/image/RTF data rides on the paste item.
            guard entry.type != NSPasteboard.PasteboardType.fileURL.rawValue,
                  let data = entry.value else { continue }
            pasteItem.setData(data, forType: NSPasteboard.PasteboardType(entry.type))
        }
        pasteboard.writeObjects([pasteItem])
        pasteboard.setString("", forType: .fromStation)
        if let app = previous.application {
            pasteboard.setString(app, forType: .source)
        }

        suppressNextCapture = true
        return true
    }

    /// Depth exposed for settings / debugging.
    var depth: Int { stack.count }
}
