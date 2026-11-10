import Foundation
import Shared

func fail(_ msg: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(code)
}

let command: Command
do {
    command = try CLI.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    fail("cgate: \(error)\n\(CLI.usage)", CgateExit.usage)
}

let link = GateLink(path: Paths.gateSocket)
let stderrLine: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }

switch command {
case .help:
    print(CLI.usage)
case .hook:
    // Fail open: any problem → no output, exit 0.
    let input = FileHandle.standardInput.readDataToEndOfFile()
    if let out = Hook.output(stdin: input, link: link) {
        FileHandle.standardOutput.write(out + Data("\n".utf8))
    }
    exit(0)
case .run(let opts):
    exit(Runner.run(opts, .live()))
case .wait(let ticket):
    exit(Waiter.run(ticket: ticket, link: link, stderr: stderrLine))
case .status:
    guard case .status(let s)? = try? link.call(.status) else {
        fail("compute gate: app not running", 1)
    }
    print(StatusCommand.render(s))
}
