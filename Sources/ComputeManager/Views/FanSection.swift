import Shared
import SwiftUI

struct FanSection: View {
    let fan: FanViewModel

    var body: some View {
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
            } else if fan.installed {
                Label("Fan helper not responding", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 4) {
                    Text("Fan helper not installed:")
                    Text("sudo scripts/install.sh").fontDesign(.monospaced).textSelection(.enabled)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
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
