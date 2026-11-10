import Shared
import SwiftUI

struct GateSection: View {
    let gate: GateViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(Self.levelName(gate.switchOn ? .on : gate.status.level),
                      systemImage: gate.switchOn ? "bolt.fill" : "bolt.slash.fill")
                    .foregroundStyle(gate.switchOn ? .primary : .secondary)
                Spacer()
                Toggle("", isOn: Binding(get: { gate.switchOn },
                                         set: { on in Task { await gate.setOn(on) } }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
            }

            if gate.offChoicePending {
                stopChoice([.noMore, .softStop, .hardStop], cancel: true)
            } else if !gate.escalations.isEmpty {
                stopChoice(gate.escalations, cancel: false)
            }

            HStack {
                Text("Slots")
                Spacer()
                Text("\(gate.status.slots)").monospacedDigit()
                Stepper("", value: Binding(get: { gate.status.slots },
                                           set: { n in Task { await gate.setSlots(n) } }),
                        in: 1...16)
                    .labelsHidden()
            }

            if !gate.runningJobs.isEmpty {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    VStack(spacing: 8) {
                        ForEach(gate.runningJobs) { lease in
                            JobRow(lease: lease, now: ctx.date) {
                                Task { await gate.kill(lease.jobId) }
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

    private func stopChoice(_ levels: [GateLevel], cancel: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(levels, id: \.self) { level in
                Button(Self.actionName(level)) { Task { await gate.chooseOff(level) } }
                    .tint(level == .hardStop ? .red : nil)
            }
            if cancel {
                Spacer()
                Button { gate.cancelOffChoice() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
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
