import GateCore
import Shared
import SwiftUI

/// Menu bar app. Placeholder menu. Owner: package B.
@main
struct ComputeManagerApp: App {
    var body: some Scene {
        MenuBarExtra("Compute Manager", systemImage: "fan") {
            Text("Compute Manager")
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
