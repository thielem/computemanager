import AppKit
import Shared
import SwiftUI

struct FanSection: View {
    let fan: FanViewModel
    static let installCommand: String = {
        guard let repo = Bundle.main.object(forInfoDictionaryKey: "CMRepoPath") as? String, !repo.isEmpty
        else { return "sudo scripts/install.sh" }
        return "sudo '\(repo)/scripts/install.sh'"
    }()

    var body: some View {
        if !fan.reachable && !fan.installed {
            notInstalled
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: Binding(get: { fan.mode }, set: { fan.select($0) })) {
                    Text("Auto").tag(FanMode.auto)
                    Text("Performance").tag(FanMode.performance)
                    Text("Max").tag(FanMode.max)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!fan.reachable)

                if let status = fan.status {
                    readout(status)
                } else {
                    Label("Fan helper not responding", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// fand absent: one row, warning + the install command (selectable, copyable).
    private var notInstalled: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(Self.installCommand).fontDesign(.monospaced).textSelection(.enabled)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Self.installCommand, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help("Copy")
        }
        .font(.callout)
        .help("Fan helper not installed")
    }

    private func readout(_ s: FanStatus) -> some View {
        HStack(spacing: 14) {
            Label(fan.hottestCPU.map { "\(Int($0.rounded()))°" } ?? "–", systemImage: "thermometer.medium")
                .foregroundStyle(s.thermalState >= .serious ? Color.orange : .secondary)
            Label(s.fans.map { "\(Int($0.actualRPM.rounded()))" }.joined(separator: " · ") + " rpm",
                  systemImage: "fan")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .font(.callout.monospacedDigit())
    }
}
