import AppKit
import Foundation

extension Notification.Name {
    /// 某个来源 App 的名称/图标解析完成（卡片据此刷新，不阻塞首帧）。
    static let sourceAppResolved = Notification.Name("SS.sourceAppResolved")
}

/// [A-2] 来源 App 中间件 —— ⑤ 来源解析口子。
///
/// 职责只有一件：`bundleID` → （本地化显示名, 16pt 图标）。
/// 契约（HTML §22.10）：
///  - 来源 App 与**预测目标 App 共用这一个实例**，不许各写一套。
///  - 解析在后台队列做：`urlForApplication` 是一次 LaunchServices 查询，
///    冷 App 可能几十毫秒，绝不能挂在首帧上。
///  - 解析失败回落 `bundleID` 原文，不显示空白。
final class SourceAppResolver: @unchecked Sendable {
    static let shared = SourceAppResolver()

    /// NSImage 不是 Sendable，故整体标注 @unchecked；只在主线程消费。
    struct Info: @unchecked Sendable {
        let bundleID: String
        let name: String
        let icon: NSImage?
    }

    private let lock = NSLock()
    private var cache: [String: Info] = [:]
    private var pending: Set<String> = []
    private let queue = DispatchQueue(
        label: "com.samuelonly.spacestation.sourceApp",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private init() {}

    /// 同步取：命中直接返回；未命中返回 nil 并在后台解析，完成后发通知。
    func info(for bundleID: String?) -> Info? {
        guard let bundleID, !bundleID.isEmpty else { return nil }

        lock.lock()
        if let hit = cache[bundleID] {
            lock.unlock()
            return hit
        }
        if pending.contains(bundleID) {
            lock.unlock()
            return nil
        }
        pending.insert(bundleID)
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let info = Self.resolve(bundleID)
            self.lock.lock()
            self.cache[bundleID] = info
            self.pending.remove(bundleID)
            self.lock.unlock()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .sourceAppResolved, object: bundleID)
            }
        }
        return nil
    }

    /// 同步强制解析（后台队列内部用，也给预测层预热目标 App 图标）。
    static func resolve(_ bundleID: String) -> Info {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            // 解析失败：名字退到 bundle id 最后一段（一级），不把 `com.apple.Safari` 整串铺到卡上。
            let short = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
            return Info(bundleID: bundleID, name: short, icon: nil)
        }
        let display = FileManager.default.displayName(atPath: url.path)
        let name = display.hasSuffix(".app") ? String(display.dropLast(4)) : display

        // 关键：`NSWorkspace.icon(forFile:)` 返回的是系统**共享缓存对象**，
        // 直接改 size 会污染全局（其它 App/我们自己别处拿到的图标都变 16pt）。
        // 复制一份再改；不改 size 也行——调用方用 .resizable() 缩放，矢量/多尺寸表示都在。
        let icon = (NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage)
            ?? NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        icon.isTemplate = false
        return Info(bundleID: bundleID, name: name, icon: icon)
    }

    /// 预热：预测层知道"下一步要送去哪个 App"时，提前把图标备好。
    func prewarm(_ bundleID: String?) {
        _ = info(for: bundleID)
    }
}
