import AppKit
import SwiftUI

/// HTML §21.7.4 — Mini Finder: a read-only folder tree in Finder column view.
/// Only file names are shown; no preview, no write. Reuses the system folder
/// icon and NSWorkspace for "reveal in Finder".
struct MiniFinder: View {
    let urls: [URL]
    let onDone: () -> Void

    @State private var selection: URL?
    @State private var children: [URL] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Mini Finder", systemImage: "folder")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: onDone) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if urls.isEmpty {
                Text("这条剪贴板里没有文件路径")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                HStack(spacing: 0) {
                    // Column 1: the copied file/folder URLs.
                    List(urls, id: \.self, selection: $selection) { url in
                        Label(url.lastPathComponent, systemImage: url.hasDirectoryPath ? "folder" : "doc")
                            .font(.system(size: 12))
                            .tag(url)
                    }
                    .listStyle(.plain)
                    .frame(width: 200)

                    Divider()

                    // Column 2: contents if the selection is a directory.
                    List(children, id: \.self) { child in
                        Label(child.lastPathComponent, systemImage: child.hasDirectoryPath ? "folder" : "doc")
                            .font(.system(size: 12))
                    }
                    .listStyle(.plain)
                    .frame(width: 200)
                }
                .frame(height: 260)

                HStack {
                    Text("只读 · \(children.count) 项")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Button("在 Finder 中显示") {
                        if let sel = selection { NSWorkspace.shared.activateFileViewerSelecting([sel]) }
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                }
            }
        }
        .padding(14)
        .frame(width: 430)
        .background(.ultraThinMaterial)
        .onChange(of: selection) { _, new in
            guard let new, new.hasDirectoryPath,
                  let contents = try? FileManager.default.contentsOfDirectory(at: new, includingPropertiesForKeys: nil) else {
                children = []
                return
            }
            children = contents
        }
    }
}
