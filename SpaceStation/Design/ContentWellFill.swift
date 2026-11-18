import CoreGraphics
import ImageIO
import SwiftUI

/// 图片卡的取景契约（纯函数 + 单一常量，L1 可测）。
///
/// **2026-11-18 第三次修正：fit，而且这次是对的。**
///
/// 前两稿在 cover / fit 之间来回翻，是因为把两件事混成一件：
/// 「填充方式」和「谁来适配谁」。真相是**顺序决定一切**：
///
/// | 顺序 | 用什么填充 | 结果 |
/// |---|---|---|
/// | 先定死卡形状，再塞图 | cover | 局部特写（一张 9:19.5 截图只剩中间一块） |
/// | 先定死卡形状，再塞图 | fit | 一条细缝 + 大片留白 |
/// | **先量内容比例定卡形状，再塞图** | **fit** | **图完整，留白 ≤ 5pt** |
///
/// DockDoor 走的是第三行（`Window Image Sizing Calculations.swift`：
/// thickness 固定 → 另一维 = thickness × 比例 → 撞 50pt / 1.5× 两个闸门才收），
/// 所以它敢用 `scaledToFit`。我们现在卡形状已经贴合内容（`EdgePosition.cardSize`），
/// 留白只剩极端比例撞闸门时的那几 pt，用主色铺底就看不见了。
///
/// 一句话：**卡跟着内容变形，所以图不需要被裁。**
enum ContentWellFill {
    /// 唯一填充方式。改这个常量 = 改全站图片卡的取景规则。
    static let contentMode: ContentMode = .fit

    /// 锚点：居中。
    ///
    /// 上一版定 `.top` 是为了「cover 竖图时先保住上半部信息」。
    /// 现在不裁了，锚点的意义只剩「撞闸门的极端图，留白偏哪头」——
    /// 居中时两侧留白对称，比顶部对齐更像「一张完整放进框里的图」。
    static let alignment: Alignment = .center

    // MARK: - 形状边界（只用于自检与文档，不再参与 clamp）

    /// 单边允许的伸缩区间，与 `StationMetrics.cardMinSide / cardMaxStretch` 同源。
    static var minSide: CGFloat { StationMetrics.cardMinSide }
    static var maxStretch: CGFloat { StationMetrics.cardMaxStretch }

    // MARK: - fit 语义

    /// fit 之后的渲染尺寸（图片按比例缩到**两个方向都不大于井**）。
    static func renderedSize(image: CGSize, well: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0, well.width > 0, well.height > 0 else { return well }
        let scale = min(well.width / image.width, well.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    /// 是否铺满（没有留白）。fit 下只有比例完全一致才为 true。
    static func fills(_ rendered: CGSize, well: CGSize) -> Bool {
        rendered.width >= well.width - 0.5 && rendered.height >= well.height - 0.5
    }

    /// 留白比例（0 = 刚好铺满，0.3 = 有一边空了 30%）。
    ///
    /// 这是「图有没有被糟蹋」的可测判据：卡形状贴合内容时它应该接近 0；
    /// 只有撞到 `cardMinSide` / `cardMaxStretch` 的极端比例才会有明显数值。
    static func letterboxRatio(image: CGSize, well: CGSize) -> Double {
        let rendered = renderedSize(image: image, well: well)
        guard well.width > 0, well.height > 0 else { return 0 }
        let horizontal = max(0, 1 - Double(rendered.width / well.width))
        let vertical = max(0, 1 - Double(rendered.height / well.height))
        return max(horizontal, vertical)
    }

    /// 把一张图按「厚度固定」规则算出的卡尺寸（与 `EdgePosition.cardSize` 同一算法，
    /// 抽出来只为让自检能在不建视图的情况下验证它）。
    static func cardSize(forImage image: CGSize, thickness: CGFloat, isHorizontal: Bool) -> CGSize {
        guard image.width > 0, image.height > 0, thickness > 0 else {
            return CGSize(width: thickness, height: thickness)
        }
        let ratio = image.width / image.height
        if isHorizontal {
            let raw = thickness * ratio
            let width = min(max(raw, minSide), thickness * maxStretch)
            return CGSize(width: width.rounded(), height: thickness)
        } else {
            let raw = thickness / ratio
            let floor = max(minSide, thickness * 0.7)
            let height = min(max(raw, floor), thickness * maxStretch)
            return CGSize(width: thickness, height: height.rounded())
        }
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
