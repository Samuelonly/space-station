import Foundation
import SwiftData

// SwiftData content record — see THIRD_PARTY_LICENSES for attribution.
@Model
final class HistoryItemContent {
    var type: String = ""
    var value: Data?

    @Relationship
    var item: HistoryItem?

    init(type: String, value: Data? = nil) {
        self.type = type
        self.value = value
    }
}
