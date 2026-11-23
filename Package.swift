// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "OPLFleetAgent",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .library(name: "OPLFleetAgentCore", targets: ["OPLFleetAgentCore"]),
    .executable(name: "OPLFleetAgent", targets: ["OPLFleetAgent"]),
    .executable(name: "opl-fleet-agent-snapshot", targets: ["OPLFleetAgentSnapshot"]),
    .executable(name: "opl-fleet-agent-headless", targets: ["OPLFleetAgentHeadless"]),
    .executable(name: "OPLFleetAgentProvider", targets: ["OPLFleetAgentProvider"]),
  ],
  dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1")
  ],
  targets: [
    .target(name: "OPLFleetAgentCore"),
    .executableTarget(
      name: "OPLFleetAgent",
      dependencies: [
        "OPLFleetAgentCore",
        .product(name: "Sparkle", package: "Sparkle"),
      ],
      linkerSettings: [
        .unsafeFlags([
          "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
        ])
      ]
    ),
    .executableTarget(
      name: "OPLFleetAgentSnapshot",
      dependencies: ["OPLFleetAgentCore"]
    ),
    .executableTarget(
      name: "OPLFleetAgentHeadless",
      dependencies: ["OPLFleetAgentCore"]
    ),
    .executableTarget(
      name: "OPLFleetAgentProvider",
      dependencies: ["OPLFleetAgentCore"]
    ),
    .testTarget(
      name: "OPLFleetAgentCoreTests",
      dependencies: ["OPLFleetAgentCore"]
    ),
    .testTarget(
      name: "OPLFleetAgentAppTests",
      dependencies: ["OPLFleetAgent", "OPLFleetAgentCore"]
    ),
  ]
)
