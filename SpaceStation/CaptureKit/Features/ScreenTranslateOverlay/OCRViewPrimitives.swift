import AppKit
import SwiftUI
import UniformTypeIdentifiers


// MARK: - Chrome controls（hover / 手型光标）

/// 右上角 OCR 服务下拉：列出已启用服务，切换即改全局默认并重识别。
struct OCRServiceMenu: View {
    let selectedID: String
    let services: [OCRServiceEntry]
    var onSelect: (String) -> Void
    var onMenuOpenChange: (Bool) -> Void = { _ in }

    @State private var isOpen = false
    @State private var isHovered = false

    private var selectedTitle: String {
        services.first(where: { $0.id == selectedID })?.displayName
            ?? OCRServiceKind.vision.displayName
    }

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 3) {
                Text(selectedTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.textPrimary.opacity(0.92))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered || isOpen ? AppTheme.textPrimary.opacity(0.10) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(L10n.string("选择 OCR 服务（将设为默认）"))
        .onHover { hovering in
            isHovered = hovering
            updateHandCursor(hovering)
        }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.15), value: isOpen)
        .onChange(of: isOpen) { _, open in
            onMenuOpenChange(open)
        }
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            OCRServiceMenuPanel(
                selectedID: selectedID,
                services: services,
                onSelect: { id in
                    onSelect(id)
                    isOpen = false
                }
            )
            .frame(width: 236)
            .padding(2)
        }
        .accessibilityLabel(String(format: L10n.string("OCR 服务，当前：%@"), selectedTitle))
    }
}

struct OCRServiceMenuPanel: View {
    let selectedID: String
    let services: [OCRServiceEntry]
    var onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.string("文本识别"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 4)

            ForEach(services) { entry in
                OCRServiceMenuRow(
                    title: entry.displayName,
                    kind: entry.kind,
                    isSelected: selectedID == entry.id,
                    trailingBadge: entry.badgeTitle
                ) {
                    onSelect(entry.id)
                }
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppTheme.surfaceMuted)
        )
    }
}

struct OCRServiceMenuRow: View {
    let title: String
    let kind: OCRServiceKind
    let isSelected: Bool
    let trailingBadge: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .frame(width: 14)
                    .opacity(isSelected ? 1 : 0)

                OCRServiceIconView(kind: kind, size: 22)

                Text(title)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let trailingBadge {
                    Text(trailingBadge)
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? AppTheme.textPrimary.opacity(0.08) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(OCRServiceMenuRowButtonStyle())
    }
}

struct OCRServiceMenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        OCRServiceMenuRowButtonBody(configuration: configuration)
    }
}

struct OCRServiceMenuRowButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        configuration.isPressed
                            ? AppTheme.textPrimary.opacity(0.12)
                            : (isHovered ? AppTheme.textPrimary.opacity(0.08) : Color.clear)
                    )
            )
            .onHover { hovering in
                isHovered = hovering
                updateHandCursor(hovering)
            }
            .animation(.easeOut(duration: 0.1), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

// 共用 chrome：`Features/Shared/ResultChromeControls.swift`
// `updateHandCursor`：`App/PointerCursor.swift`

// MARK: - Image + boxes

/// 原图 + OCR 框画布（OCR 窗 / 截图翻译窗复用）
struct OCRImageCanvas: View {
    enum ContentAlignment {
        /// 居中（OCR 结果窗默认）
        case center
        /// 顶对齐水平居中（截图翻译左栏）
        case top
    }

    let image: NSImage
    /// 与 OCR boundingBox 同一像素坐标系
    let pixelSize: CGSize
    let lines: [OCRLine]
    let showBoxes: Bool
    var contentAlignment: ContentAlignment = .center

    var body: some View {
        GeometryReader { geo in
            let fit = fittedRect(in: geo.size)
            ZStack(alignment: .topLeading) {
                Color.clear
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fit.width, height: fit.height)
                    .position(x: fit.midX, y: fit.midY)

                if showBoxes, pixelSize.width > 0, pixelSize.height > 0 {
                    ForEach(lines) { line in
                        let box = displayRect(for: line.boundingBox, fit: fit)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .stroke(AppTheme.accent.opacity(0.95), lineWidth: 1.2)
                            .background(
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(AppTheme.accent.opacity(0.12))
                            )
                            .frame(width: max(box.width, 2), height: max(box.height, 2))
                            .position(x: box.midX, y: box.midY)
                    }
                }
            }
        }
        .padding(8)
    }

    private func fittedRect(in container: CGSize) -> CGRect {
        let iw = max(pixelSize.width, 1)
        let ih = max(pixelSize.height, 1)
        let scale = min(container.width / iw, container.height / ih)
        let w = iw * scale
        let h = ih * scale
        let y: CGFloat = switch contentAlignment {
        case .center: (container.height - h) / 2
        case .top: 0
        }
        return CGRect(
            x: (container.width - w) / 2,
            y: y,
            width: w,
            height: h
        )
    }

    /// Vision/OCR 像素坐标：原点左上、y 向下 → 视图坐标（y 向下，与 SwiftUI 一致）
    private func displayRect(for pixelBox: CGRect, fit: CGRect) -> CGRect {
        let sx = fit.width / max(pixelSize.width, 1)
        let sy = fit.height / max(pixelSize.height, 1)
        return CGRect(
            x: fit.minX + pixelBox.minX * sx,
            y: fit.minY + pixelBox.minY * sy,
            width: pixelBox.width * sx,
            height: pixelBox.height * sy
        )
    }
}

// MARK: - 按图布局拼文本

enum OCRTextLayout {
    /// 按行排序结果拼成可读文本：同行用空格分隔，换行按图上纵向位置。
    static func makeText(from lines: [OCRLine], sameRowThreshold: CGFloat = 12) -> String {
        guard !lines.isEmpty else { return "" }
        var sorted = lines
        sorted.sort {
            if abs($0.boundingBox.minY - $1.boundingBox.minY) < sameRowThreshold {
                return $0.boundingBox.minX < $1.boundingBox.minX
            }
            return $0.boundingBox.minY < $1.boundingBox.minY
        }

        var parts: [String] = []
        var row: [OCRLine] = []
        var rowY: CGFloat?

        func flushRow() {
            guard !row.isEmpty else { return }
            row.sort { $0.boundingBox.minX < $1.boundingBox.minX }
            var lineText = ""
            var prevMaxX: CGFloat?
            for item in row {
                if let prev = prevMaxX {
                    let gap = item.boundingBox.minX - prev
                    // 较大空隙用双空格区分文本块
                    lineText += gap > 36 ? "  " : " "
                }
                lineText += item.text
                prevMaxX = item.boundingBox.maxX
            }
            parts.append(lineText)
            row.removeAll(keepingCapacity: true)
        }

        for line in sorted {
            if let y = rowY, abs(line.boundingBox.minY - y) >= sameRowThreshold {
                flushRow()
                rowY = line.boundingBox.minY
            } else if rowY == nil {
                rowY = line.boundingBox.minY
            }
            row.append(line)
        }
        flushRow()
        return parts.joined(separator: "\n")
    }
}

// MARK: - Modes

enum OCRLanguageMode: String, CaseIterable, Identifiable, Sendable {
    case auto
    case zhHans
    case zhHant
    case en
    case ja
    case ko

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: L10n.string("自动检测")
        case .zhHans: L10n.string("简体中文")
        case .zhHant: L10n.string("繁體中文")
        case .en: "English"
        case .ja: L10n.string("日本語")
        case .ko: "한국어"
        }
    }

    var visionLanguages: [String]? {
        switch self {
        case .auto: nil
        case .zhHans: ["zh-Hans", "en-US"]
        case .zhHant: ["zh-Hant", "en-US"]
        case .en: ["en-US"]
        case .ja: ["ja-JP", "en-US"]
        case .ko: ["ko-KR", "en-US"]
        }
    }
}

#Preview {
    Text("OCRResultView — run app to preview with real capture")
        .frame(width: 400, height: 200)
}
