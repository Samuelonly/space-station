import Foundation
import SwiftData

// Verbatim port of refs/Maccy/Maccy/Models/HistoryItemContent.swift:4-16.
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
