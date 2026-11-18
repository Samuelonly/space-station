import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var stationState = StationState()
    private var panel: FloatingPanel<StationPanel>!

    @objc private lazy var statusItem: NSStatusItem = {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.behavior = .removalAllowed
        statusItem.button?.image = Self.icon(for: .normal)
        statusItem.button?.imagePosition = .imageLeft
        // Right-click must also reach our action so we can open Settings
        // (self-developed; right-click handler is our addition, §21.10).
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.target = self
        statusItem.button?.action = #selector(performStatusItemClick)
        Self.applyPillBackground(statusItem.button)
        return statusItem
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // [A-5] 先落“未干净退出”标记：下次启动如果还看到 false，就是异常退出。
        Diagnostics.shared.markLaunched()
        _ = statusItem

        panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: stationState.edge.panelSize),
            identifier: "com.samuelonly.spacestation.panel",
            statusBarButton: statusItem.button,
            stationState: stationState
        ) {
            StationPanel()
        }

        // M4: panel-local keyboard flow. Gated on the panel actually being open.
        KeyboardRouter.shared.install(state: stationState) { [weak self] in
            self?.panel.isPresented ?? false
        }

        // 换边：stationState.edge 是唯一真源，面板的“收进→延迟→展开”由这里驱动。
        observeEdgeChanges()

        // [A-6] 视觉验收通道：`--show` 启动即打开面板。
        // 加这个是因为本机 `screencapture` 对全屏截图被权限挡住，
        // 只有把面板打开成真实窗口，才能按 window id 单独抓它。
        // 对普通用户无影响（正常启动不带参数）。
        if ProcessInfo.processInfo.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.panel.open()
            }
        }

        // [A-6] `--snapshot <path>`：把面板自己渲染成 PNG 后退出。
        // 为什么要这条：本机没有屏幕录制权限，`screencapture` 连单窗口都拿不到；
        // 而“改完看不见”是这三个稿子最大的成本。现在改完能自己出图核对布局。
        // 注意：`NSVisualEffectView` 的模糊由窗口服务器合成，离屏渲染里是透明的——
        // 所以这张图用来看**布局/尺寸/字体/卡数**，不用来判断玻璃浓度。
        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: "--snapshot"), idx + 1 < args.count {
            let path = args[idx + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self else { return }
                self.panel.open()
                // 等缩略图解码 + SwiftUI 首帧布局落地。
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    self.writeSnapshot(of: self.panel, to: path)
                    NSApp.terminate(nil)
                }
            }
        }

        // M1 engine startup: storage healing -> load -> capture hook -> timer.
        Task { @MainActor in
            try? Storage.shared.cleanupOrphanedContents()
            try? Storage.shared.removeUnpersistableContents()
            try? Storage.shared.sanitizeTitles()
            try? await History.shared.load()
            Diagnostics.shared.setHistoryCount(History.shared.items.count)
            // [A-4] 启动先扫一次磁盘，让诊断面板有真实数值。
            _ = ThumbnailCache.shared.enforceDiskLimit()
            History.shared.cleanupExpired() // §17.10 retention (pin-exempt, 0=never)

            // HTML §21.4 pin #1 (capture port). M3: prediction metadata.
            // M4: consume Undo's one-shot suppression (so the restore write
            // doesn't create a card), then record each real clip for Undo.
            Clipboard.shared.onNewCopy { item in
                if ClipboardUndo.shared.shouldSuppressCapture() { return }
                if let prediction = PredictionEngine.predictForCapture(item: item) {
                    item.predictedActionID = prediction.actionID
                    item.predictionReason = prediction.reason
                }
                History.shared.add(item)
                Diagnostics.shared.setHistoryCount(History.shared.items.count)
                ClipboardUndo.shared.record(item)
            }
            Clipboard.shared.start()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        togglePanel()
        return true
    }

    /// 观察换边：设置里改了 `stationState.edge` → 面板先收进、静置、再在新边展开。
    /// 用 `withObservationTracking` 单点订阅并自重挂载（改动只会发生在主线程）。
    private func observeEdgeChanges() {
        withObservationTracking {
            _ = stationState.edge
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.panel.switchEdge(to: self.stationState.edge)
                self.observeEdgeChanges()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // [A-5] 正常退出才置 true；下次启动读它区分“异常退出”。
        Diagnostics.shared.markCleanExit()
    }

    // MARK: - [A-6] 视觉快照（开发通道）

    /// 把窗口内容渲染成 2× PNG。
    ///
    /// 两条路：先试 `CGWindowListCreateImage` 抓**自己这个窗口**（合成后的真实像素，
    /// 含玻璃模糊与阴影）；拿不到再回落 `cacheDisplay`（只有布局，没有阴影/玻璃）。
    /// 前者是本进程截本进程，不走屏幕录制授权；后者不需要任何权限但会丢效果。
    private func writeSnapshot(of window: NSWindow, to path: String) {
        // 诊断：SwiftUI 的 `.shadow()` 是走 CALayer 的 shadow* 属性，
        // 还是走绘制指令。前者离屏拿不到、真实窗口有；后者两边都有。
        // 结论（2026-11-18 实测）：走 CALayer —— 所以 `cacheDisplay` 出来的图
        // **没有阴影**，不能用它判断投影轻重，只能判断布局。
        if let root = window.contentView?.layer {
            var count = 0
            func walk(_ l: CALayer) {
                if l.shadowOpacity > 0 { count += 1 }
                for sub in l.sublayers ?? [] { walk(sub) }
            }
            walk(root)
            NSLog("[A-6] shadow layers = %d（>0 说明阴影存在，只是离屏渲染不包含它）", count)
        }

        // 视图自绘（丢了阴影和玻璃，但布局/文字/间距是真的）。
        guard let view = window.contentView else { return }
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width * scale),
            pixelsHigh: Int(bounds.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }
        rep.size = bounds.size
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            NSColor(calibratedWhite: 0.42, alpha: 1).setFill()
            bounds.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        NSLog("[A-6] snapshot via cacheDisplay (no shadow/glass)")
    }

    // MARK: - Status item gestures (modifier logic per §21.10;
    // right-click / pill background are our additions).

    @objc private func performStatusItemClick() {
        let event = NSApp.currentEvent
        // Right-click -> context menu (Settings + Capture entry, §阶段三).
        if event?.type == .rightMouseUp || event?.type == .rightMouseDown {
            let menu = NSMenu()
            let capture = NSMenuItem(title: "截图 / 标注", action: #selector(startCapture), keyEquivalent: "")
            capture.target = self
            menu.addItem(capture)
            let captureTranslate = NSMenuItem(title: "截图并原图翻译", action: #selector(startCaptureTranslate), keyEquivalent: "")
            captureTranslate.target = self
            menu.addItem(captureTranslate)
            menu.addItem(NSMenuItem.separator())
            let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: "")
            settings.target = self
            menu.addItem(settings)
            #if DEBUG
            menu.addItem(NSMenuItem.separator())
            let diagnostics = NSMenuItem(title: "诊断面板…", action: #selector(openDiagnostics), keyEquivalent: "")
            diagnostics.target = self
            menu.addItem(diagnostics)
            #endif
            menu.addItem(NSMenuItem.separator())
            // 常驻 agent 应用没有主菜单，系统 ⌘Q 不会自己出现，必须自己给出口。
            let quit = NSMenuItem(title: "退出 Space Station", action: #selector(quitApp), keyEquivalent: "q")
            quit.target = self
            menu.addItem(quit)
            // 直接弹出，避免给 button 挂 menu 后 performClick 再次触发本方法（递归）。
            if let button = statusItem.button {
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
            }
            return
        }

        let modifierFlags = (event?.modifierFlags ?? [])
            .union(NSEvent.modifierFlags)
            .intersection(.deviceIndependentFlagsMask)

        if modifierFlags.contains(.option) {
            SS.ignoreEvents.toggle()
            if modifierFlags.contains(.shift) {
                SS.ignoreOnlyNextEvent = SS.ignoreEvents
            }
            refreshStatusIcon()
            return
        }

        togglePanel()
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show(state: stationState)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    #if DEBUG
    /// [A-5] 仅 DEV：打开诊断面板（发布包里这个方法根本不存在）。
    @objc private func openDiagnostics() {
        DiagnosticsWindowController.shared.show()
    }
    #endif

    /// 阶段三：全屏框选 → 标注 → 入库。截图结果作为图片卡插入 History。
    @objc private func startCapture() {
        Task { @MainActor in
            _ = await CaptureIntegration.captureToHistory()
        }
    }

    /// 阶段三：全屏框选 → 原图 OCR + 翻译 → 磨砂覆盖层展示。
    @objc private func startCaptureTranslate() {
        Task { @MainActor in
            guard let result = await CaptureService.shared.captureRegion() else { return }
            await TranslateOverlayController.shared.translate(image: result.image)
        }
    }

    @objc private func togglePanel() {
        panel.toggle()
    }

    // MARK: - Icon three states + gray pill contrast (§21.10 self-developed)

    private enum IconState { case normal, paused, ignoreOnce }

    private func refreshStatusIcon() {
        let state: IconState = SS.ignoreEvents
            ? .paused
            : (SS.ignoreOnlyNextEvent ? .ignoreOnce : .normal)
        statusItem.button?.image = Self.icon(for: state)
    }

    private static func icon(for state: IconState) -> NSImage? {
        let name: String
        switch state {
        case .normal:     name = "clipboard"
        case .paused:     name = "clipboard.fill"     // visually distinct paused state
        case .ignoreOnce: name = "clipboard.badge.clock"
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: "Space Station")
    }

    /// Gray pill底 raises contrast against the menu bar without showing counts.
    private static func applyPillBackground(_ button: NSStatusBarButton?) {
        guard let button else { return }
        button.wantsLayer = true
        button.layer?.cornerRadius = 5
        button.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.18).cgColor
    }
}
