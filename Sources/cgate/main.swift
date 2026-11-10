import Foundation
import Shared

// cgate placeholder: parses arguments, then reports not implemented. Owner: package C.

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

switch command {
case .help:
    print(CLI.usage)
case .hook:
    exit(0)  // fail-open placeholder: no output = tool call proceeds unchanged
case .run, .wait, .status:
    fail("cgate: not implemented", 1)
}
