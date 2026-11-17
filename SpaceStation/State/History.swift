import AppKit.NSRunningApplication
import Foundation
import Observation
import SwiftData

// Port of refs/Maccy/Maccy/Observables/History.swift (commit f0b571e).
// Kept verbatim: load :125-142, insert/save :151-157, add + dedup :159-222,
// clear/delete :237-341, findSimilarItem/isModified :508-523, limit :144-149.
// Pin changes (M1 = engine only, no UI):
//  - `HistoryItemDecorator` / `PinManager` / `Search` / `Throttler` / `Popup`
//    / `Navigator` / `KeyShortcut` / `Notifier` are UI-layer; replaced with a
//    plain `[HistoryItem]` array and a `sorter`. Card shell lands in M2.
//  - `AppState.shared.popup.needsResize` -> `@Observable` invalidation via array.
@Observable
@MainActor
final class History {
    static let shared = History()

    let logger = Logger(label: "com.samuelonly.spacestation")
    private let sorter = Sorter()

    /// Source of truth for the panel. Replaces Maccy's decorator collection.
    private(set) var items: [HistoryItem] = []

    /// Paste stack state — M1 only needs the interrupt signal (:461-467).
    private(set) var pasteStackActive = false

    @ObservationIgnored
    private var sessionLog: [Int: HistoryItem] = [:]

    // MARK: - Load & storage (:125-157)

    func load() async throws {
        let descriptor = FetchDescriptor<HistoryItem>()
        let results = try Storage.shared.context.fetch(descriptor)
        items = sorter.sort(results)
        limitHistorySize(to: SS.historySize)
        // §11: 启动阶段后台预加载队首 10 张位图（可见 6 + 左右各 2）。
        ThumbnailCache.shared.preload(items.compactMap { $0.imageData })
    }

    func insertIntoStorage(_ item: HistoryItem) throws {
        logger.info("Inserting item with id '\(item.title)'")
        Storage.shared.context.insert(item)
        Storage.shared.context.processPendingChanges()
        try? Storage.shared.context.save()
    }

    // MARK: - Add with continuous dedup (:159-222)

    @discardableResult
    func add(_ item: HistoryItem) -> HistoryItem {
        try? insertIntoStorage(item)

        var replaced: HistoryItem?
        if let existing = findSimilarItem(item) {
            if isModified(item) == nil {
                transferContents(from: existing, to: item)
            }
            // :174-180 — inherit metadata; lastCopiedAt deliberately not refreshed.
            item.firstCopiedAt = existing.firstCopiedAt
            item.numberOfCopies += existing.numberOfCopies
            item.pin = existing.pin
            item.title = existing.title
            if !item.fromStation {
                item.application = existing.application
            }
            logger.info("Removing duplicate item '\(item.title)'")
            replaced = existing
            deleteFromStorage(existing)
        }

        limitHistorySize(to: SS.historySize)

        sessionLog[Clipboard.shared.changeCount] = item

        if let replaced {
            items.removeAll { $0 === replaced }
        }
        insertSorted(item)

        return item
    }

    private func insertSorted(_ item: HistoryItem) {
        let sorted = sorter.sort(items + [item])
        items = sorted
    }

    // MARK: - Dedup helpers (:325-341, :508-523)

    /// :95-103 of HistoryItem + sessionLog modified path.
    // MARK: - Favorite cabin (§8 / §939)
    //
    // Favorite is a transfer target, not a Clip sub-state: a favorited card is
    // permanent (never expires, never capacity-evicted), and a later identical
    // clipboard copy must NOT collapse into it (de-dup skips favorites).

    /// §8 (b): author a note card directly in the Favorite cabin. No pasteboard
    /// capture — built from the given title/body and inserted as a normal item.
    @discardableResult
    func addNote(title: String, body: String) -> HistoryItem {
        let item = HistoryItem()
        item.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "新笔记" : title
        item.application = "Space Station"
        item.isFavorite = true
        item.isNote = true
        let payload = body.data(using: .utf8)
        item.contents = [HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: payload)]
        try? insertIntoStorage(item)
        insertSorted(item)
        logger.info("Created favorite note '\(item.title)'")
        return item
    }

    /// §8 (c) / §943: a dropped file or folder becomes a Favorite card. A folder
    /// card is a real Mini Finder entry (its fileURLs point at the directory).
    @discardableResult
    func addFavoriteFiles(_ urls: [URL]) -> HistoryItem {
        let item = HistoryItem()
        item.application = "Finder"
        item.isFavorite = true
        item.contents = urls.compactMap { url in
            HistoryItemContent(type: NSPasteboard.PasteboardType.fileURL.rawValue,
                               value: try? url.dataRepresentation)
        }
        item.title = urls.count == 1
            ? urls[0].lastPathComponent
            : "\(urls.count) 个项目"
        try? insertIntoStorage(item)
        insertSorted(item)
        logger.info("Created favorite file card '\(item.title)'")
        return item
    }

    /// Clip card → Favorite cabin (and back). Persists the flag; the tab filter
    /// does the actual "transfer" so no card is duplicated or moved in storage.
    func toggleFavorite(_ item: HistoryItem) {
        item.isFavorite.toggle()
        let context = Storage.shared.context
        context.processPendingChanges()
        try? context.save()
        logger.info("\(item.isFavorite ? "Favorited" : "Unfavorited") '\(item.title)'")
    }

    private func findSimilarItem(_ item: HistoryItem) -> HistoryItem? {
        if let duplicate = items.first(where: {
            $0 !== item && !$0.isFavorite && $0.supersedes(item)   // §8: favorites never de-dup
        }) {
            return duplicate
        }
        return isModified(item)
    }

    private func isModified(_ item: HistoryItem) -> HistoryItem? {
        guard let modified = item.modified else { return nil }
        return sessionLog[modified]
    }

    private func transferContents(from existing: HistoryItem, to new: HistoryItem) {
        deleteContents(of: new)
        new.contents = existing.contents
        existing.contents = []
    }

    private func deleteFromStorage(_ item: HistoryItem) {
        // §11: Clip 删除/过期/容量淘汰时同步清理该卡位图缓存（删除内容的统一入口）。
        item.purgeImageCache()
        deleteContents(of: item)
        Storage.shared.context.delete(item)
        Storage.shared.context.processPendingChanges()
        try? Storage.shared.context.save()
    }

    private func deleteContents(of item: HistoryItem) {
        item.contents.forEach(Storage.shared.context.delete)
    }

    // MARK: - Size, clear, delete (:144-149, :237-323)

    private func limitHistorySize(to maxSize: Int) {
        // §8: favorites are permanent — exclude them from the cap. Only Clip
        // cards count toward historySize; sorting keeps favorites interspersed,
        // so filter first, then trim the overflow off the evictable tail.
        let evictable = items.filter { !$0.isFavorite }
        guard evictable.count > maxSize else { return }
        evictable.suffix(evictable.count - maxSize).forEach(delete)
    }

    func delete(_ item: HistoryItem?) {
        guard let item else { return }
        deleteFromStorage(item)
        items.removeAll { $0 === item }
        sessionLog.removeValues { $0 === item }
    }

    // HTML §17.10 / §19.6: retention cleanup. Days are user-configurable,
    // never hard-coded; 0 means never expire. Pinned cards are exempt (PRD:
    // "Pin 卡不参与过期清理"). Uses lastCopiedAt, which dedup deliberately
    // does not refresh — re-copying the same clip will not extend its life.
    // Call on launch (after load) and immediately when the user changes the
    // retention value in Settings.
    @discardableResult
    func cleanupExpired() -> Int {
        let days = SS.retentionDays
        guard days > 0 else { return 0 } // 0 = never expire

        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        // §8: favorites are permanent — exempt from retention just like pins.
        let expired = items.filter { $0.pin == nil && !$0.isFavorite && $0.lastCopiedAt < cutoff }
        guard !expired.isEmpty else { return 0 }

        expired.forEach(delete)
        logger.info("Expired \(expired.count) item(s) older than \(days) day(s)")
        return expired.count
    }

    func clear() {
        items.forEach(deleteFromStorage)
        items.removeAll()
        sessionLog.removeValues { $0.pin == nil }
        Clipboard.shared.clear()
    }

    func clearAll() {
        // §11: 清空不走 deleteFromStorage，单独同步清位图缓存。
        items.forEach { $0.purgeImageCache() }
        do {
            let context = Storage.shared.context
            try context.transaction {
                try context.delete(
                    model: HistoryItemContent.self,
                    where: #Predicate { $0.item == nil }
                )
                try context.delete(model: HistoryItem.self)
                try context.delete(model: HistoryItemContent.self)
            }
            context.processPendingChanges()
            try context.save()
        } catch {
            logger.error("Failed to clear storage: \(String(reflecting: error))")
        }
        items.removeAll()
        sessionLog.removeAll()
        Clipboard.shared.clear()
    }

    // MARK: - Paste stack interrupt (:461-467)

    func interruptPasteStack() {
        guard pasteStackActive else { return }
        logger.info("Interrupting PasteStack")
        pasteStackActive = false
    }
}
