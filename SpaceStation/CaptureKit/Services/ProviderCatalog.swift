import Foundation

/// 服务商目录 —— 按「地区 AND 语言」双条件分流。
///
/// 用户明确要求（2026-11-18 拍板）：
/// - 特供版**仅限中国大陆**：必须地区是 CN **且**界面语言是中文，才追加国产服务商。
/// - 反例：新加坡用户也用简体中文，但地区非 CN、能用 Gemini/Google，故不显示国产服务。
/// - 中国版 = 外国常用 + 国产全家桶（最全）；外国版只显示国外常用，对百度/腾讯无感。
/// - 默认始终是 macOS 系统翻译 / Vision OCR（离线、零配置、大陆可用）。
enum ProviderCatalog {

    // MARK: - 地区判定（地区 AND 语言）

    /// 是否中国大陆：地区代码为 CN，且首选语言为中文。
    static var isMainlandChina: Bool {
        let region = Locale.current.region?.identifier.uppercased() ?? ""
        let regionIsCN = region == "CN"
        let languageIsChinese = Locale.preferredLanguages.first.map { code in
            code.lowercased().hasPrefix("zh")
        } ?? false
        return regionIsCN && languageIsChinese
    }

    // MARK: - OCR 服务清单

    /// 所有地区都提供：系统离线识别 + Google + 自定义端点。
    private static let globalOCR: [OCRServiceKind] = [.vision, .google, .custom]
    /// 仅中国大陆追加：国产 OCR。
    private static let chinaOCR: [OCRServiceKind] = [.baidu, .youdao, .tencent, .volcengine]

    static var ocrKinds: [OCRServiceKind] {
        isMainlandChina ? globalOCR + chinaOCR : globalOCR
    }

    static func makeOCRServices() -> [OCRServiceEntry] {
        ocrKinds.map { .make(kind: $0) }
    }

    // MARK: - 翻译服务清单

    /// 所有地区都提供：系统默认 + 国际主流 + OpenAI 兼容国际厂商 + 本地模型。
    private static let globalTranslation: [TranslationServiceKind] = [
        .system, .google, .deepl, .microsoft, .amazon,
        .openai, .openrouter, .groq, .grok,
        .ollama, .lmStudio,
    ]
    /// 仅中国大陆追加：国产云翻译 + 国产大模型（OpenAI 兼容）。
    private static let chinaTranslation: [TranslationServiceKind] = [
        .baidu, .youdao, .volcengine, .tencent, .aliyun, .caiyun, .niutrans,
        .deepseek, .qwen, .zhipu, .siliconflow, .kimi,
    ]

    static var translationKinds: [TranslationServiceKind] {
        isMainlandChina ? globalTranslation + chinaTranslation : globalTranslation
    }

    static func makeTranslationServices() -> [TranslationServiceEntry] {
        translationKinds.map { .make(kind: $0) }
    }

    // MARK: - 首次安装/重置时注入配置

    /// 若配置里尚无服务列表，注入当前地区对应的清单。
    /// 注意：不覆盖用户已有的自定义配置，避免升级时丢失密钥。
    @MainActor
    static func seedIfEmpty(_ config: CaptureConfiguration) {
        if config.ocrServices.isEmpty || config.ocrServices == [.vision()] {
            config.replaceOCRServices(makeOCRServices())
        }
        if config.translationServices.isEmpty || config.translationServices == [.system()] {
            config.replaceTranslationServices(makeTranslationServices())
        }
    }
}
