import SwiftUI

extension Notification.Name {
    /// 强调色 / 外观偏好变更通知
    static let snapFlowAppearanceDidChange = Notification.Name("SnapFlow.appearanceDidChange")
    // 语言变更见 `AppLanguage.swift` 中的 `snapFlowLanguageDidChange`
}

/// 解析品牌色 vs 系统强调色。
enum SnapFlowAppearance {
    static func resolvedAccent(useSystem: Bool) -> Color {
        useSystem ? Color.accentColor : AppTheme.brandAccent
    }

    static func resolvedAccentSoft(useSystem: Bool) -> Color {
        useSystem ? Color.accentColor.opacity(0.14) : AppTheme.brandAccentSoft
    }
}

// MARK: - Environment

private struct SnapFlowAccentKey: EnvironmentKey {
    static let defaultValue: Color = AppTheme.brandAccent
}

private struct SnapFlowAccentSoftKey: EnvironmentKey {
    static let defaultValue: Color = AppTheme.brandAccentSoft
}

extension EnvironmentValues {
    /// 当前解析后的强调色（跟随设置即时更新）
    var snapFlowAccent: Color {
        get { self[SnapFlowAccentKey.self] }
        set { self[SnapFlowAccentKey.self] = newValue }
    }

    var snapFlowAccentSoft: Color {
        get { self[SnapFlowAccentSoftKey.self] }
        set { self[SnapFlowAccentSoftKey.self] = newValue }
    }
}

