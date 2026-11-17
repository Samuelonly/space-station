import AppKit.NSPasteboard
import Foundation
import SwiftData

// SwiftData container — see THIRD_PARTY_LICENSES for the MIT engine-base attribution.
// Local change: database URL path namespaced to SpaceStation/; DEBUG testing branch
// removed (no UI-test harness in M1).
@MainActor
final class Storage {
    static let shared = Storage()

    var container: ModelContainer
    var context: ModelContext { container.mainContext }
    var size: String {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).allValues.first?.value as? Int64,
              size > 1 else {
            return ""
        }
        return ByteCountFormatter().string(fromByteCount: size)
    }

    private let url = URL.applicationSupportDirectory
        .appending(path: "SpaceStation/Storage.sqlite")

    init() {
        let config = ModelConfiguration(url: url)
        do {
            container = try ModelContainer(for: HistoryItem.self, configurations: config)
        } catch {
            fatalError("Cannot load database: \(error.localizedDescription).")
        }
    }

    func cleanupOrphanedContents() throws -> Int {
        let descriptor = FetchDescriptor<HistoryItemContent>(
            predicate: #Predicate { $0.item == nil }
        )
        let count = try context.fetchCount(descriptor)
        guard count > 0 else { return 0 }

        try context.delete(
            model: HistoryItemContent.self,
            where: #Predicate { $0.item == nil }
        )
        context.processPendingChanges()
        try context.save()
        return count
    }

    func removeUnpersistableContents() throws -> Int {
        let contents = try context.fetch(FetchDescriptor<HistoryItemContent>())
        let unwanted = contents.filter {
            !Clipboard.shared.isPersistable(NSPasteboard.PasteboardType($0.type))
        }
        guard !unwanted.isEmpty else { return 0 }

        unwanted.forEach(context.delete)
        context.processPendingChanges()
        try context.save()
        return unwanted.count
    }

    // Storage.swift:73-95 — heal titles that hang CoreText on macOS 26 (issue #1520).
    func sanitizeTitles() throws -> Int {
        let items = try context.fetch(FetchDescriptor<HistoryItem>())
        var count = 0
        for item in items where item.title.containsScalarsUnsafeForTitleLayout {
            item.title = item.title.removingScalarsUnsafeForTitleLayout()
            count += 1
        }
        guard count > 0 else { return 0 }

        context.processPendingChanges()
        try context.save()
        return count
    }
}
