// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ComputeManager",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ComputeManager", targets: ["ComputeManager"]),
        .executable(name: "fand", targets: ["fand"]),
        .executable(name: "cgate", targets: ["cgate"]),
    ],
    targets: [
        // IPC contracts, codecs, exit codes, defaults, socket helper. Owned by orchestrator.
        .target(name: "Shared"),
        // Gate state machine + gate socket server (hosted by the app).
        .target(name: "GateCore", dependencies: ["Shared"]),
        // SwiftUI MenuBarExtra app.
        .executableTarget(name: "ComputeManager", dependencies: ["Shared", "GateCore"]),
        // Root LaunchDaemon talking to the SMC.
        .executableTarget(name: "fand", dependencies: ["Shared"]),
        // CLI used by hooks and agents. Logic lives in CgateKit-style files inside the
        // target; tests use @testable import.
        .executableTarget(name: "cgate", dependencies: ["Shared"]),
        .testTarget(name: "SharedTests", dependencies: ["Shared"]),
        .testTarget(name: "GateCoreTests", dependencies: ["GateCore", "Shared"]),
        .testTarget(name: "cgateTests", dependencies: ["cgate", "Shared"]),
        .testTarget(name: "fandTests", dependencies: ["fand", "Shared"]),
    ]
)
