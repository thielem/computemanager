import Foundation
import Shared

// fand placeholder: serves fand.sock answering `notImplemented`. Owner: package A.
// Does NOT touch the SMC.

func handle(_ request: FanRequest) async -> Result<FanReply, WireError> {
    .failure(.notImplemented(request.op))
}

if CommandLine.arguments.contains("--version") {
    print("fand (placeholder) protocol v\(ProtocolVersion.fand)")
    exit(0)
}

let server = FanServer(path: Paths.fandSocket) { req, _ in await handle(req) }
do {
    try server.start(mode: 0o666)
} catch {
    FileHandle.standardError.write(Data("fand: \(error)\n".utf8))
    exit(1)
}
dispatchMain()
