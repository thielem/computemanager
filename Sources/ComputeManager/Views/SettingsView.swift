import ServiceManagement
import Shared
import SwiftUI

struct SettingsView: View {
    let gate: GateViewModel
    @State private var patterns = ""
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: Binding(get: { loginEnabled }, set: setLogin))

            Section("Runtime") {
                Stepper(value: minutes(\.defaultMaxRuntimeSeconds), in: 1...cap) {
                    LabeledContent("Default max", value: "\(Int(settings.defaultMaxRuntimeSeconds / 60)) min")
                }
                Stepper(value: minutes(\.maxRuntimeCapSeconds), in: 5...240, step: 5) {
                    LabeledContent("Cap", value: "\(Int(settings.maxRuntimeCapSeconds / 60)) min")
                }
            }

            Section("Auto-wrap") {
                TextEditor(text: $patterns)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 180)
                    .onChange(of: patterns) { _, text in
                        var s = settings
                        s.patterns = Self.parse(text)
                        guard s != settings else { return }
                        Task { await gate.updateSettings(s) }
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .onAppear { patterns = settings.patterns.joined(separator: "\n") }
    }

    private var settings: GateSettings { gate.status.settings }
    private var cap: Int { max(1, Int(settings.maxRuntimeCapSeconds / 60)) }

    private func minutes(_ key: WritableKeyPath<GateSettings, TimeInterval>) -> Binding<Int> {
        Binding(get: { Int(settings[keyPath: key] / 60) }, set: { m in
            var s = settings
            s[keyPath: key] = TimeInterval(m * 60)
            s.defaultMaxRuntimeSeconds = min(s.defaultMaxRuntimeSeconds, s.maxRuntimeCapSeconds)
            Task { await gate.updateSettings(s) }
        })
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("ComputeManager: launch at login: \(error)")
        }
        loginEnabled = SMAppService.mainApp.status == .enabled
    }

    /// One pattern per line; blank lines dropped, duplicates removed.
    static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
