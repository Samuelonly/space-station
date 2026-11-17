import AppKit
import Foundation

/// CaptureKit 与宿主 app 的桥接层。
///
/// 这是唯一的「模块 → History」写入点。CaptureKit 内部不认识 History/SwiftData；
/// 宿主通过这里把截图结果落库、把 OCR/译文复制或回写。保持边界窄、可替换。
@MainActor
enum CaptureIntegration {

    /// 打开全屏框选 → 把截图作为图片卡插入 History，返回新卡片。
    @discardableResult
    static func captureToHistory() async -> HistoryItem? {
        guard let result = await CaptureService.shared.captureRegion() else { return nil }
        guard let payload = SnipImageExport.encode(result.image, quality: 100) else { return nil }

        let item = HistoryItem()
        item.application = "Space Station · 截图"
        let r = result.region.rectInScreenPoints
        item.title = "截图 · \(Int(r.width))×\(Int(r.height))"
        let type = NSPasteboard.PasteboardType.tiff.rawValue
        item.contents = [HistoryItemContent(type: type, value: payload.data)]
        History.shared.add(item)
        return item
    }

    /// 识别选中图片卡里的文字（用当前默认 OCR 服务），返回文本行。
    static func recognize(item: HistoryItem) async throws -> [OCRLine] {
        guard let data = item.imageData, let image = NSImage(data: data),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return [] }
        return try await CaptureService.shared.recognize(cg)
    }

    /// 翻译文本（默认系统翻译，大陆可用、离线、秒出）。
    static func translate(_ texts: [String]) async throws -> [String] {
        let result = try await CaptureService.shared.translate(texts)
        return result.texts
    }
}
