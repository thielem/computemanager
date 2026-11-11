import AppKit
import SwiftUI

/// The Settings window, managed by hand. The SwiftUI `Settings` scene + `SettingsLink` is
/// unreliable from a menu bar popover in an `LSUIElement` app: the accessory app is never
/// activated, so the window opens behind other apps (or not at all) and, with no Dock icon,
/// cannot be found. Here: activate the app, then bring our own window to the front.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show(_ model: AppModel) {
        let w = window ?? make(model)
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
    }

    private static func make(_ model: AppModel) -> NSWindow {
        let w = NSWindow(contentViewController: NSHostingController(
            rootView: SettingsView(gate: model.gate, fan: model.fan)))
        w.title = "Compute Manager Settings"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        return w
    }
}
