import Shared
import SwiftUI

struct JobRow: View {
    let lease: Lease
    let now: Date
    let kill: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(lease.project).fontWeight(.medium).lineLimit(1)
                    Text(String(lease.sessionId.prefix(6))).foregroundStyle(.tertiary)
                }
                Text(lease.command)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(lease.command)
            }
            Spacer(minLength: 4)
            Text(Self.elapsed(from: lease.startedAt, to: now) + " / " + Self.minutes(lease.maxRuntimeSeconds))
                .font(.caption.monospacedDigit())
                .foregroundStyle(tint)
            Button(action: kill) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .disabled(lease.state == .killing)
            .help("Kill")
        }
    }

    private var tint: Color {
        switch lease.state {
        case .killing: .red
        case .stopRequested: .orange
        default: .secondary
        }
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func minutes(_ t: TimeInterval) -> String { "\(Int((t / 60).rounded()))m" }
}
