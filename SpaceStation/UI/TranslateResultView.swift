import AppKit
import SwiftUI

/// 阶段三B — 文本翻译结果面板。
/// ActionExecutor 的 translate handler 只取文本，真正的异步翻译在
/// CardGridView.present(.translate) 里执行，完成后把原文 + 译文喂给本视图。
/// 默认走 macOS 系统翻译（零配置、离线），用户可在设置里填各家 API。
struct TranslateResultView: View {
    let source: String
    let translated: String
    let note: String?
    @Environment(\.auxDismiss) private var dismiss

    private func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("翻译", systemImage: "globe")
                .font(.system(size: 13, weight: .semibold))
            if let note, !note.isEmpty {
                Label(note, systemImage: "info.circle")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    block(title: "原文", text: source)
                    block(title: "译文", text: translated)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 260)

            HStack {
                Spacer()
                Button {
                    copy(translated)
                    dismiss?()
                } label: {
                    Label("复制译文", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(10)
        .frame(width: 500, height: 330)
    }

    @ViewBuilder
    private func block(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(text)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }
}
