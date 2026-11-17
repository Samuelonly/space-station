import AppKit
import SwiftUI

/// M2 card shell + M3 content layer. Four edges share this one render (§21.7.4).
/// Glass/selection logic from DockDoor design (WindowPreview.swift:847-925);
/// right-side capsule = ActionRegistry.headActions (§21.7.1); prediction pill
/// = PredictionEngine output on the item (§21.7.2); flavor switch = multi-rep
/// toggle without a new card (§21.7.3). No geometry scale on hover (§21.13.6).
struct StationCard: View {
    let item: HistoryItem
    let size: CGSize
    let isSelected: Bool
    let onSelect: () -> Void
    let onPaste: () -> Void
    let onAction: (String) -> Void          // M3: runAction dispatcher
    let onFlavor: () -> Void                // M3: cycle representation

    @State private var isHovering = false
    @State private var showPrediction = false

    private var effectiveSelected: Bool { isSelected || isHovering }
    private var kind: ClipKind {
        ClipKind.derive(types: item.contents.map(\.type), text: item.text)
    }
    private var headActions: [ActionDefinition] { ActionRegistry.headActions(for: kind) }
    private var predictedAction: ActionDefinition? {
        guard let id = item.predictedActionID else { return nil }
        return ActionRegistry.byID[id]
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Card glass background (24.2 + borderedBackground 1.75, padding -6).
            RoundedRectangle(cornerRadius: StationMetrics.cardRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: StationMetrics.cardRadius, style: .continuous))
                .borderedBackground(
                    .primary.opacity(0.1),
                    lineWidth: StationMetrics.cardBgStroke,
                    shape: RoundedRectangle(cornerRadius: StationMetrics.cardRadius, style: .continuous)
                )
                .padding(-StationMetrics.innerPadding)

            if effectiveSelected {
                RoundedRectangle(cornerRadius: StationMetrics.cardRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(StationMetrics.selectionFillOpacity))
                    .padding(-StationMetrics.innerPadding)
            }

            // Content layer: clip 18.2, opacity selected?1:0.75, easeInOut 0.15.
            VStack(alignment: .leading, spacing: 6) {
                MaterialPill {
                    Label {
                        Text(item.application ?? "未知 App")
                            .font(.system(size: 10)).lineLimit(1)
                    } icon: {
                        Image(systemName: kindSymbol(kind)).font(.system(size: 10))
                    }
                }

                Spacer(minLength: 2)

                Text(item.title.isEmpty ? "(\(kind.cnLabel) / 文件)" : item.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(size.width > size.height ? 3 : 5)

                if item.numberOfCopies > 1 {
                    Text("×\(item.numberOfCopies)")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }

                // M3: right-side action capsule (type-specific) + prediction.
                HStack(spacing: 4) {
                    ForEach(headActions) { action in
                        Button { onAction(action.id) } label: {
                            Text(displayIcon(for: action)).font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .help(displayHelp(for: action))
                    }
                    if item.contents.count > 1 {
                        Button { onFlavor() } label: {
                            Image(systemName: "square.on.square").font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .help("切换另一种表示")
                    }
                    if let predictedAction {
                        Button {
                            withAnimation(StationMetrics.hoverAnimation) { showPrediction.toggle() }
                        } label: {
                            Image(systemName: "wand.and.stars").font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .help(predictedAction.label)
                    }
                }
            }
            .padding(8)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: StationMetrics.imageRadius, style: .continuous))
            .opacity(effectiveSelected ? 1 : 0.75)
            .animation(.easeInOut(duration: 0.15), value: effectiveSelected)

            // Prediction float (reason line), drawn above the card.
            if showPrediction, let predictedAction {
                VStack(alignment: .leading, spacing: 2) {
                    Text("预测：\(predictedAction.icon) \(predictedAction.label)")
                        .font(.system(size: 10, weight: .semibold))
                    Text(item.predictionReason ?? "")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(width: max(160, size.width), alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(.ultraThinMaterial))
                .offset(y: -14)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
            }

            // Selection border (outside bg branch, WindowPreview.swift:872-879).
            if effectiveSelected {
                RoundedRectangle(cornerRadius: StationMetrics.cardRadius, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: StationMetrics.selectionStrokeWidth)
                    .padding(-StationMetrics.innerPadding)
                    .allowsHitTesting(false)
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
    }

    /// §8: the Favorite star toggles appearance (⭐ collected / ☆ not yet).
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
