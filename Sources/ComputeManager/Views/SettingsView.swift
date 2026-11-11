import ServiceManagement
import Shared
import SwiftUI

struct SettingsView: View {
    let gate: GateViewModel
    let fan: FanViewModel
    @State private var patterns = ""
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @FocusState private var editing: Bool

    /// Upper bound of the cap stepper, minutes (GATE-4 hard cap).
    static let capLimit = Int(Defaults.maxRuntimeCap / 60)

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: Binding(get: { loginEnabled }, set: setLogin))

            Section("Runtime") {
                stepRow("Default max", "\(Int(settings.defaultMaxRuntimeSeconds / 60)) min",
                        minutes(\.defaultMaxRuntimeSeconds), 1...cap)
                stepRow("Cap", "\(Int(settings.maxRuntimeCapSeconds / 60)) min",
                        minutes(\.maxRuntimeCapSeconds), 5...Self.capLimit, step: 5)
            }

            Section {
                stepRow("Start", "\(Int(fan.curve.lowTemp)) °C", curveValue(\.lowTemp), FanCurve.lowTempRange)
                stepRow("Full speed", "\(Int(fan.curve.highTemp)) °C", curveValue(\.highTemp),
                        (fan.curve.lowTemp + FanCurve.minSpan)...FanCurve.highTempMax)
                stepRow("Hysteresis", "\(Int(fan.curve.hysteresis)) °C", curveValue(\.hysteresis),
                        FanCurve.hysteresisRange)
            } header: {
                HStack {
                    Text("Performance")
                    Spacer()
                    if fan.curveNotApplied {
                        Text("Needs fand update").foregroundStyle(.secondary)
                            .help("Run install.sh again to apply the curve")
                    }
                    Button("Reset") { fan.setCurve(Defaults.fanCurve) }
                        .buttonStyle(.borderless)
                        .disabled(fan.curve == Defaults.fanCurve)
                }
            }

            Section("Heavy commands") {
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
        .frame(width: 400, height: 640)
        .onAppear { reloadPatterns() }
        .onDisappear { commitPatterns() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in commitPatterns() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            loginEnabled = SMAppService.mainApp.status == .enabled
        }
        .onChange(of: settings.patterns) { if !editing { reloadPatterns() } }
    }

    private func stepRow<V: Strideable>(_ label: String, _ value: String, _ binding: Binding<V>,
                                        _ range: ClosedRange<V>, step: V.Stride = 1) -> some View
        where V.Stride: ExpressibleByIntegerLiteral {
        HStack {
            Text(label)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(.secondary)
            Stepper("", value: binding, in: range, step: step).labelsHidden()
        }
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

    private func curveValue(_ key: WritableKeyPath<FanCurve, Double>) -> Binding<Double> {
        Binding(get: { fan.curve[keyPath: key] }, set: { v in
            var c = fan.curve
            c[keyPath: key] = v
            fan.setCurve(c)
        })
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
