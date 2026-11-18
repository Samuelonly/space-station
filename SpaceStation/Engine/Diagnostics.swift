import AppKit
import Foundation
import os

/// [A-5] 反馈底座 —— 我们自己的度量，不是产品功能（HTML §22.12）。
///
/// 三条硬规矩：
///  1. 拒绝入库的记录**只记类目与时间，绝不记内容**（隐私 + 体积）。
///  2. 所有计数都在锁内更新，读快照不阻塞主线程太久。
///  3. 面板优先原则的配套：这里任何一项失败都不许抛给上层，只标记为红字。
///
/// 唯一的进程内单例，状态跨线程，按既有约定用 NSLock + @unchecked Sendable。
final class Diagnostics: @unchecked Sendable {
    static let shared = Diagnostics()

    /// Instruments 里按 subsystem 过滤即可看到十二个口子的耗时。
    static let signposter = OSSignposter(subsystem: "com.samuelonly.spacestation", category: "station")

    struct Rejection: Sendable {
        let category: String
        let at: Date
    }

    struct Snapshot: Sendable {
        var thumbnailHits = 0
        var thumbnailMisses = 0
        var thumbnailBytes = 0
        var diskBytes: Int64 = 0
        var historyCount = 0
        var residentBytes: Int64 = 0
        var rejections: [Rejection] = []
        var unimplemented: [String] = []
        var cleanExit = true
        var tidyRuns = 0
        var tidyFreedBytes = 0
    }

    struct Check: Sendable, Identifiable {
        let id = UUID()
        let title: String
        let ok: Bool
        let detail: String
    }

    private let lock = NSLock()
    private var hits = 0
    private var misses = 0
    private var thumbBytes = 0
    private var disk: Int64 = 0
    private var history = 0
    private var rejections: [Rejection] = []
    private var unimplemented: [String] = []
    private var tidyRuns = 0
    private var tidyFreedBytes = 0

    private static let maxLog = 20
    private static let cleanExitKey = "SS.lastCleanExit"

    private init() {}

    // MARK: - 写入（各口子调用）

    func recordThumbnail(hit: Bool) {
        lock.lock()
        if hit { hits += 1 } else { misses += 1 }
        lock.unlock()
    }

    func setThumbnailBytes(_ value: Int) {
        lock.lock(); thumbBytes = value; lock.unlock()
    }

    func setDiskBytes(_ value: Int64) {
        lock.lock(); disk = value; lock.unlock()
    }

    func setHistoryCount(_ value: Int) {
        lock.lock(); history = value; lock.unlock()
    }

    /// ③ 隐私门的拒绝只留类目，不留内容。
    func recordRejection(category: String) {
        lock.lock()
        rejections.append(Rejection(category: category, at: Date()))
        if rejections.count > Self.maxLog { rejections.removeFirst(rejections.count - Self.maxLog) }
        lock.unlock()
    }

    /// ⑨ 动作分发的「未实现」必须留痕，否则死按钮永远查不出来。
    func recordUnimplemented(actionID: String) {
        lock.lock()
        unimplemented.append(actionID)
        if unimplemented.count > Self.maxLog { unimplemented.removeFirst(unimplemented.count - Self.maxLog) }
        lock.unlock()
    }

    /// 收起后的内存整理（§22.14）：记次数与最近一次释放量，用来判断频率定得对不对。
    func recordMemoryTidy(freedBytes: Int) {
        lock.lock()
        tidyRuns += 1
        tidyFreedBytes = freedBytes
        lock.unlock()
    }

    // MARK: - 读取

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        var snap = Snapshot()
        snap.thumbnailHits = hits
        snap.thumbnailMisses = misses
        snap.thumbnailBytes = thumbBytes
        snap.diskBytes = disk
        snap.historyCount = history
        snap.residentBytes = Self.physicalFootprint()
        snap.rejections = rejections
        snap.unimplemented = unimplemented
        snap.cleanExit = UserDefaults.standard.bool(forKey: Self.cleanExitKey)
        snap.tidyRuns = tidyRuns
        snap.tidyFreedBytes = tidyFreedBytes
        return snap
    }

    /// 常驻内存用 phys_footprint，不用 resident_size —— 后者会把共享库算重。
    static func physicalFootprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    // MARK: - 干净退出标记（崩溃恢复用，HTML §22.13）

    func markLaunched() {
        UserDefaults.standard.set(false, forKey: Self.cleanExitKey)
    }

    func markCleanExit() {
        UserDefaults.standard.set(true, forKey: Self.cleanExitKey)
    }

    // MARK: - 启动自检（10 项）

    @MainActor
    func runSelfChecks() -> [Check] {
        var checks: [Check] = []

        // 1. 缓存目录可写
        let dir = ThumbnailCache.shared.directoryURL
        let writable = FileManager.default.isWritableFile(atPath: dir.path)
        checks.append(Check(title: "缩略图目录可写", ok: writable, detail: dir.path))

        // 2. 缩略图目录未超限
        let diskBytes = ThumbnailCache.shared.currentDiskBytes()
        let diskOK = diskBytes <= ThumbnailCache.diskByteLimit
        checks.append(Check(
            title: "缩略图磁盘占用",
            ok: diskOK,
            detail: "\(Self.mb(diskBytes)) / 上限 \(Self.mb(ThumbnailCache.diskByteLimit))"
        ))

        // 3. 数据库可读
        let dbURL = URL.applicationSupportDirectory.appending(path: "SpaceStation/Storage.sqlite")
        let dbOK = FileManager.default.fileExists(atPath: dbURL.path)
        checks.append(Check(title: "数据库存在", ok: dbOK, detail: dbOK ? "Storage.sqlite" : "首次运行尚无库"))

        // 4. 剪贴板可用
        let pasteboardOK = NSPasteboard.general.types != nil
        checks.append(Check(title: "剪贴板可访问", ok: pasteboardOK, detail: "NSPasteboard.general"))

        // 5. 状态栏可用
        let statusOK = NSStatusBar.system.thickness > 0
        checks.append(Check(title: "状态栏可用", ok: statusOK, detail: "thickness \(NSStatusBar.system.thickness)"))

        // 6. 屏幕参数
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let screenOK = screen.width > 0 && screen.height > 0
        checks.append(Check(title: "屏幕参数", ok: screenOK, detail: "\(Int(screen.width))×\(Int(screen.height))"))

        // 7. 辅助功能权限（只报告，不阻断 —— 未授权时 ⌥↵ 降级）
        let axOK = AXIsProcessTrusted()
        checks.append(Check(title: "辅助功能权限", ok: true, detail: axOK ? "已授权（⌥↵ 可直接粘贴）" : "未授权（⌥↵ 降级为仅复制）"))

        // 8. 上次是否干净退出
        let clean = UserDefaults.standard.bool(forKey: Self.cleanExitKey)
        checks.append(Check(title: "上次退出状态", ok: clean, detail: clean ? "正常退出" : "上次异常退出（崩溃或被强杀）"))

        // 9. 系统版本（我们只支持 15+）
        let os = ProcessInfo.processInfo.operatingSystemVersion
        checks.append(Check(
            title: "系统版本",
            ok: os.majorVersion >= 15,
            detail: "macOS \(os.majorVersion).\(os.minorVersion)"
        ))

        // 10. 进程唯一性。**这只是报告，不是闸门**——真正的阻止在
        // `AppDelegate.applicationWillFinishLaunching` 的 `SingleInstanceGuard`
        // 和 Info.plist 的 `LSMultipleInstancesProhibited`。
        // 2026-11-18 的教训：光有这条检查，`open -n` 一按还是两个图标。
        let instances = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? ""
        ).count
        checks.append(Check(title: "进程唯一性", ok: instances <= 1, detail: "同 bundleID 进程数 \(instances)"))

        return checks
    }

    private static func mb(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}
