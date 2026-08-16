import Foundation
import OPLFleetAgentCore
import Security

@main
struct OPLFleetAgentHeadlessCommand {
  static func main() async throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.contains("--help") || arguments.contains("-h") {
      print(Self.usage)
      return
    }
    guard arguments.allSatisfy({ $0 == "--once" }) else {
      throw AgentError.invalidArguments
    }

    let configuration = try AgentConfiguration(environment: ProcessInfo.processInfo.environment)
    let scanner = SessionScanner(codexHome: configuration.codexHome)
    let petCatalog = AmbientOpsPetAssetCatalog(
      codexHome: configuration.codexHome,
      preferredPetID: configuration.preferredPetID
    )
    let networkTelemetryStore = AmbientOpsMachineObservationStore()
    let networkTelemetryTask = Task.detached(priority: .utility) {
      var sampler = HostNetworkTelemetrySampler()
      _ = sampler.sample()
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        if let telemetry = sampler.sample() {
          await networkTelemetryStore.updateNetwork(telemetry)
        }
      }
    }
    defer { networkTelemetryTask.cancel() }
    var lastSuccessfulSnapshot: AmbientOpsAgentSnapshot?
    var hostTelemetry = HostTelemetrySampler()
    var petTracker = AmbientOpsPetTracker()
    var consecutiveFailures = 0
    var discoveredServices: [AmbientOpsService] = []
    var selectedService: AmbientOpsService?
    var selector = AmbientOpsServiceSelector(
      preferredInstanceID: configuration.preferredInstanceID)

    repeat {
      let usage = await scanner.refresh()
      let petAsset =
        configuration.petEnabled ? await petCatalog.currentAsset() : nil
      let pet = petAsset.map {
        petTracker.snapshot(definition: $0.definition, usage: usage)
      }
      let networkTelemetry = await networkTelemetryStore.currentNetwork()
      let snapshot = AmbientOpsAgentSnapshot(
        usage: usage,
        identity: configuration.identity,
        fallback: lastSuccessfulSnapshot,
        cpuPercent: hostTelemetry.sampleCPUPercent(),
        network: networkTelemetry,
        pet: pet
      )
      if usage.status == .ready {
        lastSuccessfulSnapshot = snapshot
      }

      do {
        if let endpoint = configuration.endpoint {
          try await Self.push(
            snapshot,
            to: endpoint,
            configuration: configuration,
            petAsset: petAsset
          )
        } else {
          if selectedService == nil {
            if discoveredServices.isEmpty {
              selector.resetFailures()
              discoveredServices = await Self.discoverServices()
            }
            selectedService = selector.select(from: discoveredServices)
          }
          guard let service = selectedService else {
            throw AgentError.discoveryUnavailable
          }
          do {
            try await Self.push(
              snapshot,
              to: service.endpoint,
              configuration: configuration,
              petAsset: petAsset
            )
          } catch {
            selector.recordPushFailure(for: service)
            selectedService = selector.select(from: discoveredServices)
            guard let fallback = selectedService else {
              discoveredServices.removeAll()
              throw error
            }
            try await Self.push(
              snapshot,
              to: fallback.endpoint,
              configuration: configuration,
              petAsset: petAsset
            )
          }
        }
        consecutiveFailures = 0
        print(
          "Pushed \(configuration.identity.machineID): "
            + "\(snapshot.oneMinute.tps.formatted(.number.precision(.fractionLength(1)))) TPS"
        )
      } catch {
        consecutiveFailures += 1
        FileHandle.standardError.write(
          Data("Push failed: \(error.localizedDescription)\n".utf8))
        if arguments.contains("--once") {
          throw error
        }
      }

      if arguments.contains("--once") {
        break
      }
      let multiplier = min(pow(2, Double(consecutiveFailures)), 6)
      let delay = min(configuration.intervalSeconds * multiplier, 60)
      try await Task.sleep(for: .seconds(delay))
    } while !Task.isCancelled
  }

  private static func push(
    _ snapshot: AmbientOpsAgentSnapshot,
    to endpoint: URL,
    configuration: AgentConfiguration,
    petAsset: AmbientOpsPetAsset?
  ) async throws {
    let request = try AmbientOpsPushRequest(
      endpoint: endpoint,
      token: configuration.token,
      identity: configuration.identity
    )
    try await AmbientOpsPushClient(request: request).push(snapshot, petAsset: petAsset)
  }

  @MainActor
  private static func discoverServices() async -> [AmbientOpsService] {
    let discovery = AmbientOpsDiscovery()
    var services: [AmbientOpsService] = []
    discovery.onServiceResolved = { service in
      if !services.contains(service) {
        services.append(service)
      }
    }
    discovery.start(preferredInstanceID: nil)
    try? await Task.sleep(for: .seconds(3))
    discovery.stop()
    return services
  }

  private static let usage = """
    Usage: opl-fleet-agent-headless [--once]

    Required environment:
      OPL_FLEET_AGENT_AMBIENT_TOKEN     Agent push token, or use the Keychain option

    Optional environment:
      OPL_FLEET_AGENT_AMBIENT_URL       Explicit OPL Fleet Gateway base URL; otherwise use mDNS
      OPL_FLEET_AGENT_AMBIENT_INSTANCE_ID
                                   Preferred discovered OPL Fleet Gateway instance ID
      OPL_FLEET_AGENT_AMBIENT_TOKEN_KEYCHAIN_SERVICE
                                   Generic-password Keychain service name
      OPL_FLEET_AGENT_KEYCHAIN_ACCOUNT  Keychain account (default: current user)
      OPL_FLEET_AGENT_MACHINE_ID        Stable machine ID (default: short hostname)
      OPL_FLEET_AGENT_MACHINE_NAME      Display name (default: localized hostname)
      OPL_FLEET_AGENT_PLATFORM          Platform label (default: macOS)
      OPL_FLEET_AGENT_PUSH_INTERVAL     Push interval in seconds (default: 10)
      OPL_FLEET_AGENT_PET_ID            Preferred local pet ID; use none to disable
      CODEX_HOME                  Alternate Codex home
    """
}

private struct AgentConfiguration {
  let endpoint: URL?
  let preferredInstanceID: String?
  let token: String
  let identity: AmbientOpsMachineIdentity
  let intervalSeconds: Double
  let codexHome: URL
  let petEnabled: Bool
  let preferredPetID: String?

  init(environment: [String: String]) throws {
    if let endpointValue = environment["OPL_FLEET_AGENT_AMBIENT_URL"], !endpointValue.isEmpty {
      guard
        let endpoint = URL(string: endpointValue),
        ["http", "https"].contains(endpoint.scheme?.lowercased() ?? ""),
        endpoint.host != nil
      else {
        throw AgentError.invalidEndpoint
      }
      self.endpoint = endpoint
    } else {
      endpoint = nil
    }
    preferredInstanceID = environment["OPL_FLEET_AGENT_AMBIENT_INSTANCE_ID"]
    let token =
      environment["OPL_FLEET_AGENT_AMBIENT_TOKEN"]
      ?? Self.keychainToken(environment: environment)
    guard let token, !token.isEmpty else {
      throw AgentError.missingEnvironment("OPL_FLEET_AGENT_AMBIENT_TOKEN")
    }

    let hostName = ProcessInfo.processInfo.hostName
    let defaultID =
      hostName
      .split(separator: ".")
      .first
      .map(String.init)?
      .lowercased()
      .replacingOccurrences(
        of: #"[^a-z0-9._-]"#, with: "-", options: .regularExpression)
      ?? "mac"
    let machineID = environment["OPL_FLEET_AGENT_MACHINE_ID"] ?? defaultID
    let machineName =
      environment["OPL_FLEET_AGENT_MACHINE_NAME"]
      ?? Host.current().localizedName
      ?? machineID
    identity = try AmbientOpsMachineIdentity(
      machineID: machineID,
      machineName: machineName,
      platform: environment["OPL_FLEET_AGENT_PLATFORM"] ?? "macOS"
    )
    self.token = token

    let interval = Double(environment["OPL_FLEET_AGENT_PUSH_INTERVAL"] ?? "10") ?? 10
    guard interval >= 2, interval <= 300 else {
      throw AgentError.invalidInterval
    }
    intervalSeconds = interval

    codexHome = SessionScanner.defaultCodexHome(environment: environment)
    let petID = environment["OPL_FLEET_AGENT_PET_ID"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    if petID == "none" {
      petEnabled = false
      preferredPetID = nil
    } else {
      petEnabled = true
      preferredPetID = petID
    }
  }

  private static func keychainToken(environment: [String: String]) -> String? {
    guard let service = environment["OPL_FLEET_AGENT_AMBIENT_TOKEN_KEYCHAIN_SERVICE"],
      !service.isEmpty
    else { return nil }
    let account = environment["OPL_FLEET_AGENT_KEYCHAIN_ACCOUNT"] ?? NSUserName()
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }
}

private enum AgentError: LocalizedError {
  case invalidArguments
  case missingEnvironment(String)
  case invalidInterval
  case invalidEndpoint
  case discoveryUnavailable

  var errorDescription: String? {
    switch self {
    case .invalidArguments:
      return "Invalid arguments. Use --help for usage."
    case .missingEnvironment(let name):
      return "Missing required environment variable \(name)"
    case .invalidInterval:
      return "OPL_FLEET_AGENT_PUSH_INTERVAL must be between 2 and 300 seconds"
    case .invalidEndpoint:
      return "OPL_FLEET_AGENT_AMBIENT_URL must be an absolute HTTP or HTTPS URL"
    case .discoveryUnavailable:
      return "No compatible _ambient-ops._tcp.local service was discovered"
    }
  }
}
