import AppKit
import CryptoKit
import Foundation
import ImageIO

/// HTML §11 — 缩略图管线（2026-11-18 修订口径）。
///
/// 修订前的三个致命问题，这里逐个消掉：
///  1. 用 `NSImage(data:)` 解码 = 整张图解到内存，8K 图一次 120MB+ → 改用 ImageIO
///     `CGImageSourceCreateThumbnailAtIndex`，**由解码器直接出目标尺寸，不解全图**。
///  2. 内存上限按「200 张」计数，与实际字节数无关 → 改成按 `bytesPerRow × height`
///     累计字节计费（软目标 99MB / 硬上限 128MB）。
///  3. 磁盘写的是原图字节 → 改成写缩略图本身（HEIC q0.7，失败回落 JPEG），
///     目录从 `~/Library/Caches/` 迁到 `~/Library/Application Support/`，
///     避免被清理工具整批扫掉后再重新解码。
///
/// 一份缓存、两个尺寸（卡片级 / 预览级），共用同一个内容寻址的 base key，
/// 所以「卡片上看到的」和「QuickLook 里看到的」是同一张原图的两个降采样。
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    // MARK: - [A-4] 参数（与 HTML §11 修订一致，改这里必须同步改文档）

    enum Variant: String, Sendable {
        case card       // 卡片：512pt @2x
        case preview    // 预览：长边封顶 2560

        var maxPixel: Int {
            switch self {
            case .card: return ThumbnailCache.cardPixel
            case .preview: return ThumbnailCache.previewPixel
            }
        }

        var fileSuffix: String { self == .card ? "c" : "p" }
    }

    static let cardPixel = 1024
    static let previewPixel = 2560
    /// 原图长边超过此值才值得降采样；小于它 ImageIO 会原样返回（不会放大）。
    static let downsampleThreshold = 3000

    static let softMemoryBytes = 99 * 1024 * 1024      // 目标值，超了要在诊断面板报出来
    static let memoryLimitBytes = 128 * 1024 * 1024    // 红线，超了必须淘汰
    static let diskByteLimit: Int64 = 256 * 1024 * 1024

    static let offscreenGrace: TimeInterval = 10
    static let preloadCount = 10
    private static let sweepInterval: TimeInterval = 5
    private static let heicQuality: CGFloat = 0.7

    private struct MemEntry {
        let baseKey: String
        let image: NSImage
        let bytes: Int
        var lastAccess: Date
        var lastVisible: Date
    }

    private let lock = NSLock()
    private var memory: [String: MemEntry] = [:]     // key = "baseKey:variant"
    private var visibleKeys: Set<String> = []        // base keys
    private var totalBytes = 0
    private var cachedDiskBytes: Int64 = 0
    private let ioQueue = DispatchQueue(label: "com.samuelonly.spacestation.thumbnail.io", qos: .utility)
    private var sweepTimer: DispatchSourceTimer?
    private var sweepStarted = false

    let directoryURL: URL

    private init() {
        // [A-4] Application Support 而不是 Caches：清理工具默认不碰它，
        // 清理由我们自己的 LRU + 256MB 上限决定（HTML §11 第 6 条）。
        let base = URL.applicationSupportDirectory
            .appending(path: "SpaceStation/Thumbnails", directoryHint: .isDirectory)
        directoryURL = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // 派生数据不进 Time Machine。
        var mutable = base
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)
    }

    // MARK: - Key（内容寻址，纯函数）

    /// base key：原图字节的 SHA256。卡片与预览共用，删除时凭它定位。
    static func key(forData data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func variantKey(_ baseKey: String, _ variant: Variant) -> String {
        "\(baseKey):\(variant.rawValue)"
    }

    private func fileURL(_ baseKey: String, _ variant: Variant) -> URL {
        directoryURL.appending(path: "\(variant.fileSuffix)-\(baseKey).heic")
    }

    // MARK: - 取图

    /// 卡片级（默认入口，体积小、命中快）。
    func image(forData data: Data) -> NSImage? {
        image(forData: data, variant: .card)
    }

    /// 预览级（QuickLook 用，长边 2560）。
    func previewImage(forData data: Data) -> NSImage? {
        image(forData: data, variant: .preview)
    }

    func image(forData data: Data, variant: Variant) -> NSImage? {
        ensureSweep()
        let baseKey = Self.key(forData: data)
        let key = variantKey(baseKey, variant)

        lock.lock()
        if var entry = memory[key] {
            entry.lastAccess = Date()
            memory[key] = entry
            lock.unlock()
            Diagnostics.shared.recordThumbnail(hit: true)
            return entry.image
        }
        lock.unlock()

        Diagnostics.shared.recordThumbnail(hit: false)

        if let image = loadFromDisk(baseKey, variant) {
            storeMemory(key, baseKey: baseKey, image: image)
            return image
        }

        guard let cgImage = Self.downsample(data, maxPixel: variant.maxPixel) else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        storeMemory(key, baseKey: baseKey, image: image)
        writeToDisk(cgImage, baseKey: baseKey, variant: variant)
        return image
    }

    /// 只查内存，不触发解码/落盘。
    func cachedImage(forData data: Data, variant: Variant = .card) -> NSImage? {
        let key = variantKey(Self.key(forData: data), variant)
        lock.lock()
        defer { lock.unlock() }
        return memory[key]?.image
    }

    // MARK: - [A-1] 平均色（图片井的底色，避免留白处出现灰条）

    private var tints: [String: NSColor] = [:]

    /// 取该图的主色（1×1 降采样求平均）。缓存按 base key，同一张图只算一次。
    func tint(forData data: Data, image: NSImage) -> NSColor {
        let baseKey = Self.key(forData: data)
        lock.lock()
        if let hit = tints[baseKey] { lock.unlock(); return hit }
        lock.unlock()

        let color = Self.averageColor(of: image) ?? .separatorColor
        lock.lock()
        if tints.count > 400 { tints.removeAll(keepingCapacity: true) }
        tints[baseKey] = color
        lock.unlock()
        return color
    }

    /// 1×1 上下文重绘 = 平均色。比逐像素遍历快得多，且对任何色域都成立。
    static func averageColor(of image: NSImage) -> NSColor? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(
                  data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let raw = ctx.data?.bindMemory(to: UInt8.self, capacity: 4) else { return nil }
        return NSColor(
            srgbRed: CGFloat(raw[0]) / 255,
            green: CGFloat(raw[1]) / 255,
            blue: CGFloat(raw[2]) / 255,
            alpha: 1
        )
    }

    // MARK: - 降采样（唯一解码点，⑥ 图像管线）

    /// 只分配目标尺寸的位图；不解全图，也不放大。
    static func downsample(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]

        let signpost = Diagnostics.signposter.beginInterval("thumbnail.downsample")
        let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        Diagnostics.signposter.endInterval("thumbnail.downsample", signpost)

        // L2 契约断言（HTML §22.11）：⑥ 图像管线**只许缩，不许放**。
        // 放大过的缩略图在卡上会糊成一片，而且白占内存——这是曾经真出现过的问题。
        #if DEBUG
        if let image, let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let srcWidth = properties[kCGImagePropertyPixelWidth] as? Int, srcWidth > 0 {
            assert(
                image.width <= max(maxPixel, srcWidth),
                "downsample 把图放大了：\(image.width) > max(\(maxPixel), \(srcWidth))"
            )
        }
        #endif
        return image
    }

    private static func imageBytes(_ image: CGImage) -> Int {
        max(1, image.bytesPerRow) * max(1, image.height)
    }

    // MARK: - 内存预算（按字节，不按张数）

    private func storeMemory(_ key: String, baseKey: String, image: NSImage) {
        let bytes = Self.imageBytesPacked(
            image,
            fallback: Int(image.size.width) * Int(image.size.height) * 4
        )

        lock.lock()
        if let old = memory[key] { totalBytes -= old.bytes }
        memory[key] = MemEntry(
            baseKey: baseKey,
            image: image,
            bytes: bytes,
            lastAccess: Date(),
            lastVisible: Date()
        )
        totalBytes += bytes
        evictLocked()
        let snapshot = totalBytes
        lock.unlock()

        Diagnostics.shared.setThumbnailBytes(snapshot)
    }

    /// NSImage 的 cgImage 可能为空（极少），回落到尺寸估算。
    private static func imageBytesPacked(_ image: NSImage, fallback: Int) -> Int {
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return imageBytes(cg)
        }
        return fallback
    }

    private func evictLocked() {
        let now = Date()

        // 1) 滑出视野超过 grace 且不在可见集合
        let stale = memory.filter { _, value in
            !visibleKeys.contains(value.baseKey)
                && now.timeIntervalSince(value.lastVisible) > Self.offscreenGrace
        }.map(\.key)
        for key in stale { removeLocked(key) }

        // 2) 超硬上限：按最近访问淘汰非可见项
        if totalBytes > Self.memoryLimitBytes {
            let candidates = memory
                .filter { !visibleKeys.contains($0.value.baseKey) }
                .sorted { $0.value.lastAccess < $1.value.lastAccess }
            for (key, _) in candidates {
                if totalBytes <= Self.memoryLimitBytes { break }
                removeLocked(key)
            }
        }
    }

    private func removeLocked(_ key: String) {
        if let entry = memory.removeValue(forKey: key) {
            totalBytes -= entry.bytes
        }
    }

    // MARK: - 可见性（⑨ rail 上报）

    func markVisible(_ keys: [String]) {
        let now = Date()
        lock.lock()
        visibleKeys = Set(keys)
        for (key, value) in memory where keys.contains(value.baseKey) {
            memory[key]?.lastVisible = now
        }
        lock.unlock()
    }

    // MARK: - 磁盘

    private func writeToDisk(_ image: CGImage, baseKey: String, variant: Variant) {
        let url = fileURL(baseKey, variant)
        let jpegURL = directoryURL.appending(path: "\(variant.fileSuffix)-\(baseKey).jpg")
        ioQueue.async { [weak self] in
            guard let self else { return }
            guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL, "public.heic" as CFString, 1, nil
            ) else {
                Self.writeJPEG(image, to: jpegURL)
                self.enforceDiskLimit()
                return
            }
            CGImageDestinationAddImage(destination, image, [
                kCGImageDestinationLossyCompressionQuality: Self.heicQuality
            ] as CFDictionary)
            if !CGImageDestinationFinalize(destination) {
                Self.writeJPEG(image, to: jpegURL)
            }
            self.enforceDiskLimit()
        }
    }

    private static func writeJPEG(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.jpeg" as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: heicQuality
        ] as CFDictionary)
        _ = CGImageDestinationFinalize(destination)
    }

    private func loadFromDisk(_ baseKey: String, _ variant: Variant) -> NSImage? {
        for url in candidateFiles(baseKey, variant) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, [
                      kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { continue }
            // 命中即刷新 mtime，让「删最老」按真实最近使用排序。
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        return nil
    }

    private func candidateFiles(_ baseKey: String, _ variant: Variant) -> [URL] {
        [fileURL(baseKey, variant),
         directoryURL.appending(path: "\(variant.fileSuffix)-\(baseKey).jpg")]
    }

    func currentDiskBytes() -> Int64 {
        lock.lock()
        let cached = cachedDiskBytes
        lock.unlock()
        return cached
    }

    @discardableResult
    func enforceDiskLimit() -> Int64 {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        )) ?? []

        var entries: [(url: URL, size: Int64, date: Date)] = []
        var total: Int64 = 0
        for url in files {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(values?.fileSize ?? 0)
            total += size
            entries.append((url, size, values?.contentModificationDate ?? .distantPast))
        }

        if total > Self.diskByteLimit {
            var excess = total - Self.diskByteLimit
            for entry in entries.sorted(by: { $0.date < $1.date }) {
                guard excess > 0 else { break }
                try? fm.removeItem(at: entry.url)
                excess -= entry.size
                total -= entry.size
            }
        }

        lock.lock(); cachedDiskBytes = total; lock.unlock()
        Diagnostics.shared.setDiskBytes(total)
        return total
    }

    /// Clip 删除/过期时清理两个尺寸（内存 + 磁盘）。
    func removeImage(forData data: Data) {
        let baseKey = Self.key(forData: data)
        lock.lock()
        removeLocked(variantKey(baseKey, .card))
        removeLocked(variantKey(baseKey, .preview))
        visibleKeys.remove(baseKey)
        lock.unlock()
        for variant in [Variant.card, .preview] {
            for url in candidateFiles(baseKey, variant) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - 预加载 + 定时维护

    /// 启动时后台悄悄生成队首 10 张的卡片级（§11：可见 6 + 左右各 2）。
    func preload(_ dataList: [Data]) {
        let head = Array(dataList.prefix(Self.preloadCount))
        ioQueue.async { [weak self] in
            for data in head { _ = self?.image(forData: data, variant: .card) }
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
            self.evictLocked()
            let snapshot = self.totalBytes
            self.lock.unlock()
            Diagnostics.shared.setThumbnailBytes(snapshot)
            self.enforceDiskLimit()
        }
        timer.resume()
        sweepTimer = timer
    }
}
