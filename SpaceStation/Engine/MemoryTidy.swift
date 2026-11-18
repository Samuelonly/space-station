import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// 面板收起后的「悄悄整理」——不是产品功能，是让常驻应用对笔记本友好一点。
///
/// 为什么需要它：我们这个 App 常驻内存 40–46MB，其中大头是已解码的缩略图位图。
/// 用户用完就走（收起面板），这些位图就白占着。但**不能一收起就清**——
/// 那等于每次重开都要重新解码，用户感知到的是「打开变慢」，比多占几十兆更糟。
///
/// 所以三道门全过才动手：
///  1. **频率门**：距上次 ≥ `minimumInterval`（默认 300s）。时间戳写进 UserDefaults，
///     重启也不会重置；连续开关（开→用→关→马上再开）一次都不触发。
///  2. **电源门**：系统处于低电量模式时直接跳过（用户在意 MacBook 续航）。
///  3. **静置门**：收起后先等 `settleDelay`（3s）再动手；这期间若面板又被打开，
///     任务直接取消——「悄悄」的意思是用户永远不该察觉到我们在干活。
///
/// 需要调频率只改 `minimumInterval` 一个数（HTML §22.14）。
/// 需要调频率只改 `minimumInterval` 一个数（HTML §22.14）。
///
/// 并发约定：类型本身 `nonisolated`（常量与纯函数谁都能读），
/// 只有**可变状态与副作用**（排队任务、UserDefaults 写入、清缓存）标 `@MainActor`——
/// 它们事实上只由面板的开关事件触发。
enum MemoryTidy {
    /// 最短间隔。**300 秒（5 分钟）** 的选择依据：
    /// - 一次整理的真实成本 ≈ 释放 20–40MB 位图 + malloc 归还空闲页，CPU 几十毫秒；
    /// - 但代价是**下次打开要重新解码 10 来张缩略图**（约 40–80ms），用户能感觉到；
    /// - 抽屉类工具的实际节奏是「打开→拿走→关掉→过几分钟再用」。
    ///   5 分钟正好覆盖这个节奏，且连续操作时一次都不会打断。
    /// - 若按 180s：一天开关 200 次会触发 60 多次无谓的「清→重解」循环，
    ///   既费电又让每次打开都慢一拍，得不偿失。
    static let minimumInterval: TimeInterval = 300

    /// 收起后先静置，避开「开→关→开」的连环操作。
    static let settleDelay: Duration = .seconds(3)

    /// 缩略图内存水位：降到软目标的 40%（≈40MB）。
    /// 不清空——留一半，重开时大半是命中，只有尾部几张要回源。
    static let keepFraction: Double = 0.4

    private static let lastRunKey = "SS.lastMemoryTidyAt"
    @MainActor private static var pending: Task<Void, Never>?

    /// 面板收起时调用。不满足条件就什么也不做（不排队、不占资源）。
    @MainActor
    static func scheduleAfterCollapse() {
        cancelPending()
        guard shouldRun() else { return }
        pending = Task { @MainActor in
            try? await Task.sleep(for: settleDelay)
            guard !Task.isCancelled else { return }
            run()
            pending = nil
        }
    }

    /// 面板重新打开 / 换边时调用：取消还没落地的整理。
    @MainActor
    static func cancelPending() {
        pending?.cancel()
        pending = nil
    }

    /// 给诊断面板/自检用的强制入口（绕过频率门与静置门，仍守电源门）。
    @MainActor
    @discardableResult
    static func runNow() -> Int {
        cancelPending()
        return run()
    }

    /// 纯函数版频率闸（L1 可测）：不读全局状态，只算“该不该跑”。
    static func shouldRun(lastRunAt: Double,
                          now: Double,
                          lowPowerMode: Bool,
                          interval: TimeInterval = minimumInterval) -> Bool {
        if lowPowerMode { return false }
        guard lastRunAt > 0 else { return true }
        return now - lastRunAt >= interval
    }

    static func shouldRun() -> Bool {
        shouldRun(
            lastRunAt: UserDefaults.standard.double(forKey: lastRunKey),
            now: Date.now.timeIntervalSince1970,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    /// 距上次整理还有多少秒（诊断面板显示用；从未跑过返回 0）。
    @MainActor
    static func secondsSinceLastRun() -> Int? {
        let last = UserDefaults.standard.double(forKey: lastRunKey)
        guard last > 0 else { return nil }
        return max(0, Int(Date.now.timeIntervalSince1970 - last))
    }

    /// 同步执行（面板已收起，没有可见帧可掉，几十毫秒可接受）。
    @MainActor
    @discardableResult
    private static func run() -> Int {
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: lastRunKey)

        let signpost = Diagnostics.signposter.beginInterval("memory.tidy")
        // ① 缩略图位图降到水位（LRU，不动磁盘、不动原图）
        var freed = ThumbnailCache.shared.trimMemory(keepFraction: keepFraction)
        // ② 把已释放的堆页真正还给系统（否则 malloc 会留着复用，活动监视器看不到下降）
        freed += returnFreePages()
        Diagnostics.signposter.endInterval("memory.tidy", signpost)

        Diagnostics.shared.recordMemoryTidy(freedBytes: freed)
        return freed
    }

    private static func returnFreePages() -> Int {
        #if canImport(Darwin)
        return malloc_zone_pressure_relief(nil, 0)
        #else
        return 0
        #endif
    }
}
