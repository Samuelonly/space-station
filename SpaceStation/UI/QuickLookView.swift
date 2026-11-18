import AppKit
import QuickLook       // QLPreviewItem protocol
import QuickLookUI     // QLPreviewView (AppKit renderer) — macOS only
import SwiftUI

// HTML §17.8 / §21.8 — 超级 Quick Look：Space Station 接管预览。
// 单一预览模块，数据源是剪贴板卡（HistoryItem）而非磁盘文件，因此能带上下文
// （来源 App / 内容类型 / 双端预测），这是系统 Quick Look 做不到的。
//
// 格式分级（§17.8.2）全部收敛在本文件的一个 resolve() + 一个 body 分派：
//   借系统  QLPreviewView 渲染 PDF / 视频 / Doc / 文件型图片；NSImage 走系统解码。
//   自绘    代码 / Markdown / 链接 / 纯文本 — 只读 + 「复制内容」（Text 不可编辑）。
//   复用    文件夹 → MiniFinder column view，不重复造文件列表。
//   扩展位  MKV / WEBM 等系统不支持的格式 → .extended 分支；新增格式只改
//           extendedFormats + body 的对应 case，不散落、不新建 App（§21.8）。

// MARK: - 内容分派（纯函数，可独立测试）

@MainActor
enum QuickLookResolver {
    /// 预览内容类别。携带的值都非 Sendable（NSImage/URL/@Model），
    /// 全程限定 @MainActor，不跨 actor 边界。
    enum Content {
        case image(NSImage)          // 剪贴板内嵌位图 → 系统解码展示
        case systemFile(URL)         // PDF / 视频 / Doc / 文件型图片 → QLPreviewView
        case text(String, Flavor)    // 代码 / Markdown / 链接 / 文本 → 自绘只读
        case folder([URL])           // 文件夹 → MiniFinder
        case extended(URL?)          // MKV / WEBM 等 → 集中扩展位
    }

    enum Flavor {
        case code, markdown, link, plain

        var label: String {
            switch self {
            case .code: return "代码"
            case .markdown: return "Markdown"
            case .link: return "链接"
            case .plain: return "文本"
            }
        }
    }

    /// 系统 Quick Look 不支持、必须在本模块追加渲染分支的容器/编码。
    /// 新增一种格式＝往这里加一个扩展名 + 在 body 里加一个 case。
    static let extendedFormats: Set<String> = [
        "mkv", "webm", "flv", "m2ts", "mts", "ts", "avi", "wmv", "rmvb", "vob"
    ]

    static func resolve(_ item: HistoryItem) -> Content {
        let urls = item.fileURLs

        // 单个目录 → 复用 Mini Finder（§17.8.2 复用行）。
        if urls.count == 1, urls[0].hasDirectoryPath {
            return .folder(urls)
        }
        // 扩展位优先于通用文件预览：MKV/WEBM 交给集中分支，而非 QLPreviewView 空白。
        if let first = urls.first,
           extendedFormats.contains(first.pathExtension.lowercased()) {
            return .extended(first)
        }
        // 其它文件（PDF / 视频 / Doc / 图片文件）→ 借系统 QLPreviewView。
        if let first = urls.first {
            return .systemFile(first)
        }
        // 剪贴板内嵌位图（无 fileURL）→ 系统解码的 NSImage。
        // [A-1] 预览走缩略图管线的 preview 尺寸（长边 2560），不再展开 8K 原图。
        if let data = item.imageData,
           let image = ThumbnailCache.shared.previewImage(forData: data) {
            return .image(image)
        }

        let body = item.previewableText
        // 纯链接 → 自绘网页骨架 + 地址栏，并可直接打开（原型 quickLookBody.url）。
        if let url = ClipKind.firstURL(in: body),
           url.absoluteString == body.trimmingCharacters(in: .whitespacesAndNewlines) {
            return .text(body, .link)
        }
        // Markdown 特征 → 自绘标题/粗体/行内代码。
        if body.contains("```") || body.contains("**") || body.hasPrefix("# ") || body.contains("\n# ") {
            return .text(body, .markdown)
        }
        // 代码特征 → 等宽只读。
        if ClipKind.derive(types: item.contents.map(\.type), text: body) == .code {
            return .text(body, .code)
        }
        return .text(body, .plain)
    }
}

// MARK: - 主视图

struct QuickLookView: View {
    let item: HistoryItem
    let onDone: () -> Void

    private let content: QuickLookResolver.Content

    init(item: HistoryItem, onDone: @escaping () -> Void) {
        self.item = item
        self.onDone = onDone
        self.content = QuickLookResolver.resolve(item)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            previewBody
            Divider()
            footer
        }
        .frame(width: 720, height: 520)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(radius: 24, y: 8)
    }

    // MARK: header — 带系统 Quick Look 没有的上下文

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "space")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("超级 Quick Look").font(.system(size: 13, weight: .semibold))
                Text("空格键 · 图片 / MP4 / PDF / Doc / Markdown / 代码 统一预览 · 由 Space Station 接管 · 非系统 Quick Look")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                if let prediction = predictionLine {
                    Label(prediction, systemImage: "wand.and.stars")
                        .font(.system(size: 10)).foregroundStyle(.tint)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button(action: onDone) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭 (Esc / 空格)")
        }
        .padding(14)
    }

    private var predictionLine: String? {
        guard let actionID = item.predictedActionID else { return nil }
        let label = ActionRegistry.byID[actionID]?.label ?? actionID
        if let reason = item.predictionReason, !reason.isEmpty {
            return "预测：\(label) · \(reason)"
        }
        return "预测：\(label)"
    }

    // MARK: body — 一个 switch 集中所有渲染器

    @ViewBuilder
    private var previewBody: some View {
        switch content {
        case .image(let image):
            imagePreview(image)
        case .systemFile(let url):
            QLFilePreview(url: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .text(let text, let flavor):
            textPreview(text, flavor: flavor)
        case .folder(let urls):
            MiniFinder(urls: urls, onDone: onDone)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .extended(let url):
            extendedPreview(url)
        }
    }

    private func imagePreview(_ image: NSImage) -> some View {
        ZStack {
            Color.black.opacity(0.55)
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(20)
                .shadow(radius: 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func textPreview(_ text: String, flavor: QuickLookResolver.Flavor) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(flavor.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                if flavor == .markdown, let attributed = try? AttributedString(markdown: text) {
                    Text(attributed)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if flavor == .code {
                    Text(text)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if flavor == .link {
                    linkPreview(text)
                } else {
                    Text(text)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func linkPreview(_ text: String) -> some View {
        let display = ClipKind.firstURL(in: text)?.host ?? text
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "globe").foregroundStyle(.tint)
                Text(display).font(.system(size: 18, weight: .semibold))
            }
            RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.25)).frame(height: 6)
            RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15)).frame(height: 6)
            RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.25)).frame(width: 220, height: 6)
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let url = ClipKind.firstURL(in: text), url.scheme != nil {
                Button("在默认浏览器打开") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.borderless).font(.system(size: 11))
            }
        }
    }

    /// MKV / WEBM 等扩展位：系统 Quick Look 渲染不了，集中在这里给可读占位 +
    /// 默认 App 打开。将来新增渲染分支只改本函数（§17.8.1 / §21.8）。
    private func extendedPreview(_ url: URL?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "film").font(.system(size: 40)).foregroundStyle(.secondary)
            Text(url?.lastPathComponent ?? "该格式").font(.system(size: 14, weight: .semibold))
            Text("系统 Quick Look 不支持此容器，已交由本模块扩展位处理。新格式在此模块集中追加渲染分支。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let url, FileManager.default.fileExists(atPath: url.path) {
                Button("用默认 App 打开") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: footer — 统一只读 + 一键复制

    private var footer: some View {
        HStack {
            Text("来源 \(item.application ?? "未知 App") · \(kindLabel)")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer()
            // 阶段三：对已有图片直接翻译 / 标注（面板先关，再开全屏能力）
            if case .image(let image) = content {
                Button {
                    onDone()
                    Task { @MainActor in
                        await TranslateOverlayController.shared.translate(image: image)
                    }
                } label: {
                    Label("原图翻译", systemImage: "globe")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("OCR + 翻译，磨砂覆盖层展示译文")
                Button {
                    onDone()
                    AnnotationOverlayController.shared.annotate(image: image)
                } label: {
                    Label("标注", systemImage: "pencil.tip")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("画笔 / 箭头 / 文字 / 马赛克，完成后存为新图卡")
            }
            if let copiable = copiableText {
                Button {
                    copy(copiable)
                } label: {
                    Label("复制内容", systemImage: "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
            }
            Text("只读 · 空格 / Esc 关闭")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(12)
    }

    private var kindLabel: String {
        ClipKind.derive(types: item.contents.map(\.type), text: item.text).cnLabel
    }

    /// 只有自绘文本类提供「复制内容」；图片/视频/PDF 只查看（§17.8）。
    private var copiableText: String? {
        switch content {
        case .text(let text, _): return text
        default: return nil
        }
    }

    /// 写入系统剪贴板，但绕过 History 捕获路径（不产生新卡），与
    /// ActionExecutor.writePlain 同一约定。
    private func copy(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }
}

// MARK: - 系统 Quick Look 渲染器（借 QLPreviewView，不自绘）

/// NSViewRepresentable 包装 AppKit 的 QLPreviewView。图片/PDF/视频/Doc
/// 全部交给系统渲染器：省内存、跟随系统更新、不重复造轮子（§17.8.2）。
private struct QLFilePreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.previewItem = url as QLPreviewItem
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        nsView.previewItem = url as QLPreviewItem
    }
}
