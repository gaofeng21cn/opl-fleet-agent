import CodexTPSCore
import Foundation

@main
struct OPLFleetAgentProviderCommand {
  static func main() async throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.contains("--help") || arguments.contains("-h") {
      print(
        "Usage: OPLFleetAgentProvider --ref <fleet.agent.telemetry.v1#local|fleet.agent.doctor.v1#current>"
      )
      return
    }
    guard arguments.count == 2, arguments[0] == "--ref" else {
      throw ProviderCommandError.invalidArguments
    }

    let environment = ProcessInfo.processInfo.environment
    let identity = try localIdentity(environment: environment)
    let usage = await SessionScanner().refresh()
    let now = Date()
    let encoder = OPLFleetAgentProvider.encoder()
    let data: Data

    switch arguments[1] {
    case OPLFleetAgentProvider.telemetryRef:
      var cpuSampler = HostTelemetrySampler()
      var networkSampler = HostNetworkTelemetrySampler()
      _ = cpuSampler.sampleCPUPercent()
      _ = networkSampler.sample(at: now)
      try await Task.sleep(for: .milliseconds(100))
      data = try encoder.encode(
        OPLFleetAgentProvider.telemetry(
          usage: usage,
          identity: identity,
          cpuPercent: cpuSampler.sampleCPUPercent(),
          network: networkSampler.sample(),
          now: Date()
        )
      )
    case OPLFleetAgentProvider.doctorRef:
      data = try encoder.encode(
        OPLFleetAgentProvider.doctor(usage: usage, identity: identity, now: now)
      )
    default:
      throw ProviderCommandError.unknownRef
    }

    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
  }

  private static func localIdentity(
    environment: [String: String]
  ) throws -> AmbientOpsMachineIdentity {
    let hostName = ProcessInfo.processInfo.hostName
    let defaultID =
      hostName
      .split(separator: ".")
      .first
      .map(String.init)?
      .lowercased()
      .replacingOccurrences(
        of: #"[^a-z0-9._-]"#,
        with: "-",
        options: .regularExpression
      ) ?? "mac"
    let machineID = environment["CODEX_TPS_MACHINE_ID"] ?? defaultID
    let machineName =
      environment["CODEX_TPS_MACHINE_NAME"]
      ?? Host.current().localizedName
      ?? machineID
    return try AmbientOpsMachineIdentity(
      machineID: machineID,
      machineName: machineName,
      platform: environment["CODEX_TPS_PLATFORM"] ?? "macOS"
    )
  }
}

private enum ProviderCommandError: LocalizedError {
  case invalidArguments
  case unknownRef

  var errorDescription: String? {
    switch self {
    case .invalidArguments:
      return "Invalid arguments"
    case .unknownRef:
      return "Unsupported provider ref"
    }
  }
}
