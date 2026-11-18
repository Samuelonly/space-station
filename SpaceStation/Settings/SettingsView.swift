import AppKit
import SwiftUI

/// Settings · keymap panel (HTML §19.4 / §21.9). Points that matter:
///  - one row per function: name / current combo / record new / reset all;
///  - click a keycap -> pressing a combo records it; Esc cancels;
///  - collision -> the cap flashes red and the combo is rejected (§21.9);
///  - rebinding affects the keyboard only; status-item ⌥ / ⌥⇧ mouse gestures
///    stay fixed (§18.3).
/// The recorder owns a local keyDown monitor that is installed only while a
/// keycap is listening, and it consumes keys so they never reach the rail.

@MainActor
final class HotkeyRecorder: ObservableObject {
    @Published var listening: HotkeyID?
    @Published var conflictID: HotkeyID?
    private var monitor: Any?
    private weak var state: StationState?

    init(state: StationState) { self.state = state }

    func begin(_ id: HotkeyID) {
        end()
        listening = id
        state?.isRecordingHotkey = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.capture(event)
        }
    }

    func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        listening = nil
        state?.isRecordingHotkey = false
    }

    private func capture(_ event: NSEvent) -> NSEvent? {
        guard let id = listening else { return event }
        // Wait for a real key, not a bare modifier press.
        if event.type == .flagsChanged { return nil }
        if let chars = event.charactersIgnoringModifiers, chars == "\u{1B}" {
            end() // Escape cancels
            return nil
        }
        if ["Meta", "Alt", "Shift", "Control"].contains(event.characters) { return nil }

        let combo = HotkeyStore.codeFrom(event: event)
        let store = HotkeyStore.shared
        if store.conflict(for: combo, excluding: id) != nil {
            conflictID = id
            end()
            // Clear the red flash after a beat.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                self.conflictID = nil
            }
            return nil
        }
        store.set(combo, for: id)
        end()
        return nil
    }
}

struct SettingsView: View {
    @ObservedObject var store = HotkeyStore.shared
    @StateObject private var recorder: HotkeyRecorder
    @Environment(StationState.self) private var state

    // Local mirrors of SS settings so the privacy tab redraws immediately.
    @State private var includeSecrets = SS.includeSecretSources
    @State private var retention = SS.retentionDays

    init(state: StationState) {
        _recorder = StateObject(wrappedValue: HotkeyRecorder(state: state))
    }

    var body: some View {
        TabView {
            positionTab
                .tabItem { Label("位置", systemImage: "arrow.up.and.down.and.arrow.left.and.right") }
            keymapTab
                .tabItem { Label("快捷键", systemImage: "keyboard") }
            privacyTab
                .tabItem { Label("隐私", systemImage: "hand.raised") }
        }
        .frame(width: 440, height: 360)
        .onDisappear { recorder.end() }
    }

    // MARK: - Position tab (§18.5 四边停靠)

    private var positionTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("🧭 设置 · 位置").font(.headline)
                Text("站体贴在屏幕的哪一边").font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                ForEach(EdgePosition.allCases, id: \.self) { candidate in
                    let active = state.edge == candidate
                    Button {
                        switchEdge(to: candidate)
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: candidate.symbolName).font(.system(size: 15))
                            Text(candidate.cnLabel).font(.system(size: 11, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(active ? Color.accentColor.opacity(0.18)
                                             : Color.secondary.opacity(0.10))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(active ? Color.accentColor : .clear, lineWidth: 1.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("顶/底 = 横排卡（4:3），左/右 = 竖排卡（3:4）。换边时站体会先收进、静置一瞬、再在新位置展开——重活都发生在你看不见的时候。")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
            HStack {
                Text("改动立即生效").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("完成") { SettingsWindowController.shared.close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    /// 只改 `stationState.edge`：面板的“收进 → 延迟 → 展开”由 AppDelegate 观察驱动，
    /// 这里绝不直接动窗口，避免出现两条换边路径。
    private func switchEdge(to candidate: EdgePosition) {
        guard state.edge != candidate else { return }
        EdgePosition.saved = candidate
        state.edge = candidate
    }

    // MARK: - Keymap tab (§19.4 / §21.9)

    private var keymapTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            groupLabel("键盘流")
            ForEach(HotkeyStore.definitions.prefix(4)) { row($0) }
            groupLabel("自有快捷键")
            ForEach(HotkeyStore.definitions.dropFirst(4)) { row($0) }
            note
            HStack {
                Button("全部恢复默认") { store.resetAll() }
                Spacer()
                Button("完成") { SettingsWindowController.shared.close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    // MARK: - Privacy tab (§17.10 / §19.6)
    //
    // Retention is a free integer, never a hard-coded enum. 1/7/30 are offered
    // only as "common practice" shortcuts; the Stepper lets the user choose
    // any number of days. 0 means never expire. Changing either value takes
    // effect immediately (cleanup runs on the spot).

    private var privacyTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("🛡 设置 · 隐私").font(.headline)
                Text("默认替你做掉，这里都能改（§19.6）")
                    .font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("机密来源").font(.system(size: 12, weight: .semibold))
                Toggle("把密码管理器等机密来源也收入历史", isOn: Binding(
                    get: { includeSecrets },
                    set: { includeSecrets = $0; SS.includeSecretSources = $0 }
                ))
                .font(.system(size: 12))
                Text("默认关闭：1Password / Bitwarden / 钥匙串等来源不入库。打开后这些来源也会被记录。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 8) {
                Text("保留时长").font(.system(size: 12, weight: .semibold))
                HStack(spacing: 6) {
                    ForEach([1, 7, 30], id: \.self) { d in
                        Button("\(d) 天") { setRetention(d) }
                            .buttonStyle(.bordered)
                            .tint(retention == d ? .accentColor : nil)
                    }
                    Button("永不过期") { setRetention(0) }
                        .buttonStyle(.bordered)
                        .tint(retention == 0 ? .accentColor : nil)
                }
                Stepper(value: Binding(
                    get: { retention },
                    set: { setRetention($0) }
                ), in: 0...3650) {
                    Text(retentionLabel).font(.system(size: 12))
                }
                Text("1 / 7 / 30 天是常见区间，天数完全由你定；0 = 永不清理。Pin 卡始终不过期。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

            Spacer(minLength: 0)
            HStack {
                Text("改动立即生效").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("完成") { SettingsWindowController.shared.close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private var retentionLabel: String {
        retention == 0 ? "保留：永不过期" : "保留：\(retention) 天"
    }

    private func setRetention(_ days: Int) {
        retention = max(0, days)
        SS.retentionDays = retention
        History.shared.cleanupExpired() // shrink immediately if lowered
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("⚙ 设置 · 改键").font(.headline)
            Text("点键帽后按下组合键录入 · Esc 取消")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func groupLabel(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.top, 2)
    }

    private func row(_ def: HotkeyDefinition) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(def.label).font(.system(size: 12, weight: .medium))
                Text("\(def.source)\(def.proto ? " · 原型可试" : " · 真机")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            keycap(for: def)
        }
    }

    private func keycap(for def: HotkeyDefinition) -> some View {
        let isListening = recorder.listening == def.id
        let isConflict = recorder.conflictID == def.id
        return Button {
            isListening ? recorder.end() : recorder.begin(def.id)
        } label: {
            Text(isListening ? "按组合键…"
                 : isConflict ? "冲突：" + def.label
                 : HotkeyStore.label(for: store.combo(for: def.id)))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .frame(minWidth: 76)
                .padding(.vertical, 5).padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isConflict ? Color.red.opacity(0.18)
                             : isListening ? Color.accentColor.opacity(0.18)
                             : Color.secondary.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isConflict ? Color.red : isListening ? Color.accentColor : Color.clear,
                                lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
    }

    private var note: some View {
        Text("冲突检测：新键位与已有功能相同会标红并拒绝保存。改键只影响键盘，状态栏 ⌥-click / ⌥⇧-click 鼠标手势固定不变。")
            .font(.caption2).foregroundStyle(.secondary)
            .padding(8)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Hosts SettingsView in a standalone, non-activating-but-keyable window.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show(state: StationState) {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingView(rootView: SettingsView(state: state).environment(state))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Space Station · 设置"
        window.contentView = hosting
        window.center()
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func close() { window?.close(); window = nil }

    func windowWillClose(_ notification: Notification) { window = nil }
}
