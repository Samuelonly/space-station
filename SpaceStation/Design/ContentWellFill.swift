import CoreGraphics
import ImageIO
import SwiftUI

/// 内容井的填充规则（纯函数 + 单一常量，L1 可测）。
///
/// **2026-11-18 第二次修正：cover 保留，但卡片形状必须先适配内容。**
///
/// 上一版把「一律 cover」当成独立规则，结果在 90×120 的卡里 cover 一张 9:19.5 的
/// 手机截图 = 只剩中间一小块，用户原话是「相当于局部特写，太奇怪了」。
///
/// 读了 DockDoor 才发现它为什么敢用 `scaledToFit`：
/// 它不是「固定卡形状再塞图」，而是**先按图片比例把卡片宽度算出来**
/// （`Window Image Sizing Calculations.swift`：thickness 固定，width = thickness × aspectRatio，
///   再 clamp 到 `dynamicMaxAspectRatio = 1.5`），所以 fit 几乎不留白。
///
/// 我们的做法对齐它：**卡片形状跟随内容比例，clamp 在 2:3 ~ 3:2**。
/// 于是 cover 的裁切量天然被限制在 33% 以内，既不会剩细缝，也不会变成局部特写。
/// 「完整地看整张图」仍然交给 QuickLook，卡片只负责「一眼认出这是什么」。
enum ContentWellFill {
    /// 唯一填充方式。改这个常量 = 改全站图片卡的取景规则。
    static let contentMode: ContentMode = .fill

    /// **裁切锚点：顶部。**
    ///
    /// 竖图（9:19.5 的手机截图）即使卡片已经贴合比例，仍会有少量上下裁切 ——
    /// 而截图的**信息几乎都在上半部**（状态栏、标题、第一屏内容），
    /// 中间和底部往往是空白或键盘。所以锚点定在顶部：先保证看到开头。
    static let alignment: Alignment = .top

    // MARK: - 形状适配（DockDoor: dynamicMaxAspectRatio = 1.5）

    /// 卡片宽高比允许的范围 **2:3 ~ 3:2**。超出这个范围的图，宁可裁一点也不许
    /// 把卡拉成一条缝或一根柱——那是“局部特写”和“细缝”两个极端。
    static let minAspect: CGFloat = 1.0 / 1.5
    static let maxAspect: CGFloat = 1.5

    static func clampAspect(_ ratio: CGFloat) -> CGFloat {
        guard ratio.isFinite, ratio > 0 else { return 1 }
        return min(max(ratio, minAspect), maxAspect)
    }

    /// cover 在最坏情况下的裁切比例（= 1 − 2/3 ≈ 0.333）。
    /// 这条是“不再出现局部特写”的可测判据：任何卡的裁切率都不得超过它。
    static var maxCropRatio: Double { 1 - Double(minAspect) }

    /// cover 之后的渲染尺寸（图片按比例放大到**两个方向都不小于井**）。
    static func renderedSize(image: CGSize, well: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0, well.width > 0, well.height > 0 else { return well }
        let scale = max(well.width / image.width, well.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    /// 是否铺满（没有留白）。cover 的判据，也是“用户会不会看到灰条”的判据。
    static func fills(_ rendered: CGSize, well: CGSize) -> Bool {
        rendered.width >= well.width - 0.5 && rendered.height >= well.height - 0.5
    }

    /// 竖向溢出的比例（0 = 刚好铺满，0.7 = 裁掉了 70% 的高度）。
    static func verticalCropRatio(image: CGSize, well: CGSize) -> Double {
        let rendered = renderedSize(image: image, well: well)
        guard rendered.height > 0 else { return 0 }
        return max(0, 1 - Double(well.height / rendered.height))
    }
}

/// 读图片**像素比例**，不解码整图（`CGImageSourceCopyPropertiesAtIndex` 只读头）。
///
/// 为什么要它：卡片宽度要跟着图片比例算（`EdgePosition.cardSize(imageAspect:)`），
/// 布局阶段就必须知道比例，不能等缩略图解码完——那样滚动时卡片会一张张“跳宽”。
enum ImageAspect {
    /// `NSCache` 自身是线程安全的（内部有锁），只是没被标成 `Sendable`，
    /// 所以这里用 `nonisolated(unsafe)` 明确表示“我知道自己在共享什么”。
    nonisolated(unsafe) private static let cache = NSCache<NSString, NSNumber>()

    /// **按卡 id 缓存**。布局每帧都会问一次尺寸，而 `item.imageData` 每次都要从
    /// SwiftData 取 blob；不按 id 缓存的话等于每帧读几 MB，滚动直接卡死。
    /// 约定 **0 = 已确认这张卡没有图**（文本卡），这样文本卡也不会反复去取 blob。
    static func cachedValue(id: String) -> CGFloat? {
        cache.object(forKey: id as NSString).map { CGFloat(truncating: $0) }
    }

    static func store(id: String, value: CGFloat) {
        cache.setObject(NSNumber(value: Double(value)), forKey: id as NSString)
    }

    static func ratio(for data: Data) -> CGFloat? {
        let key = String(data.hashValue) as NSString
        if let hit = cache.object(forKey: key) { return CGFloat(truncating: hit) }

        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let raw = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?,
              // 注意：这里存的是 `NSNumber`，直接 `as? CGFloat` 会失败（坑过一次）。
              let width = (raw[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (raw[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0
        else { return nil }

        let ratio = CGFloat(width / height)
        cache.setObject(NSNumber(value: Double(ratio)), forKey: key)
        return ratio
    }
}

