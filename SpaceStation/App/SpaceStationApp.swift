import Foundation
import SwiftUI

@main
struct SpaceStationApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // L1/L2 检查点的命令行入口（HTML §22.11）：
        //   SpaceStation.app/Contents/MacOS/SpaceStation --self-check
        // 全绿退出码 0，有红 1 —— 可以直接接进脚本，不用开界面。
        if CommandLine.arguments.contains("--self-check") {
            let passed = SelfCheck.runAndPrint()
            exit(passed ? 0 : 1)
        }
    }

    // A sceneless AppKit app is not expressible with SwiftUI's App protocol.
    // Keep one permanently-hidden MenuBarExtra scene, same as the MIT engine base.
    var body: some Scene {
        MenuBarExtra("", isInserted: .constant(false)) {
            EmptyView()
        }
    }
}
