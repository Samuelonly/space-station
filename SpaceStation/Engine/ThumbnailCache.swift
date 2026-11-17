import AppKit
import CryptoKit
import Foundation

/// HTML §11 — 缩略图缓存策略（集中式，替代 HistoryItem 上那份无上限的
/// @Transient cachedDecodedImage）。四条硬指标全部落在这里：
///   1. 内存 LRU 上限 200 张（每张 @2x 约 50KB → 峰值约 10MB）。
///   2. 滑出视野超过 10 秒的条目从内存淘汰；仍在 200 上限内则按最近访问淘汰。
///   3. 磁盘缓存 ~/Library/Caches/Space Station/：异步批量写（每批最多 5 张）；
///      Clip 删除/过期时同步清理；总量超 50MB 按时间戳删最老。
///   4. 预加载：启动阶段后台加载队首 10 张（可见 6 + 左右各 2 的近似）。
/// App 图标像素不缓存（§11）——直接用 NSWorkspace 系统缓存，见 QuickLookView/
/// StationCard，本类只管粘贴板内嵌位图。
///
/// key 用 imageData 的 SHA256（内容寻址）：同一张图多卡共享一份、重启后仍命中，
/// 且删除时能只凭 Data 定位磁盘文件，不依赖不稳定的 PersistentIdentifier。
/// NSImage 非 Sendable、状态跨线程，故用 NSLock + @unchecked Sendable 守护。
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    // MARK: - §11 可调参数（纯常量，便于逻辑测试）
    static let memoryLimit = 200
    static let offscreenGrace: TimeInterval = 10
    static let diskByteLimit: Int64 = 50 * 1024 * 1024
    static let writesPerBatch = 5
    static let preloadCount = 10
    private static let sweepInterval: TimeInterval = 5

    struct MemEntry {
        let image: NSImage
        var lastAccess: Date
        var lastVisible: Date
    }

    private let lock = NSLock()
    private var memory: [String: MemEntry] = [:]
    private var visibleKeys: Set<String> = []
    private var pendingWrites: [String: Data] = [:]
    private let ioQueue = DispatchQueue(label: "com.samuelonly.spacestation.thumbnail.io", qos: .utility)
    private let cacheDir: URL
    private var sweepTimer: DispatchSourceTimer?
    private var sweepStarted = false

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        cacheDir = base.appendingPathComponent("Space Station", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: - Key（内容寻址，纯函数）

    static func key(forData data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func fileURL(_ key: String) -> URL {
        cacheDir.appendingPathComponent(key + ".img", isDirectory: false)
    }

    // MARK: - 取图（内存 → 磁盘 → 解码）

    /// 解码并缓存；冷启动命中磁盘可省掉大图解码。任何线程可调用。
    func image(forData data: Data) -> NSImage? {
        ensureSweep()
        let key = Self.key(forData: data)

        lock.lock()
        if var entry = memory[key] {
            entry.lastAccess = Date()
            memory[key] = entry
            lock.unlock()
            return entry.image
        }
        lock.unlock()

        // 磁盘命中：读回原始字节再解码，画质与直接解码一致（QuickLook 需要高清）。
        if let image = loadFromDisk(key) {
            storeMemory(key, image: image)
            return image
        }

        guard let image = NSImage(data: data) else { return nil }
        storeMemory(key, image: image)
        queueWrite(key, data: data)
        return image
    }

    /// 只查内存，不触发解码/落盘。给逻辑验证与 UI 判断用。
    func cachedImage(forData data: Data) -> NSImage? {
        let key = Self.key(forData: data)
        lock.lock()
        defer { lock.unlock() }
        return memory[key]?.image
    }

    // MARK: - 可见性 / 淘汰

    /// rail 告诉缓存当前可见的卡（按 imageData 的 key）。可见条目不进 10 秒淘汰。
    func markVisible(_ keys: [String]) {
        let now = Date()
        lock.lock()
        visibleKeys = Set(keys)
        for key in keys where memory[key] != nil {
            memory[key]?.lastVisible = now
        }
        lock.unlock()
    }

    /// 纯函数：在给定时刻，从内存表里算出应淘汰的 key（offscreen 超时 + 超上限 LRU）。
    /// 独立出来可直接脚本验证淘汰边界，不必跑真机定时器。
    static func evictionKeys(
        from memory: [String: MemEntry],
        visible: Set<String>,
        now: Date,
        limit: Int = memoryLimit,
        grace: TimeInterval = offscreenGrace
    ) -> Set<String> {
        var result = Set<String>()
        for (key, entry) in memory
        where !visible.contains(key) && now.timeIntervalSince(entry.lastVisible) > grace {
            result.insert(key)
        }
        let remaining = memory.count - result.count
        if remaining > limit {
            let oldest = memory
                .filter { !result.contains($0.key) }
                .sorted { $0.value.lastAccess < $1.value.lastAccess }
                .prefix(remaining - limit)
            result.formUnion(oldest.map(\.key))
        }
        return result
    }

    private func storeMemory(_ key: String, image: NSImage) {
        lock.lock()
        memory[key] = MemEntry(image: image, lastAccess: Date(), lastVisible: Date())
        applyEvictionLocked()
        lock.unlock()
    }

    private func applyEvictionLocked() {
        let doomed = Self.evictionKeys(from: memory, visible: visibleKeys, now: Date())
        for key in doomed { memory.removeValue(forKey: key) }
    }

    // MARK: - 磁盘写 / 读 / 清理

    private func queueWrite(_ key: String, data: Data) {
        lock.lock()
        pendingWrites[key] = data
        let batch: [String: Data]
        if pendingWrites.count >= Self.writesPerBatch {
            batch = pendingWrites
            pendingWrites.removeAll()
        } else {
            batch = [:]
        }
        lock.unlock()
        if !batch.isEmpty { flush(batch) }
    }

    /// 不足一批的剩余写入由定时 sweep 兜底 flush（§11「单次写入最大 5 张」）。
    private func flushPending() {
        lock.lock()
        let batch = pendingWrites
        pendingWrites.removeAll()
        lock.unlock()
        if !batch.isEmpty { flush(batch) }
    }

    private func flush(_ batch: [String: Data]) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            for (key, data) in batch {
                try? data.write(to: self.fileURL(key), options: .atomic)
            }
            self.enforceDiskLimit()
        }
    }

    private func loadFromDisk(_ key: String) -> NSImage? {
        let url = fileURL(key)
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { return nil }
        // 命中即刷新 mtime，让 50MB 超限时的「删最老」按真实最近使用排序。
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return image
    }

    /// 磁盘总量超 50MB 时按 mtime 从老到新删除，直到回落到限额内（§11）。
    func enforceDiskLimit() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        )) ?? []
        var total: Int64 = 0
        var entries: [(url: URL, size: Int64, date: Date)] = []
        for url in files {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(values?.fileSize ?? 0)
            total += size
            entries.append((url, size, values?.contentModificationDate ?? .distantPast))
        }
        guard total > Self.diskByteLimit else { return }
        var excess = total - Self.diskByteLimit
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            guard excess > 0 else { break }
            try? fm.removeItem(at: entry.url)
            excess -= entry.size
        }
    }

    /// Clip 删除/过期时同步清理内存与磁盘（§11「Clip 过期时同步清理」）。
    func removeImage(forData data: Data) {
        let key = Self.key(forData: data)
        lock.lock()
        memory.removeValue(forKey: key)
        visibleKeys.remove(key)
        pendingWrites.removeValue(forKey: key)
        lock.unlock()
        try? FileManager.default.removeItem(at: fileURL(key))
    }

    // MARK: - 预加载 + 定时维护

    /// 启动阶段后台悄悄加载队首 10 张（§11：可见 6 + 左右各 2）。
    func preload(_ dataList: [Data]) {
        let head = Array(dataList.prefix(Self.preloadCount))
        ioQueue.async { [weak self] in
            for data in head { _ = self?.image(forData: data) }
        }
    }

    private func ensureSweep() {
        lock.lock()
        if sweepStarted { lock.unlock(); return }
        sweepStarted = true
        lock.unlock()

        let timer = DispatchSource.makeTimerSource(queue: ioQueue)
        timer.schedule(deadline: .now() + Self.sweepInterval, repeating: Self.sweepInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.applyEvictionLocked()
            self.lock.unlock()
            self.flushPending()
            self.enforceDiskLimit()
        }
        timer.resume()
        sweepTimer = timer
    }
}
