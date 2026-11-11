import Foundation

/// Job label for the menu: git toplevel folder name, plus the branch unless main/master
/// (`settings (main--settings)`). nil (→ cwd basename) when not a repo or git is slow (>200 ms).
enum GitLabel {
    static func compute(cwd: String, timeout: TimeInterval = 0.2) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", cwd, "rev-parse", "--show-toplevel", "--abbrev-ref", "HEAD"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        guard (try? p.run()) != nil else { return nil }
        guard done.wait(timeout: .now() + timeout) == .success else {
            p.terminate()
            return nil
        }
        guard p.terminationStatus == 0 else { return nil }
        let lines = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").map(String.init)
        guard lines.count == 2 else { return nil }
        return format(toplevel: lines[0], branch: lines[1])
    }

    static func format(toplevel: String, branch: String) -> String {
        let name = (toplevel as NSString).lastPathComponent
        return ["main", "master", "HEAD", ""].contains(branch) ? name : "\(name) (\(branch))"
    }
}
