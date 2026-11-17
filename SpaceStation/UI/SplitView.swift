import AppKit
import SwiftUI

/// HTML §21.7.4 — Split 大爆炸. Port of prototype fragmentize (html:1979-1995)
/// and openSplit (1996-2025). Fragments are a temporary selection: click copies
/// that chunk (repeatable), drag writes text/plain into the target app, Esc
/// collapses. The original card stays in the rail.
struct SplitView: View {
    let item: HistoryItem
    let onDone: () -> Void

    @State private var picked: Set<Int> = []
    @State private var toast: String = "点一块 = 复制那块（可连点）· 拖一块 = 拖进目标 App"

    private let fragments: [String]

    init(item: HistoryItem, onDone: @escaping () -> Void) {
        self.item = item
        self.onDone = onDone
        self.fragments = Self.fragmentize(item.text ?? item.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Split 大爆炸", systemImage: "burst")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("已复制 \(picked.count) 块")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button(action: onDone) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Text(toast)
                .font(.system(size: 10)).foregroundStyle(.secondary)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8)], spacing: 8) {
                    ForEach(fragments.indices, id: \.self) { i in
                        Text(fragments[i])
                            .font(.system(size: 12))
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(picked.contains(i) ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.06))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(picked.contains(i) ? Color.accentColor : Color.clear, lineWidth: 1.5)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { copy(fragmentAt: i) }
                            .onDrag { NSItemProvider(object: fragments[i] as NSString) }
                    }
                }
            }
            .frame(maxHeight: 260)

            Text("原卡留在站体 · 碎片是临时选区")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 420)
        .background(.ultraThinMaterial)
    }

    private func copy(fragmentAt i: Int) {
        guard !picked.contains(i) else { return }
        picked.insert(i)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(fragments[i], forType: .string)
        toast = "已复制第 \(picked.count) 块 · 碎片场保持开着"
    }

    // MARK: - fragmentize (verbatim algorithm, html:1979-1995)
    static func fragmentize(_ text: String) -> [String] {
        let clean = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        var chunks: [String] = []
        var current = ""
        for ch in clean {
            current.append(ch)
            if "。！？!?；;，,、".contains(ch) {
                let t = current.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { chunks.append(t) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { chunks.append(tail) }

        var out: [String] = []
        for chunk in chunks {
            if chunk.count <= 12 { out.append(chunk); continue }
            let hasCJK = chunk.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
            if hasCJK {
                let pieces = stride(from: 0, to: chunk.count, by: 5).map { i -> String in
                    let start = chunk.index(chunk.startIndex, offsetBy: i)
                    let end = chunk.index(start, offsetBy: 5, limitedBy: chunk.endIndex) ?? chunk.endIndex
                    return String(chunk[start..<end])
                }
                var buf = ""
                for p in pieces {
                    if (buf + p).count > 8 && !buf.isEmpty { out.append(buf); buf = p }
                    else { buf += p }
                }
                if !buf.isEmpty { out.append(buf) }
            } else {
                var buf: [String] = []
                for w in chunk.split(separator: " ").map(String.init) {
                    buf.append(w)
                    if buf.joined(separator: " ").count > 16 { out.append(buf.joined(separator: " ")); buf = [] }
                }
                if !buf.isEmpty { out.append(buf.joined(separator: " ")) }
            }
        }
        return Array(out.prefix(26))
    }
}
