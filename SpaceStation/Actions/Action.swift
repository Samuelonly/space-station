import Foundation

/// HTML §21.7.1 — Action registry. 25 actions / 5 groups, ported verbatim from
/// the prototype `ACTIONS` (space-station.html:1620-1679). Designed from day one
/// to be registrable / discoverable / executable — this is the same entry point
/// that grows into a command palette and plugin system later. NOT a switch.
///
/// Ported fields: id, icon, label, desc, types, group, rank, passive, tier.
/// Closure fields (boost/why/demo) live in PredictionEngine / ActionExecutor
/// so pure data stays `Sendable` and independently testable.
struct ActionDefinition: Sendable, Identifiable {
    let id: String
    let icon: String
    let label: String
    let desc: String
    /// `nil` means "*" (all types) in the prototype.
    let types: Set<ClipKind>?
    let group: ActionGroup
    let rank: Int
    let passive: Bool
    let tier: ActionTier?

    func canUse(on kind: ClipKind) -> Bool {
        guard let types else { return true }
        return types.contains(kind)
    }
}

enum ActionGroup: String, Sendable, CaseIterable {
    case recognize, transform, route, organize, hygiene

    var label: String {
        switch self {
        case .recognize: return "识别"
        case .transform: return "变换"
        case .route: return "去向"
        case .organize: return "整理"
        case .hygiene: return "隐私"
        }
    }
}

enum ActionTier: String, Sendable {
    case local, freemium, cloud
}

enum ActionRegistry {
    static let all: [ActionDefinition] = [
        // 识别
        .init(id: "ocr", icon: "👁", label: "OCR 提取文字", desc: "识别图内文字并复制",
              types: [.image, .video], group: .recognize, rank: 82, passive: true, tier: .freemium),
        .init(id: "explain", icon: "⌘", label: "解释这段代码", desc: "生成代码说明",
              types: [.code], group: .recognize, rank: 78, passive: true, tier: .cloud),
        .init(id: "translate", icon: "🌐", label: "翻译", desc: "本地系统翻译免费；长文可走云端",
              types: [.text, .note, .code, .url], group: .recognize, rank: 70, passive: true, tier: .freemium),
        .init(id: "extractlinks", icon: "🔗", label: "提取全部链接", desc: "富文本里的链接分家",
              types: [.text, .url, .note], group: .recognize, rank: 48, passive: false, tier: nil),
        .init(id: "qr", icon: "▦", label: "识别图中二维码", desc: "本地解码，不联网",
              types: [.image], group: .recognize, rank: 45, passive: false, tier: nil),
        .init(id: "color", icon: "🎨", label: "识别色值", desc: "Hex / RGB / HSL 互转",
              types: [.text, .image, .note], group: .recognize, rank: 42, passive: false, tier: nil),
        .init(id: "quicklook", icon: "␣", label: "超级 Quick Look", desc: "空格预览，替代系统 Quick Look",
              types: nil, group: .recognize, rank: 55, passive: false, tier: .local),
        // 变换
        .init(id: "split", icon: "❋", label: "Split 大爆炸", desc: "文本炸成可点碎片",
              types: [.text, .code, .note], group: .transform, rank: 84, passive: true, tier: nil),
        .init(id: "purify", icon: "🔗", label: "链接净化", desc: "短链还原 / 去追踪参数",
              types: [.url], group: .transform, rank: 88, passive: true, tier: nil),
        .init(id: "plain", icon: "🧹", label: "去格式纯文本", desc: "粘贴时丢掉富文本样式",
              types: [.text, .code, .note, .url], group: .transform, rank: 52, passive: false, tier: nil),
        .init(id: "codechunk", icon: "⌗", label: "按函数/代码块切", desc: "Split 智能粒度",
              types: [.code], group: .transform, rank: 46, passive: false, tier: nil),
        .init(id: "format", icon: "{ }", label: "格式化 / 压缩", desc: "JSON / 代码整形",
              types: [.code, .text], group: .transform, rank: 44, passive: false, tier: nil),
        .init(id: "transform", icon: "Aa", label: "文本变换", desc: "大小写 / 全半角 / 空白 / 正则",
              types: [.text, .code, .note], group: .transform, rank: 43, passive: false, tier: nil),
        .init(id: "flavor", icon: "🧩", label: "切换另一种表示", desc: "同一 Clip 的纯文本 / 富文本 / 图片 / 文件",
              types: nil, group: .transform, rank: 40, passive: false, tier: nil),
        // 去向
        .init(id: "openwith", icon: "↗", label: "预测目标 App", desc: "猜下一步去哪个 App",
              types: nil, group: .route, rank: 92, passive: true, tier: nil),
        .init(id: "folder", icon: "📂", label: "打开文件夹", desc: "Mini Finder 展开子目录",
              types: [.file], group: .route, rank: 50, passive: false, tier: nil),
        .init(id: "reveal", icon: "🔍", label: "在 Finder 中显示", desc: "选中文件",
              types: [.file], group: .route, rank: 46, passive: false, tier: nil),
        .init(id: "export", icon: "⇥", label: "导出到…", desc: "右键菜单低频项",
              types: nil, group: .route, rank: 38, passive: false, tier: nil),
        .init(id: "custom", icon: "⚙", label: "自定义 Action", desc: "AppleScript / 快捷指令 / shell 出口",
              types: nil, group: .route, rank: 36, passive: false, tier: nil),
        // 整理
        .init(id: "copyall", icon: "📋", label: "复制全部", desc: "把内容复制回剪贴板",
              types: nil, group: .organize, rank: 60, passive: true, tier: nil),
        .init(id: "pinkey", icon: "🔤", label: "Pin 到字母键", desc: "一个键召回常用卡",
              types: nil, group: .organize, rank: 48, passive: false, tier: nil),
        .init(id: "stack", icon: "⇉", label: "加入顺序粘贴栈", desc: "多张卡按顺序连粘",
              types: nil, group: .organize, rank: 44, passive: false, tier: nil),
        .init(id: "snippet", icon: "📌", label: "转存成常用片段", desc: "常备片段落到 Favorite",
              types: [.text, .code, .note], group: .organize, rank: 42, passive: false, tier: nil),
        // 隐私
        .init(id: "otp", icon: "⏱", label: "验证码 60 秒消失", desc: "识别一次性码并自动过期",
              types: [.text, .note], group: .hygiene, rank: 76, passive: true, tier: nil),
        .init(id: "secret", icon: "🛡", label: "忽略机密来源", desc: "默认不入库 · 设置里可改",
              types: nil, group: .hygiene, rank: 40, passive: false, tier: nil),
    ]

    static let byID: [String: ActionDefinition] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    /// HTML §1696 `headActions` base = [copy, favorite]. Favorite is a UI-level
    /// always-on card button, NOT a registry entry — that keeps the registry at
    /// exactly 25 actions / 5 groups (§17.5). Its handler lives in ActionExecutor.
    static let favoriteBase = ActionDefinition(
        id: "favorite", icon: "⭐", label: "收藏到 Favorite",
        desc: "永久保存，不受过期影响；再点移回 Clip",
        types: nil, group: .organize, rank: 58, passive: false, tier: nil
    )

    static func actions(for kind: ClipKind) -> [ActionDefinition] {
        all.filter { $0.canUse(on: kind) }
    }

    /// Right-side capsule: 2 base + up to 2 type-specific (prototype headActions).
    /// §639: Copy / Favorite are the always-on base pair; Pin lives on the App
    /// capsule (§960), so it is intentionally not a head action here.
    static func headActions(for kind: ClipKind) -> [ActionDefinition] {
        var result: [ActionDefinition] = []
        if let copy = byID["copyall"] { result.append(copy) }
        result.append(favoriteBase)
        let extraIDs: [ClipKind: [String]] = [
            .text: ["split"], .note: ["split"],
            .code: ["split", "explain"], .url: ["openwith", "purify"],
            .image: ["ocr", "quicklook"], .video: ["quicklook"], .file: ["folder"]
        ]
        for id in extraIDs[kind] ?? [] {
            if let a = byID[id] { result.append(a) }
        }
        return Array(result.prefix(4))
    }
}
