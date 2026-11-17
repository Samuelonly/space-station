import AppKit
import CoreGraphics
import Foundation

/// 截图 / 标注 / OCR / 翻译模块的统一门面（Facade）。
///
/// 所有 CaptureKit 能力经由此处对外暴露，核心 app 只需调用这几个方法，
/// 不直接接触 snap-flow 移植来的任何类型 —— 保持模块边界窄、可替换。
@MainActor
final class CaptureService {
    static let shared = CaptureService()

    let configuration: CaptureConfiguration
    private let ocrRouter: OCRRouter
    private let translationService: TranslationService

    init(configuration: CaptureConfiguration = CaptureConfiguration()) {
        self.configuration = configuration
        self.ocrRouter = OCRRouter(settings: configuration)
        self.translationService = TranslationService(settings: configuration)
        ProviderCatalog.seedIfEmpty(configuration)
    }

    // MARK: - 入口

    /// 打开全屏框选，返回截图结果（含区域 + 捕获图）。取消返回 nil。
    func captureRegion() async -> SnipResult? {
        await RegionSelectorController.snip(settings: .shared, purpose: .annotate)
    }

    /// 只框选一个区域（供"原图翻译"等复用）。
    func selectRegion() async -> CaptureRegion? {
        await RegionSelectorController.selectRegion(settings: .shared)
    }

    // MARK: - OCR

    /// 用当前默认 OCR 服务识别图片；languages 传 nil 走自动。
    func recognize(_ image: CGImage, languages: [String]? = nil) async throws -> [OCRLine] {
        try await ocrRouter.recognize(image, languages: languages)
    }

    /// 指定服务的 OCR（设置页"试一试"用）。
    func recognize(_ image: CGImage, serviceID: String) async throws -> [OCRLine] {
        try await ocrRouter.recognize(image, languages: nil, serviceID: serviceID)
    }

    // MARK: - 翻译

    /// 用当前默认翻译服务翻译文本；默认走 macOS 系统翻译（大陆可用、离线）。
    func translate(_ texts: [String]) async throws -> TranslationResult {
        try await translationService.translate(texts)
    }

    /// 指定服务的翻译。
    func translate(
        _ texts: [String],
        serviceID: String,
        source: String? = nil,
        target: String? = nil
    ) async throws -> TranslationResult {
        try await translationService.translate(
            texts, sourceLanguage: source, targetLanguage: target, serviceID: serviceID
        )
    }

    // MARK: - 服务目录（供设置 UI）

    func enabledOCRServices() -> [OCRServiceEntry] {
        configuration.ocrServices.filter { $0.kind == .vision || $0.isEnabled }
    }

    func enabledTranslationServices() -> [TranslationServiceEntry] {
        configuration.translationServices.filter { $0.kind == .system || $0.isEnabled }
    }
}
