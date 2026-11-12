import Shared
import SwiftUI

struct GateSection: View {
    let gate: GateViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(Self.levelName(gate.isOn ? .on : (gate.status.level.isOff ? gate.status.level : .noMore)),
                      systemImage: gate.isOn ? "bolt.fill" : "bolt.slash.fill")
                    .foregroundStyle(gate.isOn ? .primary : .secondary)
                Spacer()
                Toggle("", isOn: Binding(get: { gate.isOn },
                                         set: { on in Task { await gate.setOn(on) } }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
            }

            if !gate.escalations.isEmpty {
                stopChoice(gate.escalations)
            }

            HStack {
                Text("Slots")
                Spacer()
                Text("\(gate.status.slots)").monospacedDigit()
                Stepper("", value: Binding(get: { gate.status.slots },
                                           set: { n in Task { await gate.setSlots(n) } }),
                        in: 0...16)
                    .labelsHidden()
            }

            if !gate.runningJobs.isEmpty {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    VStack(spacing: 8) {
                        ForEach(gate.runningJobs) { lease in
                            JobRow(lease: lease, now: ctx.date) {
                                Task { await gate.stop(lease.jobId) }
                            }
                        }
                    }
                }
            }

            if gate.queuedCount > 0 {
                Label("\(gate.queuedCount) queued", systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func stopChoice(_ levels: [GateLevel]) -> some View {
        HStack(spacing: 6) {
            ForEach(levels, id: \.self) { level in
                Button(Self.actionName(level)) { Task { await gate.chooseOff(level) } }
                    .tint(level == .hardStop ? .red : nil)
            }
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
    }

    static func levelName(_ l: GateLevel) -> String {
        switch l {
        case .on: "On"
        case .noMore: "Off"
        case .softStop: "Stopping"
        case .hardStop: "Killing"
        }
    }

    static func actionName(_ l: GateLevel) -> String {
        switch l {
        case .on: "On"
        case .noMore: "No more"
        case .softStop: "Soft stop"
        case .hardStop: "Hard stop"
        }
    }
}
