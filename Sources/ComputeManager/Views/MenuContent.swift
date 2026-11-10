import AppKit
import SwiftUI

struct MenuContent: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FanSection(fan: model.fan)
            Divider()
            GateSection(gate: model.gate)
            if let err = model.gate.lastError {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
            Divider()
            HStack(spacing: 10) {
                Button { Task { await model.meeting() } } label: {
                    Label("Meeting", systemImage: "video.fill")
                }
                .help("Gate off (No more) + fans Auto")
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .simultaneousGesture(TapGesture().onEnded { NSApp.activate(ignoringOtherApps: true) })
                    .help("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("q")
                    .help("Quit")
            }
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 320)
    }
}
