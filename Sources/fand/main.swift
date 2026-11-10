import Foundation
import Shared

// fand: root LaunchDaemon owning the SMC fan keys. See Daemon.swift / FanController.swift.
//   fand                 run the daemon (root)
//   fand --print-status  read-only fans/temps as JSON (unprivileged OK, no SMC writes)
//   fand --revert-auto   one-shot: all fans back to Apple control (root)
//   fand --version

switch CommandLine.arguments.dropFirst().first {
case "--version":
    print("fand protocol v\(ProtocolVersion.fand)")
case "--print-status":
    exit(OneShot.printStatus())
case "--revert-auto":
    exit(OneShot.revertAuto())
case nil:
    Daemon().run()
case let other?:
    FileHandle.standardError.write(Data("fand: unknown argument \(other)\nusage: fand [--print-status | --revert-auto | --version]\n".utf8))
    exit(64)
}
