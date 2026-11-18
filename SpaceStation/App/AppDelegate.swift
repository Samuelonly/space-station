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

    func applicationWillFinishLaunching(_ notification: Notification) {
        // `--instances`：只报告，不接管。开发态用来核对「现在跑的是哪一版」。
        // 必须放在闸门之前，否则这条命令自己会先把旧实例杀了。
        if ProcessInfo.processInfo.arguments.contains("--instances") {
            SingleInstanceGuard.report()
            exit(0)
        }

        // **单实例闸门**（§22.13）。放在最早时机：连状态栏图标都还没建，
        // 一旦要接管，旧图标绝不会留在状态栏里；一旦要让位，也不会闪一下再消失。
        SingleInstanceGuard.enforce()
    }

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
            // 第三个参数可选，用来指定看哪条边；**不写就是开发基准轴（横向顶部）**。
            //
            // 上一轮为了看左侧，命令行里显式传了 dockEdge，于是“这次该拍哪边”
            // 变成每轮开工前的第一个选择题，而且拍错了才发现——这就是盲盒。
            // 现在默认横向，纵向只有显式点名才拍。
            let explicit = (idx + 2 < args.count) ? EdgePosition(rawValue: args[idx + 2]) : nil
            let target = explicit ?? EdgePosition.developmentBaseline
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self else { return }
                // open() 会以 stationState.edge 为准重算尺寸，所以在这里改就够；
                // 走内存状态而不是 UserDefaults，快照**不会**把用户设置改脏。
                self.stationState.edge = target
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

// MARK: - 单实例闸门（§22.13）

/// 用户原话（2026-11-18 12:30，写 §22.13 那一条时）：
///
/// > 「如果用户更新了，或者是他崩溃了，重启了，可能会有两个同一进程，
/// >   这个需要判断，按照先后顺序杀死那个之前的进程。
/// >   就这个本身对于我们在开发阶段的 Feedback 也很重要，然后对于用户也很重要，
/// >   因为万一他连续双击打开，他可能就卡死了。」
///
/// 所以这一道闸门的语义是 **新进程接管、旧进程被杀掉**，不是「新进程退出去」。
/// 第一版做反了（旧实例留着、新进程 exit），后果正是用户担心的那件事：
/// 改完编译、启动，看到的还是上一版界面 —— 旧进程没死，新包自己退了。
/// 更糟的是旧进程一旦卡死（不理事件循环），就永远没人能接管，只能手动 kill。
///
/// **开发状态检测**：判定依据不是「谁先启动」这么粗，而是先把每个实例的事实读出来——
/// 可执行文件路径、构建时间（可执行文件 mtime）、进程启动时间——再决定：
///
/// | 情况 | 判定 | 动作 |
/// |---|---|---|
/// | 已在跑的包**构建时间更新**（用旧包顺手启动） | 本包是陈旧的 | 本进程退出，激活那个新的 |
/// | 同一份二进制被重新链接（路径相同，两边 mtime 都变成新构建时间） | 比启动时间 | 本进程接管，杀旧进程 |
/// | 两份拷贝（`build/` 与 `.build/`），旧的那份 mtime 更早 | 对方陈旧 | 本进程接管，杀旧进程 |
/// | 旧进程卡死、不理 SIGTERM | 2 秒后仍存活 | SIGKILL 兜底再启动 |
enum SingleInstanceGuard {
    /// 一份运行中实例的**可核验事实**。全部来自系统，不做推断。
    struct Instance: Equatable {
        let pid: pid_t
        let path: String
        /// 可执行文件修改时间 = 构建时间。构建完没动过，改完重编就变。
        let builtAt: Date?
        /// 进程启动时间。
        let launchedAt: Date?
    }

    enum Verdict: Equatable {
        /// 杀掉这些旧进程，本进程继续启动。
        case takeOver(stale: [pid_t])
        /// 本包比正在跑的更旧，让位给它。
        case yieldTo(pid: pid_t)
    }

    /// SIGTERM 之后等多久才动 SIGKILL。2 秒足够正常退出，又不至于让用户盯着空转。
    static let graceSeconds: TimeInterval = 2.0

    // MARK: 判定（纯函数，可被 L1 自检直接调用）

    static func decide(mine: Instance, others: [Instance]) -> Verdict {
        let newer = others.filter { isNewer($0, than: mine) }
        if let target = newer.max(by: { ($0.builtAt ?? .distantPast) < ($1.builtAt ?? .distantPast) }) {
            return .yieldTo(pid: target.pid)
        }
        return .takeOver(stale: others.map(\.pid))
    }

    /// `a` 是否比 `b` 新。先看构建时间；两边构建时间相同（同一份二进制被重新链接，
    /// 磁盘上只剩最后一次的 mtime）时退回启动时间。
    static func isNewer(_ a: Instance, than b: Instance) -> Bool {
        if let ab = a.builtAt, let bb = b.builtAt, abs(ab.timeIntervalSince(bb)) > 2 {
            return ab > bb
        }
        guard let al = a.launchedAt, let bl = b.launchedAt else { return false }
        return al > bl
    }

    // MARK: 执行

    @MainActor
    static func enforce() {
        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else { return }
        let me = currentInstance()
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me.pid }
            .map(instance(from:))
        guard !others.isEmpty else { return }

        switch decide(mine: me, others: others) {
        case .yieldTo(let pid):
            // 用旧包启动时不该把新包杀掉 —— 让位，并把新的拉到前面。
            NSLog("[SingleInstance] 已在运行的 pid %d 比本包更新（本包 %@ 构建于 %@）→ 本进程（pid %d）让位退出",
                  pid, me.path, stamp(me.builtAt), me.pid)
            NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps])
            exit(0)

        case .takeOver(let stale):
            for pid in stale {
                let target = others.first { $0.pid == pid } ?? Instance(pid: pid, path: "?", builtAt: nil, launchedAt: nil)
                NSLog("[SingleInstance] 接管：旧实例 pid %d 构建于 %@（%@），本包构建于 %@ → 结束旧的",
                      pid, stamp(target.builtAt), target.path, stamp(me.builtAt))
                terminate(pid)
            }
        }
    }

    /// 先 SIGTERM，等 `graceSeconds`，还活着就 SIGKILL。
    /// 卡死的进程不会处理 SIGTERM，这一步不是防御性代码，是必需路径。
    private static func terminate(_ pid: pid_t) {
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(graceSeconds)
        while Date() < deadline {
            if kill(pid, 0) != 0 {          // ESRCH：已经没了
                NSLog("[SingleInstance] 旧实例 pid %d 已按 SIGTERM 退出", pid)
                return
            }
            usleep(50_000)
        }
        kill(pid, SIGKILL)
        usleep(200_000)
        NSLog("[SingleInstance] 旧实例 pid %d 对 SIGTERM %.0f 秒无响应（疑似卡死），已 SIGKILL",
              pid, graceSeconds)
    }

    // MARK: 事实采集

    static func currentInstance() -> Instance {
        // 本进程的 `launchDate` 在 `willFinishLaunching` 阶段还查不到（返回 nil），
        // 直接用当下时间：我们就是这一秒起来的。
        instance(pid: ProcessInfo.processInfo.processIdentifier,
                 path: Bundle.main.executableURL?.path ?? "",
                 launchedAt: Date())
    }

    static func instance(from app: NSRunningApplication) -> Instance {
        instance(pid: app.processIdentifier,
                 path: app.executableURL?.path ?? "",
                 launchedAt: app.launchDate)
    }

    static func instance(pid: pid_t, path: String, launchedAt: Date? = nil) -> Instance {
        Instance(
            pid: pid,
            path: path,
            builtAt: path.isEmpty ? nil : buildDate(of: path),
            launchedAt: launchedAt ?? NSRunningApplication(processIdentifier: pid)?.launchDate
        )
    }

    private static func buildDate(of path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private static func stamp(_ date: Date?) -> String {
        guard let date else { return "未知" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    /// `--instances`：把「现在到底跑着几个、分别是谁、多旧」直接打出来。
    /// 开发态最难查的不是崩溃，是「我以为在跑新版，其实跑着旧版」。
    @MainActor
    static func report() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let all = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .map(instance(from:))
        print("[Instances] 同 bundleID 共 \(all.count) 个进程")
        for item in all.sorted(by: { ($0.launchedAt ?? .distantPast) < ($1.launchedAt ?? .distantPast) }) {
            let mine = item.pid == ProcessInfo.processInfo.processIdentifier ? " ←本进程" : ""
            print("  pid \(item.pid)  构建 \(stamp(item.builtAt))  启动 \(stamp(item.launchedAt))  \(item.path)\(mine)")
        }
    }
}
