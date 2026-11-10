import AppKit
import SwiftUI

@main
struct ComputeManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppRuntime.model

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(gate: model.gate)
        }
    }
}

/// Separate view so observation of the model reliably refreshes the glyph.
private struct MenuBarLabel: View {
    let model: AppModel
    var body: some View { Image(nsImage: MenuBarIcon.image(for: model.icon)) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppRuntime.launch() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppRuntime.terminate() }
    }
}
