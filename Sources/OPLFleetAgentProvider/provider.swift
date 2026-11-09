import Foundation
import OPLFleetAgentCore

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
    let identity = try AmbientOpsMachineIdentity.providerIdentity(environment: environment)
    let now = Date()
    let codexHome = SessionScanner.defaultCodexHome(environment: environment)
    let usage = await SessionScanner(codexHome: codexHome).refresh(now: now)
    let lastKnownStore = FleetAgentLastKnownStore(
      url: FleetAgentLastKnownStore.defaultURL(environment: environment),
      binding: FleetAgentLastKnownStore.observationBinding(identity: identity, codexHome: codexHome)
    )
    let lastKnownLoad = lastKnownStore.load(now: now)
    let lastKnown = lastKnownLoad.sample
    let fallback = lastKnown?.usageSnapshot()
    let encoder = OPLFleetAgentProvider.encoder()
    let data: Data

    switch arguments[1] {
    case OPLFleetAgentProvider.telemetryRef:
      var cpuSampler = HostTelemetrySampler()
      var networkSampler = HostNetworkTelemetrySampler()
      _ = cpuSampler.sampleCPUPercent()
      _ = networkSampler.sample(at: now)
      try await Task.sleep(for: .milliseconds(100))
      let projection = OPLFleetAgentProvider.telemetry(
        usage: usage,
        identity: identity,
        fallback: fallback,
        fallbackLastObservedAt: lastKnown?.lastObservedAt,
        cpuPercent: usage.status == .ready
          ? cpuSampler.sampleCPUPercent() : lastKnown?.cpuPercent,
        network: usage.status == .ready
          ? networkSampler.sample() : lastKnown?.networkTelemetry(),
        unavailableReasonCode: lastKnownLoad.unavailableReasonCode,
        now: Date()
      )
      if projection.freshness.state == "fresh" {
        try? lastKnownStore.save(projection)
      }
      data = try encoder.encode(projection)
    case OPLFleetAgentProvider.doctorRef:
      if usage.status == .ready {
        let cacheProjection = OPLFleetAgentProvider.telemetry(
          usage: usage,
          identity: identity,
          now: now
        )
        try? lastKnownStore.save(cacheProjection)
      }
      data = try encoder.encode(
        OPLFleetAgentProvider.doctor(
          usage: usage,
          identity: identity,
          fallback: fallback,
          fallbackLastObservedAt: lastKnown?.lastObservedAt,
          unavailableReasonCode: lastKnownLoad.unavailableReasonCode,
          now: now
        )
      )
    default:
      throw ProviderCommandError.unknownRef
    }

    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
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
