import AppKit

// Port of refs/Maccy/Maccy/Sorter.swift (commit f0b571e).
// Pin change: Maccy's `PinOrder` (UserDefaults-backed) is simplified to a
// deterministic alphabetical pin order — pin reordering UI is M4.
// The three sort keys and the pinned/unpinned split are verbatim (:26-65).
final class Sorter {
    enum By: String, CaseIterable {
        case lastCopiedAt
        case firstCopiedAt
        case numberOfCopies
    }

    func sort(_ items: [HistoryItem], by: By = SS.sortBy) -> [HistoryItem] {
        let sortedUnpinned = items
            .filter { $0.pin == nil }
            .sorted(by: { bySortingAlgorithm($0, $1, by) })

        let pinnedItems = items.filter { $0.pin != nil }
        let orderedPinned = pinnedItems.sorted { ($0.pin ?? "") < ($1.pin ?? "") }

        switch SS.pinTo {
        case .top:
            return orderedPinned + sortedUnpinned
        case .bottom:
            return sortedUnpinned + orderedPinned
        }
    }

    private func bySortingAlgorithm(_ lhs: HistoryItem, _ rhs: HistoryItem, _ by: By) -> Bool {
        switch by {
        case .firstCopiedAt:
            return lhs.firstCopiedAt > rhs.firstCopiedAt
        case .numberOfCopies:
            return lhs.numberOfCopies > rhs.numberOfCopies
        default:
            return lhs.lastCopiedAt > rhs.lastCopiedAt
        }
    }
}
