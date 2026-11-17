import SwiftUI

@main
struct SpaceStationApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // A sceneless AppKit app is not expressible with SwiftUI's App protocol.
    // Keep one permanently-hidden MenuBarExtra scene, same as the MIT engine base.
    var body: some Scene {
        MenuBarExtra("", isInserted: .constant(false)) {
            EmptyView()
        }
    }
}
