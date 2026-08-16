import Foundation

public struct AmbientOpsMachineObservation: Sendable {
  public let identity: AmbientOpsMachineIdentity
  public let snapshot: AmbientOpsAgentSnapshot
  public let petAsset: AmbientOpsPetAsset?

  public init(
    identity: AmbientOpsMachineIdentity,
    snapshot: AmbientOpsAgentSnapshot,
    petAsset: AmbientOpsPetAsset?
  ) {
    self.identity = identity
    self.snapshot = snapshot
    self.petAsset = petAsset
  }
}

public actor AmbientOpsMachineObservationStore {
  private var observation: AmbientOpsMachineObservation?
  private var networkTelemetry: HostNetworkTelemetry?

  public init() {}

  public func update(_ observation: AmbientOpsMachineObservation) {
    self.observation = observation
  }

  public func current() -> AmbientOpsMachineObservation? {
    observation
  }

  public func updateNetwork(_ telemetry: HostNetworkTelemetry) {
    networkTelemetry = telemetry
  }

  public func currentNetwork() -> HostNetworkTelemetry? {
    networkTelemetry
  }
}

public struct AmbientOpsDirectStatus: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let productName: String
  public let serverVersion: String
  public let instanceId: String
  public let generatedAt: Date
  public let demo: Bool
  public let site: Site
  public let overallStatus: String
  public let provider: Provider
  public let capabilities: Capabilities
  public let network: Network
  public let codex: Codex
  public let machines: [Machine]

  public struct Site: Codable, Equatable, Sendable {
    public let name: String
    public let timeZone: String
  }

  public struct Provider: Codable, Equatable, Sendable {
    public let kind: String
    public let scope: String
    public let id: String
    public let name: String
  }

  public struct Capabilities: Codable, Equatable, Sendable {
    public let loadVisualState: Bool
    public let network: Bool
    public let networkHistory: Bool
    public let persistentHistory: Bool
    public let pets: Bool
    public let webDisplay: Bool
    public let liveActivityPush: Bool
  }

  public struct Network: Codable, Equatable, Sendable {
    public let status: String
    public let source: String?
    public let downloadMbps: Double?
    public let uploadMbps: Double?
    public let clients: Double?
    public let latencyMs: Double?
    public let updatedAt: Date?
    public let error: String?
    public let ageSeconds: Double?
    public let history: [HistoryPoint]
  }

  public struct HistoryPoint: Codable, Equatable, Sendable {
    public let at: Date
    public let downloadMbps: Double
    public let uploadMbps: Double
  }

  public struct Codex: Codable, Equatable, Sendable {
    public let status: String
    public let oneMinuteTps: Double
    public let fiveMinuteTps: Double
    public let cachePercent: Double
    public let activeSessions: Double
    public let cpuPercent: Double?
    public let cpuReportedMachineCount: Double
    public let memoryPercent: Double?
    public let memoryReportedMachineCount: Double
    public let machineCount: Double
    public let liveMachineCount: Double
    public let staleMachineCount: Double
  }

  public struct Machine: Codable, Equatable, Sendable {
    public let machineId: String
    public let machineName: String
    public let platform: String
    public let generatedAt: Date
    public let receivedAt: Date
    public let reportedStatus: String
    public let error: String?
    public let oneMinute: AmbientOpsWindowSnapshot
    public let fiveMinutes: AmbientOpsWindowSnapshot
    public let activeSessions: Double
    public let cpuPercent: Double?
    public let memoryPercent: Double?
    public let pet: Pet?
    public let status: String
    public let ageSeconds: Double
    public let cachePercent: Double
    public let loadVisualState: AmbientOpsLoadVisualState
  }

  public struct Pet: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let spriteVersionNumber: Int
    public let assetHash: String
    public let state: AmbientOpsPetState
    public let stateSince: Date
    public let assetUrl: String
  }
}

public struct AmbientOpsLoadVisualState: Codable, Equatable, Sendable {
  public let modelVersion: Int
  public let state: String
  public let label: String
  public let score: Double
  public let constrained: Bool
  public let activity: Double
  public let parallel: Double
  public let tempo: Double
  public let travelMs: Double
  public let clusterCount: Int
  public let taskDensity: Double
  public let pressure: Double
  public let queueDepth: Double
  public let heat: Double
}

public enum AmbientOpsLoadModel {
  public static let modelVersion = 1

  public static func visualState(
    tps: Double,
    activeSessions: Double,
    cpuPercent: Double?
  ) -> AmbientOpsLoadVisualState {
    let safeTPS = max(0, tps)
    let sessions = max(0, activeSessions)
    let cpu = cpuPercent.map { clamp($0, 0, 100) }
    let tpsIntensity = clamp(sqrt(safeTPS / 60_000), 0, 1)
    let sessionIntensity = min(1, sessions / 12)
    let cpuIntensity = cpu.map { min(1, max(0, $0 / 100)) }
    let score =
      cpuIntensity.map {
        tpsIntensity * 0.56 + sessionIntensity * 0.22 + $0 * 0.22
      } ?? (tpsIntensity * 0.72 + sessionIntensity * 0.28)
    let normalizedScore = clamp(score, 0, 1)
    let hasWork = safeTPS > 0 || sessions > 0
    let pressure = cpu.map { clamp(($0 - 68) / 32, 0, 1) } ?? 0
    let constrained =
      hasWork
      && cpu.map {
        $0 >= 88 && normalizedScore >= 0.35
      } == true
    let parallel = hasWork ? clamp(sqrt(sessions / 18), 0, 1) : 0
    let tempo =
      hasWork
      ? clamp(0.45 + normalizedScore * 1.35 + sqrt(safeTPS / 90_000) * 0.7, 0.45, 2.5)
      : 0.2
    let clusterCount =
      hasWork
      ? max(1, min(4, Int((1 + parallel * 3).rounded())))
      : 0
    let activity =
      hasWork
      ? clamp(normalizedScore * 0.72 + parallel * 0.28, 0, 1)
      : 0
    let travelSeconds = clamp(
      3.1 - tpsIntensity * 1.8 - sessionIntensity * 0.35,
      0.8,
      3.1
    )
    let travelMs = hasWork ? clamp(travelSeconds * 1_000, 800, 3_100) : 4_800
    let queueDepth =
      constrained
      ? clamp(0.24 + pressure * 0.76, 0.24, 1)
      : clamp(max(0, normalizedScore - 0.68) * 0.7, 0, 0.25)
    let state: (id: String, label: String)
    if constrained {
      state = ("constrained", "CONSTRAINED")
    } else if normalizedScore >= 0.45 {
      state = ("heavy", "HEAVY")
    } else if normalizedScore >= 0.18 {
      state = ("active", "ACTIVE")
    } else {
      state = ("quiet", "QUIET")
    }

    return AmbientOpsLoadVisualState(
      modelVersion: modelVersion,
      state: state.id,
      label: state.label,
      score: normalizedScore,
      constrained: constrained,
      activity: activity,
      parallel: parallel,
      tempo: tempo,
      travelMs: travelMs,
      clusterCount: clusterCount,
      taskDensity: hasWork
        ? clamp(0.16 + activity * 0.68 + parallel * 0.16, 0.16, 1)
        : 0,
      pressure: pressure,
      queueDepth: queueDepth,
      heat: clamp(pressure * 0.9 + activity * 0.12, 0, 1)
    )
  }

  private static func clamp(_ value: Double, _ minimum: Double, _ maximum: Double) -> Double {
    max(minimum, min(maximum, value))
  }
}

public enum AmbientOpsDirectStatusBuilder {
  public static func build(
    observation: AmbientOpsMachineObservation,
    serverVersion: String,
    networkTelemetry: HostNetworkTelemetry? = nil,
    now: Date = Date()
  ) -> AmbientOpsDirectStatus {
    let identity = observation.identity
    let snapshot = observation.snapshot
    let live = snapshot.status == "live"
    let totalInput = snapshot.oneMinute.inputTokens
    let cachePercent =
      totalInput > 0
      ? (Double(snapshot.oneMinute.cachedInputTokens) / Double(totalInput) * 100).rounded()
      : 0
    let visual = AmbientOpsLoadModel.visualState(
      tps: snapshot.oneMinute.tps,
      activeSessions: Double(snapshot.activeSessions),
      cpuPercent: snapshot.cpuPercent
    )
    let pet = snapshot.pet.map {
      AmbientOpsDirectStatus.Pet(
        id: $0.id,
        displayName: $0.displayName,
        spriteVersionNumber: $0.spriteVersionNumber,
        assetHash: $0.assetHash,
        state: $0.state,
        stateSince: $0.stateSince,
        assetUrl: "/api/v1/pets/\($0.assetHash)"
      )
    }
    let machine = AmbientOpsDirectStatus.Machine(
      machineId: identity.machineID,
      machineName: identity.machineName,
      platform: identity.platform,
      generatedAt: snapshot.generatedAt,
      receivedAt: now,
      reportedStatus: snapshot.status,
      error: snapshot.error,
      oneMinute: snapshot.oneMinute,
      fiveMinutes: snapshot.fiveMinutes,
      activeSessions: Double(snapshot.activeSessions),
      cpuPercent: snapshot.cpuPercent,
      memoryPercent: nil,
      pet: pet,
      status: live ? "live" : "error",
      ageSeconds: max(0, now.timeIntervalSince(snapshot.generatedAt).rounded()),
      cachePercent: cachePercent,
      loadVisualState: visual
    )
    let providerID = "opl-fleet-agent-\(identity.machineID)"
    let status = live ? "live" : "error"

    return AmbientOpsDirectStatus(
      schemaVersion: 1,
      productName: OPLFleetAgentProtocol.productName,
      serverVersion: serverVersion,
      instanceId: providerID,
      generatedAt: now,
      demo: false,
      site: .init(
        name: identity.machineName,
        timeZone: TimeZone.current.identifier
      ),
      overallStatus: status,
      provider: .init(
        kind: "opl-fleet-agent",
        scope: "machine",
        id: identity.machineID,
        name: identity.machineName
      ),
      capabilities: .init(
        loadVisualState: true,
        network: true,
        networkHistory: false,
        persistentHistory: false,
        pets: true,
        webDisplay: false,
        liveActivityPush: false
      ),
      network: .init(
        status: networkTelemetry == nil ? "unavailable" : "live",
        source: "host",
        downloadMbps: networkTelemetry?.downloadMbps,
        uploadMbps: networkTelemetry?.uploadMbps,
        clients: nil,
        latencyMs: nil,
        updatedAt: networkTelemetry?.sampledAt,
        error: nil,
        ageSeconds: networkTelemetry.map {
          max(0, now.timeIntervalSince($0.sampledAt).rounded())
        },
        history: []
      ),
      codex: .init(
        status: status,
        oneMinuteTps: snapshot.oneMinute.tps,
        fiveMinuteTps: snapshot.fiveMinutes.tps,
        cachePercent: cachePercent,
        activeSessions: Double(snapshot.activeSessions),
        cpuPercent: snapshot.cpuPercent,
        cpuReportedMachineCount: snapshot.cpuPercent == nil ? 0 : 1,
        memoryPercent: nil,
        memoryReportedMachineCount: 0,
        machineCount: 1,
        liveMachineCount: live ? 1 : 0,
        staleMachineCount: 0
      ),
      machines: [machine]
    )
  }

  public static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
}
