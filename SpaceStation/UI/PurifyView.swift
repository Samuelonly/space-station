import AppKit
import SwiftUI

/// HTML §17.6 — link purification result overlay.
/// Rules from the PRD:
///  - the cleaned link is already written back to the card (ActionExecutor),
///    so tapping the card itself copies the purified URL;
///  - the overlay keeps ONE action button — "用 Safari 打开" — which is the
///    predicted next step;
///  - there is deliberately NO close button — clicking any blank area or
///    pressing Escape (handled globally by KeyboardRouter) dismisses it.
struct PurifyView: View {
    let url: String
    @Environment(\.auxDismiss) private var dismiss

    private var displayURL: URL? { URL(string: url) }
    private var canOpen: Bool {
        guard let u = displayURL else { return false }
        return u.scheme == "http" || u.scheme == "https"
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Click anywhere blank to dismiss (no close button by design).
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { dismiss?() }

            VStack(alignment: .leading, spacing: 12) {
                Label("链接净化", systemImage: "link.badge.checkmark")
                    .font(.system(size: 13, weight: .semibold))

                Text("已去掉追踪参数，这张卡现在就是净化后的链接")
                    .font(.system(size: 10)).foregroundStyle(.secondary)

                // Read-only cleaned link — not an editable field.
                Text(url)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )

                HStack {
                    Spacer()
                    Button {
                        if let u = displayURL { NSWorkspace.shared.open(u) }
                        dismiss?()
                    } label: {
                        Label("用 Safari 打开", systemImage: "safari")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canOpen)
                    .help("预测的下一步：在默认浏览器打开")
                }
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(10)
        }
        .frame(width: 460, height: 210)
    }
}
