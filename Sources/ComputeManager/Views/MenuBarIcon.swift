import AppKit
import Shared

/// Menu bar glyph: gate state, plus the fan mode when it is not Auto.
enum MenuBarIcon {
    struct State: Equatable {
        var level: GateLevel
        var jobsRunning: Bool
        var fanMode: FanMode
        var fanReachable: Bool
    }

    static func symbols(for s: State) -> [[String]] {
        var out: [[String]]
        switch (s.level, s.jobsRunning) {
        case (.on, _): out = [["bolt.fill"]]
        case (_, true): out = [["bolt.badge.clock.fill", "hourglass"]]
        case (_, false): out = [["bolt.slash.fill", "bolt.slash"]]
        }
        if s.fanReachable {
            switch s.fanMode {
            case .auto: break
            case .performance: out.append(["fan.fill", "fan", "speedometer"])
            case .max: out.append(["wind"])
            }
        }
        return out
    }

    static func image(for s: State) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let parts: [NSImage] = symbols(for: s).compactMap { names in
            names.lazy.compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
                .first?.withSymbolConfiguration(config)
        }
        let gap: CGFloat = 3
        let height: CGFloat = 16
        let width = parts.reduce(0) { $0 + $1.size.width } + gap * CGFloat(max(0, parts.count - 1))
        let img = NSImage(size: NSSize(width: max(width, 1), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for p in parts {
                p.draw(in: NSRect(x: x, y: (height - p.size.height) / 2, width: p.size.width, height: p.size.height))
                x += p.size.width + gap
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}
