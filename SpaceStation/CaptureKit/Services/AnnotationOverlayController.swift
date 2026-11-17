import AppKit
import SwiftUI

/// 对一张已有图片做标注（阶段三 QuickLook 入口）。
/// 标注画布是 AppKit NSView，需要 NSWindow 承载：底层铺原图，上面盖透明画布，
/// 顶部一排工具按钮 + AnnotateOptionsBar 样式面板。完成后标注结果作为新图卡入库。
@MainActor
final class AnnotationOverlayController: NSObject, NSWindowDelegate {
    static let shared = AnnotationOverlayController()

    private var window: NSWindow?
    private var canvas: AnnotationCanvasView?
    private var optionsBar: AnnotateOptionsBar?
    private var toolButtons: [AnnotateTool: NSButton] = [:]

    private let tools: [AnnotateTool] = [
        .none, .shape, .arrow, .pen, .highlighter, .text, .mosaic, .number, .eraser
    ]

    /// 对图片打开标注窗口。
    func annotate(image: NSImage) {
        // 已有窗口先关掉，避免叠加
        closeWindow()

        let imgSize = image.size
        guard imgSize.width > 0, imgSize.height > 0 else { return }

        // 容器视图：底图 + 透明画布 + 工具栏
        let canvasHolder = NSView(frame: NSRect(origin: .zero, size: imgSize))

        let base = NSImageView(frame: NSRect(origin: .zero, size: imgSize))
        base.image = image
        base.imageScaling = .scaleProportionallyUpOrDown
        base.autoresizingMask = [.width, .height]
        canvasHolder.addSubview(base)

        let drawCanvas = AnnotationCanvasView(frame: NSRect(origin: .zero, size: imgSize))
        drawCanvas.baseImage = image
        drawCanvas.managesCursor = true
        drawCanvas.autoresizingMask = [.width, .height]
        canvasHolder.addSubview(drawCanvas)
        self.canvas = drawCanvas

        // 窗口尺寸：图 + 顶部工具区
        let toolbarH: CGFloat = 78
        let winSize = NSSize(width: imgSize.width, height: imgSize.height + toolbarH)

        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: winSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        win.title = "标注 · Space Station"
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 420, height: 320)
        win.center()

        let root = NSView(frame: NSRect(origin: .zero, size: winSize))
        root.autoresizingMask = [.width, .height]

        // 工具栏容器（顶部）
        let toolbar = NSView(frame: NSRect(x: 0, y: imgSize.height, width: imgSize.width, height: toolbarH))
        toolbar.autoresizingMask = [.width]
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        // 工具按钮行
        let buttonH: CGFloat = 26
        var x: CGFloat = 8
        for tool in tools {
            let btn = NSButton(title: tool.title, target: self, action: #selector(selectTool(_:)))
            btn.bezelStyle = .rounded
            btn.font = .systemFont(ofSize: 11)
            btn.frame = NSRect(x: x, y: toolbarH - buttonH - 6, width: 58, height: buttonH)
            btn.tag = tools.firstIndex(of: tool) ?? 0
            btn.state = tool == .none ? .on : .off
            toolbar.addSubview(btn)
            toolButtons[tool] = btn
            x += 62
        }
        // 撤销 / 重做
        for (idx, sel, title) in [(0, #selector(undo(_:)), "撤销"), (1, #selector(redo(_:)), "重做")] {
            let btn = NSButton(title: title, target: self, action: sel)
            btn.bezelStyle = .rounded
            btn.font = .systemFont(ofSize: 11)
            btn.frame = NSRect(x: x, y: toolbarH - buttonH - 6, width: 46, height: buttonH)
            toolbar.addSubview(btn)
            x += 50
        }
        // 完成按钮（右）
        let done = NSButton(title: "完成并保存", target: self, action: #selector(finish(_:)))
        done.bezelStyle = .rounded
        done.font = .systemFont(ofSize: 11, weight: .semibold)
        done.frame = NSRect(x: imgSize.width - 106, y: toolbarH - buttonH - 6, width: 98, height: buttonH)
        done.autoresizingMask = [.minXMargin]
        toolbar.addSubview(done)

        // 样式面板（第二行），初始隐藏，选工具后显示
        let bar = AnnotateOptionsBar(frame: NSRect(x: 8, y: 4, width: imgSize.width - 16, height: 40))
        bar.autoresizingMask = [.width]
        bar.isHidden = true
        bar.onChange = { [weak self] style in
            Task { @MainActor in self?.canvas?.apply(options: style) }
        }
        toolbar.addSubview(bar)
        self.optionsBar = bar

        root.addSubview(toolbar)

        // 画布区（工具栏以下），随窗口缩放
        canvasHolder.frame = NSRect(x: 0, y: 0, width: imgSize.width, height: imgSize.height)
        canvasHolder.autoresizingMask = [.width, .height]
        root.addSubview(canvasHolder)

        win.contentView = root
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
    }

    @objc private func selectTool(_ sender: NSButton) {
        guard let tool = tools[safe: sender.tag] else { return }
        for (t, btn) in toolButtons { btn.state = (t == tool) ? .on : .off }
        let c = canvas
        if tool == .undo { c?.undo(); return }
        if tool == .redo { c?.redo(); return }
        c?.commitTextIfNeeded()
        c?.tool = tool
        if tool == .none {
            optionsBar?.isHidden = true
        } else {
            optionsBar?.isHidden = false
            optionsBar?.show(for: tool, preferredStyle: nil)
        }
    }

    @objc private func undo(_ sender: Any?) { canvas?.undo() }
    @objc private func redo(_ sender: Any?) { canvas?.redo() }

    @objc private func finish(_ sender: Any?) {
        guard let image = canvas?.compositeImage() else { closeWindow(); return }
        // 标注结果作为新图卡入库
        guard let payload = SnipImageExport.encode(image, quality: 100) else { closeWindow(); return }
        let item = HistoryItem()
        item.application = "Space Station · 标注"
        item.title = "标注 · \(Int(image.size.width))×\(Int(image.size.height))"
        item.contents = [HistoryItemContent(
            type: NSPasteboard.PasteboardType.tiff.rawValue,
            value: payload.data
        )]
        History.shared.add(item)
        closeWindow()
    }

    func windowWillClose(_ notification: Notification) { closeWindow() }

    private func closeWindow() {
        window?.orderOut(nil)
        window = nil
        canvas = nil
        optionsBar = nil
        toolButtons.removeAll()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
