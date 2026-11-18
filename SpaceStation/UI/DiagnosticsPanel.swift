#if DEBUG
import AppKit
import SwiftUI

/// [A-5] 诊断面板 —— 仅 DEV 构建存在，绝不进入发布包。
/// 自测时看这里，不靠猜（HTML §22.12 第 3 条）。
@MainActor
final class DiagnosticsWindowController {
    static let shared = DiagnosticsWindowController()

    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: DiagnosticsPanel())
        let panel = NSWindow(contentViewController: hosting)
        panel.title = "Space Station · 诊断（DEV）"
        panel.styleMask = [.titled, .closable, .resizable]
        panel.setContentSize(NSSize(width: 460, height: 560))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = panel
    }
}

struct DiagnosticsPanel: View {
    @State private var snapshot = Diagnostics.shared.snapshot()
    @State private var checks: [Diagnostics.Check] = []
    @State private var logicChecks: [SelfCheck.Item] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            metrics
            Divider()
            logicList
            Divider()
            checksList
            Spacer(minLength: 0)
            footer
        }
        .padding(16)
        .frame(minWidth: 440, minHeight: 540, alignment: .topLeading)
        .task {
            checks = await Diagnostics.shared.runSelfChecks()
            logicChecks = SelfCheck.runAll()
            while !Task.isCancelled {
                snapshot = Diagnostics.shared.snapshot()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// L1 纯函数自测（§22.11）：改完逻辑先看这里，红了就是真红线。
    private var logicList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("逻辑自检（L1）").font(.system(size: 11, weight: .semibold))
                let failed = logicChecks.filter { !$0.ok }.count
                Text(failed == 0 ? "\(logicChecks.count)/\(logicChecks.count) 通过" : "\(failed) 项失败")
                    .font(.system(size: 9))
                    .foregroundStyle(failed == 0 ? Color.green : Color.red)
            }
            ForEach(logicChecks.filter { !$0.ok }) { item in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(Color.red)
                        .font(.system(size: 9))
                    Text("\(item.name) — \(item.detail)")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var metrics: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("常驻内存", Self.mb(Int64(snapshot.residentBytes)),
                warn: snapshot.residentBytes > 250 * 1024 * 1024)
            row("缩略图内存", "\(Self.mb(Int64(snapshot.thumbnailBytes))) / 软 \(Self.mb(Int64(ThumbnailCache.softMemoryBytes))) · 硬 \(Self.mb(Int64(ThumbnailCache.memoryLimitBytes)))",
                warn: snapshot.thumbnailBytes > ThumbnailCache.softMemoryBytes)
            row("缩略图磁盘", "\(Self.mb(snapshot.diskBytes)) / 上限 \(Self.mb(ThumbnailCache.diskByteLimit))",
                warn: snapshot.diskBytes > ThumbnailCache.diskByteLimit)
            row("缩略图命中", "\(snapshot.thumbnailHits) 次命中 / \(snapshot.thumbnailMisses) 次回源", warn: false)
            row("收起后整理", "\(snapshot.tidyRuns) 次 · 最近释放 \(Self.mb(Int64(snapshot.tidyFreedBytes))) · 间隔 \(Int(MemoryTidy.minimumInterval))s", warn: false)
            row("库内卡片", "\(snapshot.historyCount) 张", warn: false)
        }
    }

    private var checksList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("启动自检").font(.system(size: 11, weight: .semibold))
            ForEach(checks) { check in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: check.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(check.ok ? Color.green : Color.red)
                        .font(.system(size: 10))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(check.title).font(.system(size: 10))
                        Text(check.detail).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !snapshot.rejections.isEmpty {
                Text("最近被隐私门挡下（只记类目）").font(.system(size: 10, weight: .semibold))
                Text(snapshot.rejections.suffix(5)
                    .map { "\($0.category) · \($0.at.formatted(date: .omitted, time: .standard))" }
                    .joined(separator: "\n"))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            if !snapshot.unimplemented.isEmpty {
                Text("最近未实现的 Action（死按钮线索）").font(.system(size: 10, weight: .semibold))
                Text(snapshot.unimplemented.suffix(5).joined(separator: ", "))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ title: String, _ value: String, warn: Bool) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 10))
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(warn ? Color.red : Color.primary)
        }
    }

    private static func mb(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}
#endif
