// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "CodexTPS",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .library(name: "CodexTPSCore", targets: ["CodexTPSCore"]),
    .executable(name: "CodexTPS", targets: ["CodexTPS"]),
    .executable(name: "codex-tps-snapshot", targets: ["CodexTPSSnapshot"]),
    .executable(name: "codex-tps-agent", targets: ["CodexTPSAgent"]),
    .executable(name: "OPLFleetAgentProvider", targets: ["CodexTPSProvider"]),
  ],
  targets: [
    .target(name: "CodexTPSCore"),
    .executableTarget(
      name: "CodexTPS",
      dependencies: ["CodexTPSCore"]
    ),
    .executableTarget(
      name: "CodexTPSSnapshot",
      dependencies: ["CodexTPSCore"]
    ),
    .executableTarget(
      name: "CodexTPSAgent",
      dependencies: ["CodexTPSCore"]
    ),
    .executableTarget(
      name: "CodexTPSProvider",
      dependencies: ["CodexTPSCore"]
    ),
    .testTarget(
      name: "CodexTPSCoreTests",
      dependencies: ["CodexTPSCore"]
    ),
    .testTarget(
      name: "CodexTPSAppTests",
      dependencies: ["CodexTPS", "CodexTPSCore"]
    ),
  ]
)
