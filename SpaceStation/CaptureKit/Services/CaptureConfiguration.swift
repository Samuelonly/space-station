import Foundation

// MARK: - 轻量配置层
//
// 替代 snap-flow 的 800 行 SettingsStore，只为 OCR 路由与翻译服务提供必需的
// 服务列表 / 默认 ID / 语言对 / token 回写。provider 代码无需改动，
// 只需把参数类型 SettingsStore 换成 any CaptureConfiguring。
// 服务条目（OCRServiceEntry / TranslationServiceEntry）沿用原数据结构。

@MainActor
protocol CaptureConfiguring: AnyObject {
    // OCR
    func resolvedDefaultOCRServiceID() -> String
    func ocrService(id: String) -> OCRServiceEntry?
    var ocrServices: [OCRServiceEntry] { get }
    func updateBaiduToken(serviceID: String, config: BaiduOCRConfig)

    // Translation
    func resolvedDefaultTranslationServiceID() -> String
    func translationService(id: String) -> TranslationServiceEntry?
    var translationServices: [TranslationServiceEntry] { get }
    var sourceLanguage: String { get set }
    var targetLanguage: String { get set }
}

/// 默认配置实现：UserDefaults 持久化，内置「系统翻译 + Vision OCR」。
/// 其余 provider 由接入层（地区分流）程序化注入。
final class CaptureConfiguration: CaptureConfiguring {
    private let defaults: UserDefaults
    private let keyOCRServices = "ss.capture.ocrServices"
    private let keyOCRDefault = "ss.capture.ocrDefaultID"
    private let keyTransServices = "ss.capture.translationServices"
    private let keyTransDefault = "ss.capture.translationDefaultID"
    private let keySourceLang = "ss.capture.sourceLanguage"
    private let keyTargetLang = "ss.capture.targetLanguage"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - OCR services

    var ocrServices: [OCRServiceEntry] {
        get {
            if let data = defaults.data(forKey: keyOCRServices),
               let decoded = try? JSONDecoder().decode([OCRServiceEntry].self, from: data),
               !decoded.isEmpty
            {
                var list = decoded
                if !list.contains(where: { $0.kind == .vision }) {
                    list.insert(.vision(), at: 0)
                }
                if let idx = list.firstIndex(where: { $0.kind == .vision }) {
                    list[idx].isEnabled = true
                    list[idx].id = OCRServiceEntry.visionID
                }
                return list
            }
            return [.vision()]
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: keyOCRServices)
            }
        }
    }

    private var ocrDefaultID: String {
        get { defaults.string(forKey: keyOCRDefault) ?? OCRServiceEntry.visionID }
        set { defaults.set(newValue, forKey: keyOCRDefault) }
    }

    func ocrService(id: String) -> OCRServiceEntry? {
        ocrServices.first { $0.id == id }
    }

    func resolvedDefaultOCRServiceID() -> String {
        if let e = ocrService(id: ocrDefaultID), e.kind == .vision || e.isEnabled {
            return e.id
        }
        return OCRServiceEntry.visionID
    }

    func setDefaultOCRServiceID(_ id: String) {
        guard ocrServices.contains(where: { $0.id == id }) else { return }
        ocrDefaultID = id
    }

    /// 用草稿列表整体替换（地区分流 / 设置页保存时调用）。
    func replaceOCRServices(_ services: [OCRServiceEntry], defaultID: String? = nil) {
        var list = services
        if !list.contains(where: { $0.kind == .vision }) {
            list.insert(.vision(), at: 0)
        }
        if let idx = list.firstIndex(where: { $0.kind == .vision }) {
            list[idx].isEnabled = true
            list[idx].id = OCRServiceEntry.visionID
        }
        ocrServices = list
        if let defaultID, list.contains(where: { $0.id == defaultID }) {
            ocrDefaultID = defaultID
        }
    }

    func updateBaiduToken(serviceID: String, config: BaiduOCRConfig) {
        var list = ocrServices
        guard let idx = list.firstIndex(where: { $0.id == serviceID }) else { return }
        list[idx].baidu = config
        ocrServices = list
    }

    // MARK: - Translation services

    var translationServices: [TranslationServiceEntry] {
        get {
            if let data = defaults.data(forKey: keyTransServices),
               let decoded = try? JSONDecoder().decode([TranslationServiceEntry].self, from: data),
               !decoded.isEmpty
            {
                return Self.normalizedTranslationServices(decoded)
            }
            return [.system()]
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: keyTransServices)
            }
        }
    }

    private var translationDefaultID: String {
        get { defaults.string(forKey: keyTransDefault) ?? TranslationServiceEntry.systemID }
        set { defaults.set(newValue, forKey: keyTransDefault) }
    }

    private static func normalizedTranslationServices(
        _ services: [TranslationServiceEntry]
    ) -> [TranslationServiceEntry] {
        var seen = Set<String>()
        var result = [TranslationServiceEntry.system()]
        seen.insert(TranslationServiceKind.system.rawValue)
        for var entry in services where !seen.contains(entry.kind.rawValue) {
            guard entry.kind != .system else { continue }
            seen.insert(entry.kind.rawValue)
            if !entry.privacyAccepted { entry.isEnabled = false }
            result.append(entry)
        }
        return result
    }

    func translationService(id: String) -> TranslationServiceEntry? {
        translationServices.first { $0.id == id }
    }

    func resolvedDefaultTranslationServiceID() -> String {
        if let entry = translationService(id: translationDefaultID),
           entry.kind == .system || (entry.isEnabled && entry.isReadyToTranslate)
        {
            return entry.id
        }
        return TranslationServiceEntry.systemID
    }

    func setDefaultTranslationServiceID(_ id: String) {
        guard translationServices.contains(where: { $0.id == id }) else { return }
        translationDefaultID = id
    }

    /// 用草稿列表整体替换（地区分流 / 设置页保存时调用）。
    func replaceTranslationServices(_ services: [TranslationServiceEntry], defaultID: String? = nil) {
        let normalized = Self.normalizedTranslationServices(services)
        translationServices = normalized
        if let defaultID, normalized.contains(where: { $0.id == defaultID }) {
            translationDefaultID = defaultID
        }
    }

    // MARK: - Languages

    var sourceLanguage: String {
        get { defaults.string(forKey: keySourceLang) ?? TranslationLanguage.autoSourceToken }
        set { defaults.set(newValue, forKey: keySourceLang) }
    }

    var targetLanguage: String {
        get {
            let raw = defaults.string(forKey: keyTargetLang) ?? TranslationLanguage.systemTargetToken
            return raw.isEmpty ? TranslationLanguage.systemTargetToken : raw
        }
        set { defaults.set(newValue, forKey: keyTargetLang) }
    }
}
