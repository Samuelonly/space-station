import AppKit
import SwiftUI

/// 卡片壳 + 内容层（四边共用，HTML §21.7.4）。
///
/// 0.5.0 / A 组的三处改动都落在这一个文件：
///  - [A-1] 图片卡真的画图：走 ThumbnailCache 的卡片级降采样，后台生成，不阻塞首帧。
///  - [A-2] 来源 App 显示真图标 + 真名字（SourceAppResolver），不再是 `com.apple.Safari`。
///  - [A-3] 布局归位：右上角动作组件（hover 淡入）、左下 Info（相对时间 · 可选信息 · ×N）、
///          右下留空；卡内不放常驻垃圾桶。
struct StationCard: View {
    let item: HistoryItem
    let size: CGSize
    let isSelected: Bool
    let onSelect: () -> Void
    let onPaste: () -> Void
    let onAction: (String) -> Void
    let onFlavor: () -> Void

    @State private var isHovering = false
    @State private var showPrediction = false
    @State private var thumbnail: NSImage?
    @State private var appInfo: SourceAppResolver.Info?

    private var effectiveSelected: Bool { isSelected || isHovering }
    private var isLandscape: Bool { size.width > size.height }

    private var kind: ClipKind {
        ClipKind.derive(types: item.contents.map(\.type), text: item.text)
    }

    private var headActions: [ActionDefinition] {
        Array(ActionRegistry.headActions(for: kind).prefix(2))
    }

    private var predictedAction: ActionDefinition? {
        guard let id = item.predictedActionID else { return nil }
        return ActionRegistry.byID[id]
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            background
            if effectiveSelected { selectionFill }

            VStack(alignment: .leading, spacing: 6) {
                header
                content
                Spacer(minLength: 0)
                infoLine
            }
            .padding(8)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: StationMetrics.imageRadius, style: .continuous))
            .opacity(effectiveSelected ? 1 : 0.75)
            .animation(.easeInOut(duration: 0.15), value: effectiveSelected)

            // [A-3] 动作组件：右上角、hover 才显形（§17.4），不再占底部一行。
            actionCluster
                .padding(6)
                .frame(width: size.width, height: size.height, alignment: .topTrailing)
                .opacity(isHovering ? 1 : 0)
                .animation(StationMetrics.hoverAnimation, value: isHovering)

            if effectiveSelected { selectionBorder }
        }
        .overlay(alignment: .bottomLeading) {
            if showPrediction, let predictedAction {
                predictionFloat(predictedAction)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            }
        }
        .frame(width: size.width + StationMetrics.innerPadding * 2,
               height: size.height + StationMetrics.innerPadding * 2)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            let hovering: Bool
            switch phase {
            case .active: hovering = true
            case .ended: hovering = false
            @unknown default: hovering = false
            }
            withAnimation(StationMetrics.hoverAnimation) { isHovering = hovering }
        }
        .onTapGesture { onSelect(); onPaste() }
        .animation(StationMetrics.hoverAnimation, value: effectiveSelected)
        .task(id: item.persistentModelID) { await loadSurfaces() }
        .onReceive(NotificationCenter.default.publisher(for: .sourceAppResolved)) { note in
            guard let changed = note.object as? String, changed == item.application else { return }
            appInfo = SourceAppResolver.shared.info(for: changed)
        }
    }

    // MARK: - 背景 / 选中（§21.6 玻璃 + 描边，不做几何缩放）

    private var background: some View {
        RoundedRectangle(cornerRadius: StationMetrics.cardRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: StationMetrics.cardRadius, style: .continuous))
            .borderedBackground(
                .primary.opacity(0.1),
                lineWidth: StationMetrics.cardBgStroke,
                shape: RoundedRectangle(cornerRadius: StationMetrics.cardRadius, style: .continuous)
            )
            .padding(-StationMetrics.innerPadding)
    }

    private var selectionFill: some View {
        RoundedRectangle(cornerRadius: StationMetrics.cardRadius, style: .continuous)
            .fill(Color.accentColor.opacity(StationMetrics.selectionFillOpacity))
            .padding(-StationMetrics.innerPadding)
    }

    private var selectionBorder: some View {
        RoundedRectangle(cornerRadius: StationMetrics.cardRadius, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: StationMetrics.selectionStrokeWidth)
            .padding(-StationMetrics.innerPadding)
            .allowsHitTesting(false)
    }

    // MARK: - [A-2] 头部：真图标 + 真名字

    private var header: some View {
        HStack(spacing: 4) {
            iconView
            Text(displayName)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(height: 18)
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon = appInfo?.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 14, height: 14)
        } else {
            Image(systemName: kindSymbol(kind))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
        }
    }

    private var displayName: String {
        if let name = appInfo?.name { return name }
        guard let bundleID = item.application, !bundleID.isEmpty else { return "未知 App" }
        // 解析完成前的瞬时回落：com.apple.Safari → Safari（好过一个裸 bundle id）
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }

    // MARK: - [A-1] 内容层：图片卡真的画图

    @ViewBuilder
    private var content: some View {
        if kind == .image {
            imageContent
        } else {
            textContent
        }
    }

    private var imageContent: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.primary.opacity(0.06))

            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 18))
                    .foregroundStyle(.tertiary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var textContent: some View {
        Text(bodyText)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(isLandscape ? 3 : 5)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var bodyText: String {
        item.title.isEmpty ? "（\(kind.cnLabel)）" : item.title
    }

    // MARK: - [A-3] 左下 Info

    private var infoLine: some View {
        Text(infoText)
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var infoText: String {
        var parts = [Self.relativeTime(item.lastCopiedAt)]
        if let second = secondaryInfo { parts.append(second) }
        if item.numberOfCopies > 1 { parts.append("×\(item.numberOfCopies)") }
        return parts.joined(separator: " · ")
    }

    /// 第二信息只在真有意义时出现（文本没有大小就不显示）。
    private var secondaryInfo: String? {
        switch kind {
        case .image:
            guard let data = item.imageData else { return nil }
            return Self.byteText(data.count)
        case .file:
            let count = item.fileURLs.count
            return count > 1 ? "\(count) 项" : nil
        case .url:
            return ClipKind.firstURL(in: item.text ?? "")?.host
        case .video, .text, .code, .note:
            return nil
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private static func relativeTime(_ date: Date) -> String {
        let interval = Date.now.timeIntervalSince(date)
        if interval < 60 { return "刚刚" }
        return relativeFormatter.localizedString(for: date, relativeTo: Date.now)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.isAdaptive = true
        return formatter
    }()

    private static func byteText(_ bytes: Int) -> String {
        byteFormatter.string(fromByteCount: Int64(bytes))
    }

    // MARK: - [A-3] 右上动作组件

    private var actionCluster: some View {
        HStack(spacing: 4) {
            ForEach(headActions) { action in
                Button { onAction(action.id) } label: {
                    Text(displayIcon(for: action)).font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help(displayHelp(for: action))
            }

            if item.contents.count > 1 {
                Button { onFlavor() } label: {
                    Image(systemName: "square.on.square").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help("切换另一种表示")
            }

            if let predictedAction {
                Button {
                    withAnimation(StationMetrics.hoverAnimation) { showPrediction.toggle() }
                } label: {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("预测：\(predictedAction.label)")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 1))
    }

    private func predictionFloat(_ action: ActionDefinition) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("预测：\(action.icon) \(action.label)")
                .font(.system(size: 10, weight: .semibold))
            Text(item.predictionReason ?? "")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(width: max(160, size.width), alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.ultraThinMaterial))
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .allowsHitTesting(false)
    }

    // MARK: - 加载（后台，不阻塞首帧）

    private struct BoxedImage: @unchecked Sendable {
        let image: NSImage
    }

    private func loadSurfaces() async {
        appInfo = SourceAppResolver.shared.info(for: item.application)

        guard kind == .image, thumbnail == nil, let data = item.imageData else { return }
        let boxed = await Task.detached(priority: .userInitiated) { () -> BoxedImage? in
            guard let image = ThumbnailCache.shared.image(forData: data) else { return nil }
            return BoxedImage(image: image)
        }.value
        if let image = boxed?.image { thumbnail = image }
    }

    // MARK: - 图标 / 文案

    private func displayIcon(for action: ActionDefinition) -> String {
        if action.id == "favorite" { return item.isFavorite ? "⭐" : "☆" }
        return action.icon
    }

    private func displayHelp(for action: ActionDefinition) -> String {
        if action.id == "favorite" {
            return item.isFavorite ? "移回 Clip — 取消永久收藏" : "收藏到 Favorite — 永久保存"
        }
        return "\(action.label) — \(action.desc)"
    }

    private func kindSymbol(_ kind: ClipKind) -> String {
        switch kind {
        case .text: return "doc.text"
        case .url: return "link"
        case .image: return "photo"
        case .video: return "play.rectangle"
        case .file: return "folder"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .note: return "note.text"
        }
    }
}
