import SwiftUI

/// HTML §8(b) — Favorite `+` → type to author a note card. Title + body; Save
/// calls back into History.addNote (Favorite cabin, permanent). Escape / tapping
/// the dimmed surround closes via the shared auxDismiss path (no close button,
/// matching the PurifyView "click blank to dismiss" convention).
struct NoteComposer: View {
    let onSave: (String, String) -> Void

    @State private var title = ""
    @State private var bodyText = ""
    @Environment(\.auxDismiss) private var dismiss
    @FocusState private var focusTitle: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("新笔记 · Favorite", systemImage: "note.text")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("永久保存").font(.system(size: 10)).foregroundStyle(.secondary)
            }

            TextField("标题", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .focused($focusTitle)

            TextEditor(text: $bodyText)
                .font(.system(size: 12))
                .frame(height: 110)
                .overlay(
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12))
                )

            HStack {
                Text("Esc 关闭").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("保存") {
                    onSave(title, bodyText)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                          bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 360, height: 240)
        .background(.ultraThinMaterial)
        .onAppear { focusTitle = true }
    }
}
