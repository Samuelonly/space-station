import CoreGraphics
import Foundation

/// [A-1] 内容井的填充规则（纯函数，L1 可测）。
///
/// 为什么单独抽出来：这是“卡片好不好看”的**唯一裁决点**，一旦散在视图里，
/// 以后调比例就只能靠肉眼试。抽成纯函数后，改数值前先跑 `--self-check`。
///
/// 规则（2026-11-18 用户口径：井要被画面占满，且内容不许被裁没）：
/// - 图与井比例差 ≤ 容差 → **cover**：铺满整个井，只裁掉极窄的一条；
/// - 差得远 → **backdropFit**：底层用同一张图放大模糊铺满，前景完整放下。
///   井 100% 是画面（不再是灰条 + 小图），内容一张不裁。
enum ContentWellFill {
    enum Mode: String, Sendable {
        case cover
        case backdropFit
    }

    /// - Parameters:
    ///   - imageAspect: 宽 / 高
    ///   - wellAspect: 宽 / 高
    ///   - tolerance: 相对容差。0.25 = 比例差 25% 以内算“够接近”。
    static func mode(imageAspect: CGFloat,
                     wellAspect: CGFloat,
                     tolerance: CGFloat = StationMetrics.contentCoverTolerance) -> Mode {
        guard imageAspect > 0, wellAspect > 0 else { return .cover }
        let delta = abs(imageAspect - wellAspect) / wellAspect
        return delta <= tolerance ? .cover : .backdropFit
    }
}
