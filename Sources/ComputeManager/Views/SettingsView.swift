import ServiceManagement
import Shared
import SwiftUI

struct SettingsView: View {
    let gate: GateViewModel
    @State private var patterns = ""
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @FocusState private var editing: Bool

    /// Upper bound of the cap stepper, minutes (GATE-4 hard cap).
    static let capLimit = Int(Defaults.maxRuntimeCap / 60)

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: Binding(get: { loginEnabled }, set: setLogin))

            Section("Runtime") {
                Stepper(value: minutes(\.defaultMaxRuntimeSeconds), in: 1...cap) {
                    LabeledContent("Default max", value: "\(Int(settings.defaultMaxRuntimeSeconds / 60)) min")
                }
                Stepper(value: minutes(\.maxRuntimeCapSeconds), in: 5...Self.capLimit, step: 5) {
                    LabeledContent("Cap", value: "\(Int(settings.maxRuntimeCapSeconds / 60)) min")
                }
            }

            Section("Auto-wrap") {
                TextEditor(text: $patterns)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 180)
                    .focused($editing)
                    .onChange(of: editing) { _, now in if !now { commitPatterns() } }
                    .task(id: patterns) {
                        try? await Task.sleep(for: .seconds(1.5))
                        if !Task.isCancelled { commitPatterns() }
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .onAppear { reloadPatterns() }
        .onDisappear { commitPatterns() }
        .onChange(of: settings.patterns) { if !editing { reloadPatterns() } }
    }

    private var settings: GateSettings { gate.status.settings }
    private var cap: Int { max(1, Int(settings.maxRuntimeCapSeconds / 60)) }

    private func reloadPatterns() { patterns = settings.patterns.joined(separator: "\n") }

    private func commitPatterns() {
        var s = settings
        s.patterns = Self.parse(patterns)
        guard s != settings else { return }
        Task { await gate.updateSettings(s) }
    }

    private func minutes(_ key: WritableKeyPath<GateSettings, TimeInterval>) -> Binding<Int> {
        Binding(get: { Int(settings[keyPath: key] / 60) }, set: { m in
            let s = Self.setting(settings, key, minutes: m)
            Task { await gate.updateSettings(s) }
        })
    }

    /// Sets `key` to `m` minutes; cap ≤ `Defaults.maxRuntimeCap`, default ≤ cap.
    static func setting(_ old: GateSettings, _ key: WritableKeyPath<GateSettings, TimeInterval>,
                        minutes m: Int) -> GateSettings {
        var s = old
        s[keyPath: key] = TimeInterval(max(1, m) * 60)
        s.maxRuntimeCapSeconds = min(s.maxRuntimeCapSeconds, Defaults.maxRuntimeCap)
        s.defaultMaxRuntimeSeconds = min(s.defaultMaxRuntimeSeconds, s.maxRuntimeCapSeconds)
        return s
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
