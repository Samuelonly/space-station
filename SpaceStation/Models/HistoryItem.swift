import AppKit
import Foundation
import SwiftData
import Vision

// Port of refs/Maccy/Maccy/Models/HistoryItem.swift (commit f0b571e).
// Fields :77-87, dedup :95-103, title :105-141, accessors :143-250, OCR :252-291.
// Pin-key helper statics (:9-62) are UI/keyboard concerns — deferred to M4.
@Model
class HistoryItem {
    // :77-82 — persisted fields, verbatim.
    var application: String?
    var firstCopiedAt: Date = Date.now
    var lastCopiedAt: Date = Date.now
    var numberOfCopies: Int = 1
    var pin: String?
    var title = ""

    @Relationship(deleteRule: .cascade, inverse: \HistoryItemContent.item)
    var contents: [HistoryItemContent] = []

    // §11: 解码结果改由集中式 ThumbnailCache 管理（200 张 LRU + 磁盘缓存），
    // 不再用每卡一份、无上限的 @Transient cachedDecodedImage。

    // Our additions (HTML §21.5.1): prediction metadata + source bundleId.
    // Optional/defaulted so the SwiftData schema stays compatible with the port.
    var sourceBundleId: String?
    var predictedActionID: String?
    var predictionReason: String?
    var sanitizedValue: String?

    // §8 Favorite cabin (our additions, defaulted so SwiftData schema stays
    // compatible). Favorite is a PERMANENT transfer target: unlike Pin (which
    // only locks a card inside the Clip rail), a favorited card leaves the
    // Clip flow, never expires and is never capacity-evicted or de-duplicated
    // by a later clipboard copy (§939 / §8). `isNote` marks cards authored via
    // the Favorite `+` composer rather than captured from the pasteboard.
    var isFavorite: Bool = false
    var isNote: Bool = false

    init(contents: [HistoryItemContent] = []) {
        self.firstCopiedAt = Date.now
        self.lastCopiedAt = Date.now
        self.contents = contents
    }

    // :64-74 — transient types excluded from duplicate comparison.
    private static let transientTypes: [String] = [
        NSPasteboard.PasteboardType.modified.rawValue,
        NSPasteboard.PasteboardType.fromStation.rawValue,
        NSPasteboard.PasteboardType.linkPresentationMetadata.rawValue,
        NSPasteboard.PasteboardType.customWebKitPasteboardData.rawValue,
        NSPasteboard.PasteboardType.source.rawValue,
        NSPasteboard.PasteboardType.customChromiumWebData.rawValue,
        NSPasteboard.PasteboardType.chromiumSourceUrl.rawValue,
        NSPasteboard.PasteboardType.chromiumSourceToken.rawValue,
        NSPasteboard.PasteboardType.notesRichText.rawValue
    ]

    private static let imageTypes: [NSPasteboard.PasteboardType] = StorageType.images.types

    // :95-103 — no time window, pure type+value comparison. Verbatim.
    func supersedes(_ item: HistoryItem) -> Bool {
        item.contents
            .filter { !Self.transientTypes.contains($0.type) }
            .allSatisfy { content in
                contents.contains(where: { $0.type == content.type && $0.value == content.value })
            }
    }

    // :105-141 — title generation with OCR kickoff.
    @MainActor
    func generateTitle() -> String {
        let pasteboardImageData = contentData(Self.imageTypes)
        let universalClipboardImageURL = universalClipboardImage ? fileURLs.first : nil
        guard pasteboardImageData == nil && universalClipboardImageURL == nil else {
            Task {
                if let recognizedText = await Self.recognizeText(
                    imageData: pasteboardImageData,
                    fileURL: universalClipboardImageURL
                ) {
                    self.title = recognizedText
                }
            }
            return ""
        }

        var title = previewableText
            .shortened(to: 1_000)
            .removingScalarsUnsafeForTitleLayout()

        if SS.showSpecialSymbols {
            if let range = title.range(of: "^ +", options: .regularExpression) {
                title = title.replacingOccurrences(of: " ", with: "·", range: range)
            }
            if let range = title.range(of: " +$", options: .regularExpression) {
                title = title.replacingOccurrences(of: " ", with: "·", range: range)
            }
            title = title
                .replacingOccurrences(of: "\n", with: "⏎")
                .replacingOccurrences(of: "\t", with: "⇥")
        } else {
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return title
    }

    // :143-157
    var previewableText: String {
        if !fileURLs.isEmpty {
            fileURLs
                .compactMap { $0.absoluteString.removingPercentEncoding }
                .joined(separator: "\n")
        } else if let text, !text.isEmpty {
            text
        } else if let rtf, !rtf.string.isEmpty {
            rtf.string
        } else if let html, !html.string.isEmpty {
            html.string
        } else {
            title
        }
    }

    // :159-166
    var fileURLs: [URL] {
        guard !universalClipboardText else { return [] }
        return allContentData([.fileURL])
            .compactMap { URL(dataRepresentation: $0, relativeTo: nil, isAbsolute: true) }
    }

    /// §8: a card is a "folder card" (Mini Finder) when any copied fileURL is
    /// a directory. Used by the `mini` tab filter and the Favorite folder card.
    var isFolderCard: Bool { fileURLs.contains { $0.hasDirectoryPath } }

    /// §8 (b): a note card authored in the Favorite cabin. Its body is the
    /// `.string` content; title is the user-given note name.
    var noteBody: String? { isNote ? text : nil }

    var htmlData: Data? { contentData([.html]) }
    var html: NSAttributedString? {
        guard let data = htmlData else { return nil }
        return NSAttributedString(html: data, documentAttributes: nil)
    }

    var imageData: Data? {
        var data = contentData(Self.imageTypes)
        if data == nil, universalClipboardImage, let url = fileURLs.first {
            data = try? Data(contentsOf: url)
        }
        return data
    }

    /// §11: 解码走集中缓存 —— 内存 LRU 200 + 磁盘缓存 + 预加载。
    /// 内容寻址（imageData 的 SHA256），多卡共享、重启命中、删卡可精准清理。
    var image: NSImage? {
        guard let data = imageData else { return nil }
        return ThumbnailCache.shared.image(forData: data)
    }

    /// §11: 删除/过期时同步清理该卡位图的内存与磁盘缓存。
    func purgeImageCache() {
        guard let data = imageData else { return }
        ThumbnailCache.shared.removeImage(forData: data)
    }

    var rtfData: Data? { contentData([.rtf]) }
    var rtf: NSAttributedString? {
        guard let data = rtfData else { return nil }
        return NSAttributedString(rtf: data, documentAttributes: nil)
    }

    @available(*, deprecated, renamed: "purgeImageCache()")
    func clearDecodedImageCache() { purgeImageCache() }

    var text: String? {
        guard let data = contentData([.string]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    var modified: Int? {
        guard let data = contentData([.modified]),
              let modified = String(data: data, encoding: .utf8) else { return nil }
        return Int(modified)
    }

    var fromStation: Bool { contentData([.fromStation]) != nil }
    var universalClipboard: Bool { contentData([.universalClipboard]) != nil }

    private var universalClipboardImage: Bool {
        universalClipboard && fileURLs.first?.pathExtension == "jpeg"
    }

    private var universalClipboardText: Bool {
        universalClipboard && contentData([.html, .tiff, .png, .jpeg, .rtf, .string, .heic]) != nil
    }

    // :238-250
    private func contentData(_ types: [NSPasteboard.PasteboardType]) -> Data? {
        let content = contents.first(where: {
            types.contains(NSPasteboard.PasteboardType($0.type))
        })
        return content?.value
    }

    private func allContentData(_ types: [NSPasteboard.PasteboardType]) -> [Data] {
        contents
            .filter { types.contains(NSPasteboard.PasteboardType($0.type)) }
            .compactMap { $0.value }
    }

    // :252-291 — OCR off the cooperative pool.
    nonisolated private static let textRecognitionQueue = DispatchQueue(
        label: "com.samuelonly.spacestation.textRecognition",
        qos: .utility
    )

    nonisolated private static func recognizeText(imageData: Data?, fileURL: URL?) async -> String? {
        await withCheckedContinuation { continuation in
            textRecognitionQueue.async {
                continuation.resume(returning: performTextRecognition(imageData: imageData, fileURL: fileURL))
            }
        }
    }

    nonisolated private static func performTextRecognition(imageData: Data?, fileURL: URL?) -> String? {
        guard let data = imageData ?? fileURL.flatMap({ try? Data(contentsOf: $0) }) else {
            return nil
        }
        let requestHandler = VNImageRequestHandler(data: data)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        do {
            try requestHandler.perform([request])
        } catch {
            print("Unable to perform the request: \(error).")
            return nil
        }
        guard let observations = request.results else { return nil }
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
