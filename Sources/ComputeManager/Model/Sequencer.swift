import Foundation

/// Monotonic counter stamped on status snapshots where they arrive (any thread), so the
/// main actor can drop a snapshot older than one it already applied (unstructured tasks
/// hopping to the main actor are not ordered).
final class Sequencer: @unchecked Sendable {  // guarded by `lock`
    private let lock = NSLock()
    private var n: UInt64 = 0
    func next() -> UInt64 { lock.withLock { n += 1; return n } }
}
