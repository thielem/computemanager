import Foundation
import Shared

/// Performance curve with hysteresis (FAN-2). The curve is evaluated on an "effective"
/// temperature that follows rising temps immediately and falling temps only once they drop
/// more than `hysteresis` below it (then it lags `hysteresis` behind): a dead band that keeps
/// the fans from hunting around a set point.
struct CurveState: Equatable, Sendable {
    let curve: FanCurve
    private(set) var effective: Double?

    init(curve: FanCurve) { self.curve = curve }

    /// Feed one reading; returns the effective temperature.
    mutating func update(_ t: Double) -> Double {
        let e = effective.map { max(t, min($0, t + curve.hysteresis)) } ?? t
        effective = e
        return e
    }

    mutating func reset() { effective = nil }

    /// Fraction 0...1 of the way from min to max RPM for effective temperature `t`.
    func fraction(_ t: Double) -> Double {
        let span = curve.highTemp - curve.lowTemp
        guard span > 0 else { return t >= curve.highTemp ? 1 : 0 }
        return min(max((t - curve.lowTemp) / span, 0), 1)
    }

    static func rpm(fraction: Double, minRPM: Double, maxRPM: Double) -> Double {
        (minRPM + (maxRPM - minRPM) * fraction).rounded()
    }
}
