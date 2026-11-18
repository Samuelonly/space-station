import CoreGraphics
import SwiftUI

/// 内容井的填充规则（纯函数 + 单一常量，L1 可测）。
///
/// **2026-11-18 定案：一律 cover**，也就是 Instagram / 微博那套：
/// 每个格子形状完全一致，图片以中心为基准铺满，超出部分裁掉。
///
/// 为什么不再“完整放下”（fit）：
/// 一张 9:19.5 的手机截图放进 4:3 的井里，fit 只会剩一条 20% 宽的细缝——
/// 留白本身不携带任何信息，用户既看不清、也认不出。而 cover 之后，井里
/// 全是画面，至少能认出“这是哪个页面 / 哪张图”。
/// “完整地看整张图”是 QuickLook 的职责，不是卡片的职责。
///
/// 视图层用 `ContentWellFill.contentMode`（= `.fill`）；下面两个函数是它的
/// 可测契约，防止哪天有人为了“别裁掉两侧”又把它改回 `.fit`。
enum ContentWellFill {
    /// 唯一填充方式。改这个常量 = 改全站图片卡的取景规则。
    static let contentMode: ContentMode = .fill

    /// **裁切锚点：顶部。**
    ///
    /// 一律 cover 之后还有一个问题：竖图（9:19.5 的手机截图）放进横卡，
    /// 居中裁会把上下各切掉一半 —— 而截图的**信息几乎都在上半部**
    /// （状态栏、标题、第一屏内容），中间和底部往往是空白或键盘。
    /// 居中裁的结果就是“一张只剩中间空白的蓝块”。
    /// 所以锚点定在顶部：先保证看到开头，看不到的部分由 QuickLook 负责。
    static let alignment: Alignment = .top

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
    /// 超过 0.6 说明这张图在横卡里已经“只剩一条”，是取景比例的锅，不是图的锅。
    static func verticalCropRatio(image: CGSize, well: CGSize) -> Double {
        let rendered = renderedSize(image: image, well: well)
        guard rendered.height > 0 else { return 0 }
        return max(0, 1 - Double(well.height / rendered.height))
    }
}
