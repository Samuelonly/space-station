import AppKit
import CoreGraphics
import SwiftUI

/// 「原图翻译」展示控制器。
///
/// 对一张图片：OCR（带 boundingBox）→ 逐行翻译 → 用 ScreenTranslateOverlayView
/// 在原位置盖磨砂译文卡片。这是画皮画魂里「魂」的落点——磨砂材质模糊原文笔画、
/// 保留底层质感，译文盖回原位，接近 Google Lens 的体验。
@MainActor
final class TranslateOverlayController {
    static let shared = TranslateOverlayController()

    private var window: NSWindow?

    /// 对图片做原图翻译并在浮窗中展示。
    func translate(image: NSImage) async {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let size = CGSize(width: cg.width, height: cg.height)

        // 构造一个覆盖整张图的 CaptureRegion（覆盖层按 imageSize 归一化定位）
        let region = CaptureRegion(
            rectInScreenPoints: CGRect(origin: .zero, size: size),
            displayID: CGMainDisplayID(),
            scaleFactor: 1
        )

        // 1) OCR
        let lines: [OCRLine]
        do {
            lines = try await CaptureService.shared.recognize(cg)
        } catch {
            lines = []
        }
        guard !lines.isEmpty else { return }

        // 2) 逐行翻译（默认系统翻译；失败则叠原文）
        var translatedTexts: [String] = lines.map(\.text)
        do {
            let result = try await CaptureService.shared.translate(lines.map(\.text))
            translatedTexts = result.texts
        } catch {
            // 翻译不可用时保留原文，覆盖层仍能展示
        }

        let overlayLines: [OverlayLine] = zip(lines, translatedTexts).map { line, translated in
            OverlayLine(
                id: line.id,
                source: line.text,
                translated: translated,
                boundingBox: line.boundingBox
            )
        }

        // 3) session + actions
        let config = CaptureService.shared.configuration
        let session = ScreenTranslateOverlaySession(
            image: cg,
            imageSize: size,
            selection: region,
            lines: overlayLines,
            ocrServiceID: config.resolvedDefaultOCRServiceID(),
            translationServiceID: config.resolvedDefaultTranslationServiceID(),
            sourceLanguage: config.sourceLanguage,
            targetLanguage: config.targetLanguage,
            mode: .imageTranslate
        )
        let actions = ScreenTranslateOverlayActions(
            enabledOCRServices: { CaptureService.shared.enabledOCRServices() },
            enabledTranslationServices: { CaptureService.shared.enabledTranslationServices() }
        )

        // 4) 浮窗展示（尺寸上限守护，避免超大图撑爆屏幕）
        let maxSide: CGFloat = 1100
        let scale = min(1, maxSide / max(size.width, size.height))
        let winSize = NSSize(width: size.width * scale, height: size.height * scale + 64)
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: winSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "原图翻译 · Space Station"
        win.level = .floating
        win.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: TranslateOverlayHost(session: session, actions: actions))
        host.frame = NSRect(origin: .zero, size: winSize)
        win.contentView = host
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
    }
}

/// 承载覆盖层的 SwiftUI 宿主：底层原图 + 磨砂译文覆盖层。
private struct TranslateOverlayHost: View {
    let session: ScreenTranslateOverlaySession
    let actions: ScreenTranslateOverlayActions

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 底层原图
            Image(nsImage: NSImage(cgImage: session.image, size: session.imageSize))
                .resizable()
                .aspectRatio(contentMode: .fit)
            // 磨砂译文覆盖层（复用 snap-flow 的渲染 + 我们的磨砂改造）
            ScreenTranslateOverlayView(
                session: session,
                actions: actions,
                toolbarAbove: true,
                toolbarWidth: 600,
                toolbarHeight: 40
            )
        }
    }
}
