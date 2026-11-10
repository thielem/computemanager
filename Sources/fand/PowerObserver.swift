import Foundation
import IOKit
import IOKit.pwr_mgt

/// System sleep/wake notifications via `IORegisterForSystemPower` (works in a daemon, no
/// AppKit). Calls `onWake` after the system has powered on.
final class PowerObserver: @unchecked Sendable {  // fields written once in start(), then read on `queue`
    private let onWake: @Sendable () -> Void
    private let queue = DispatchQueue(label: "fand.power")
    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    // IOMessage.h: iokit_common_msg(x) = sys_iokit (0xE0000000) | x. The C macros don't import.
    static let canSystemSleep: UInt32 = 0xE000_0270
    static let systemWillSleep: UInt32 = 0xE000_0280
    static let systemHasPoweredOn: UInt32 = 0xE000_0300

    init(onWake: @escaping @Sendable () -> Void) { self.onWake = onWake }

    func start() -> Bool {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(refcon, &notifyPort, { refcon, _, type, arg in
            guard let refcon else { return }
            Unmanaged<PowerObserver>.fromOpaque(refcon).takeUnretainedValue().handle(type, arg)
        }, &notifier)
        guard rootPort != 0, let notifyPort else { return false }
        IONotificationPortSetDispatchQueue(notifyPort, queue)
        return true
    }

    private func handle(_ type: UInt32, _ arg: UnsafeMutableRawPointer?) {
        switch type {
        case Self.canSystemSleep, Self.systemWillSleep:
            // Must acknowledge or sleep is delayed by 30 s.
            IOAllowPowerChange(rootPort, Int(bitPattern: arg))
        case Self.systemHasPoweredOn:
            onWake()
        default:
            break
        }
    }
}
