import Foundation

public struct FleetAgentCapabilityABI: Codable, Equatable, Sendable {
  public let id: String
  public let version: String
}

public struct FleetAgentNativeCarrier: Codable, Equatable, Sendable {
  public let kind: String
  public let availability: String
  public let status: String
}

public struct FleetAgentFreshness: Codable, Equatable, Sendable {
  public let state: String
  public let lastObservedAt: String?
  public let lastKnown: Bool
  public let reasonCode: String?

  private enum CodingKeys: String, CodingKey {
    case state
    case lastObservedAt
    case lastKnown
    case reasonCode
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(state, forKey: .state)
    try container.encode(lastObservedAt, forKey: .lastObservedAt)
    try container.encode(lastKnown, forKey: .lastKnown)
    try container.encodeIfPresent(reasonCode, forKey: .reasonCode)
  }
}

public struct FleetAgentNodeIdentity: Codable, Equatable, Sendable {
  public let stableNodeId: String
  public let displayName: String
  public let platform: String
  public let agentVersion: String
}

public struct FleetAgentRateWindow: Codable, Equatable, Sendable {
  public let windowSeconds: Int
  public let tokenRatePerSecond: Double?
  public let requestRatePerMinute: Double?

  private enum CodingKeys: String, CodingKey {
    case windowSeconds
    case tokenRatePerSecond
    case requestRatePerMinute
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(windowSeconds, forKey: .windowSeconds)
    try container.encode(tokenRatePerSecond, forKey: .tokenRatePerSecond)
    try container.encode(requestRatePerMinute, forKey: .requestRatePerMinute)
  }
}

public struct FleetAgentRateWindows: Codable, Equatable, Sendable {
  public let oneMinute: FleetAgentRateWindow
  public let fiveMinutes: FleetAgentRateWindow
}

public struct FleetAgentTelemetryPayload: Codable, Equatable, Sendable {
  public let collectionStatus: String
  public let windows: FleetAgentRateWindows
  public let activeConversationCount: Int?
  public let hostCpuPercent: Double?
  public let hostNetworkReceiveBytesPerSecond: Double?
  public let hostNetworkTransmitBytesPerSecond: Double?
  public let hostCapabilityFlags: [String]

  private enum CodingKeys: String, CodingKey {
    case collectionStatus
    case windows
    case activeConversationCount
    case hostCpuPercent
    case hostNetworkReceiveBytesPerSecond
    case hostNetworkTransmitBytesPerSecond
    case hostCapabilityFlags
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(collectionStatus, forKey: .collectionStatus)
    try container.encode(windows, forKey: .windows)
    try container.encode(activeConversationCount, forKey: .activeConversationCount)
    try container.encode(hostCpuPercent, forKey: .hostCpuPercent)
    try container.encode(
      hostNetworkReceiveBytesPerSecond,
      forKey: .hostNetworkReceiveBytesPerSecond
    )
    try container.encode(
      hostNetworkTransmitBytesPerSecond,
      forKey: .hostNetworkTransmitBytesPerSecond
    )
    try container.encode(hostCapabilityFlags, forKey: .hostCapabilityFlags)
  }
}

public struct FleetAgentDoctorCheck: Codable, Equatable, Sendable {
  public let checkId: String
  public let state: String
  public let reasonCode: String?
}

public struct FleetAgentDoctorPayload: Codable, Equatable, Sendable {
  public let doctorState: String
  public let capabilityCurrentness: String
  public let checks: [FleetAgentDoctorCheck]
}

public struct FleetAgentProviderEnvelope<Payload>: Codable, Equatable, Sendable
where Payload: Codable & Equatable & Sendable {
  public let schema: String
  public let capabilityAbi: FleetAgentCapabilityABI
  public let access: String
  public let authority: String
  public let operation: String
  public let readRef: String
  public let observedAt: String
  public let freshness: FleetAgentFreshness
  public let nativeCarrier: FleetAgentNativeCarrier
  public let node: FleetAgentNodeIdentity?
  public let payload: Payload

  private enum CodingKeys: String, CodingKey {
    case schema
    case capabilityAbi
    case access
    case authority
    case operation
    case readRef
    case observedAt
    case freshness
    case nativeCarrier
    case node
    case payload
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schema, forKey: .schema)
    try container.encode(capabilityAbi, forKey: .capabilityAbi)
    try container.encode(access, forKey: .access)
    try container.encode(authority, forKey: .authority)
    try container.encode(operation, forKey: .operation)
    try container.encode(readRef, forKey: .readRef)
    try container.encode(observedAt, forKey: .observedAt)
    try container.encode(freshness, forKey: .freshness)
    try container.encode(nativeCarrier, forKey: .nativeCarrier)
    try container.encode(node, forKey: .node)
    try container.encode(payload, forKey: .payload)
  }
}

public enum OPLFleetAgentProvider {
  public static let schema = "opl_fleet_agent_provider.v1"
  public static let telemetryRef = "fleet.agent.telemetry.v1#local"
  public static let doctorRef = "fleet.agent.doctor.v1#current"
  public static let capabilityABI = FleetAgentCapabilityABI(
    id: "opl-fleet-agent.capabilities",
    version: "1.0.0"
  )

  private static let freshAgeSeconds: TimeInterval = 90
  private static let projectedCapabilityFlags =
    OPLFleetAgentProtocol.capabilities + [
      "execution_constraints.not_projected",
      "sanitized_execution_receipts.deferred",
    ]

  public static func telemetry(
    usage: UsageSnapshot,
    identity: AmbientOpsMachineIdentity,
    fallback: UsageSnapshot? = nil,
    cpuPercent: Double? = nil,
    network: HostNetworkTelemetry? = nil,
    now: Date = Date()
  ) -> FleetAgentProviderEnvelope<FleetAgentTelemetryPayload> {
    let state = projectionState(usage: usage, fallback: fallback, now: now)
    let source = state.source
    let payload = FleetAgentTelemetryPayload(
      collectionStatus: state.collectionStatus,
      windows: FleetAgentRateWindows(
        oneMinute: rateWindow(source?.oneMinute, seconds: 60),
        fiveMinutes: rateWindow(source?.fiveMinutes, seconds: 300)
      ),
      activeConversationCount: source?.activeSessions,
      hostCpuPercent: source == nil ? nil : cpuPercent.map { min(100, max(0, $0)) },
      hostNetworkReceiveBytesPerSecond: source == nil
        ? nil : network.map { megabitsToBytes($0.downloadMbps) },
      hostNetworkTransmitBytesPerSecond: source == nil
        ? nil : network.map { megabitsToBytes($0.uploadMbps) },
      hostCapabilityFlags: source == nil ? [] : projectedCapabilityFlags
    )
    return envelope(
      operation: "telemetry.read",
      readRef: telemetryRef,
      identity: identity,
      now: now,
      state: state,
      payload: payload
    )
  }

  public static func doctor(
    usage: UsageSnapshot,
    identity: AmbientOpsMachineIdentity,
    fallback: UsageSnapshot? = nil,
    now: Date = Date()
  ) -> FleetAgentProviderEnvelope<FleetAgentDoctorPayload> {
    let state = projectionState(usage: usage, fallback: fallback, now: now)
    let payload: FleetAgentDoctorPayload
    if state.source == nil {
      payload = FleetAgentDoctorPayload(
        doctorState: "unavailable",
        capabilityCurrentness: "unavailable",
        checks: []
      )
    } else {
      let current = state.freshness.state == "fresh" && usage.status == .ready
      payload = FleetAgentDoctorPayload(
        doctorState: current ? "healthy" : "degraded",
        capabilityCurrentness: current ? "current" : "stale",
        checks: [
          FleetAgentDoctorCheck(checkId: "provider_executable", state: "pass", reasonCode: nil),
          FleetAgentDoctorCheck(
            checkId: "usage_collection",
            state: usage.status == .ready ? "pass" : "warn",
            reasonCode: usage.status == .ready ? nil : collectionReason(usage.status)
          ),
          FleetAgentDoctorCheck(
            checkId: "sample_freshness",
            state: state.freshness.state == "fresh" ? "pass" : "warn",
            reasonCode: state.freshness.state == "fresh" ? nil : "last_known_sample"
          ),
          FleetAgentDoctorCheck(
            checkId: "execution_constraints",
            state: "unavailable",
            reasonCode: "not_projected"
          ),
          FleetAgentDoctorCheck(
            checkId: "sanitized_execution_receipts",
            state: "unavailable",
            reasonCode: "deferred_no_source"
          ),
        ]
      )
    }
    return envelope(
      operation: "doctor.read",
      readRef: doctorRef,
      identity: identity,
      now: now,
      state: state,
      payload: payload
    )
  }

  public static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  private struct ProjectionState {
    let source: UsageSnapshot?
    let freshness: FleetAgentFreshness
    let collectionStatus: String
    let carrierStatus: String
  }

  private static func projectionState(
    usage: UsageSnapshot,
    fallback: UsageSnapshot?,
    now: Date
  ) -> ProjectionState {
    let source: UsageSnapshot?
    if usage.status == .ready {
      source = usage
    } else if fallback?.status == .ready {
      source = fallback
    } else {
      source = nil
    }
    guard let source else {
      return ProjectionState(
        source: nil,
        freshness: FleetAgentFreshness(
          state: "unavailable",
          lastObservedAt: nil,
          lastKnown: false,
          reasonCode: collectionReason(usage.status)
        ),
        collectionStatus: "unavailable",
        carrierStatus: "degraded"
      )
    }

    let age = max(0, now.timeIntervalSince(source.generatedAt))
    let fresh = usage.status == .ready && age <= freshAgeSeconds
    return ProjectionState(
      source: source,
      freshness: FleetAgentFreshness(
        state: fresh ? "fresh" : "stale",
        lastObservedAt: timestamp(source.generatedAt),
        lastKnown: !fresh,
        reasonCode: fresh
          ? nil : (usage.status == .ready ? "sample_stale" : collectionReason(usage.status))
      ),
      collectionStatus: fresh ? "available" : "degraded",
      carrierStatus: fresh ? "ready" : "degraded"
    )
  }

  private static func envelope<Payload>(
    operation: String,
    readRef: String,
    identity: AmbientOpsMachineIdentity,
    now: Date,
    state: ProjectionState,
    payload: Payload
  ) -> FleetAgentProviderEnvelope<Payload>
  where Payload: Codable & Equatable & Sendable {
    FleetAgentProviderEnvelope(
      schema: schema,
      capabilityAbi: capabilityABI,
      access: "read_only",
      authority: "observation_only",
      operation: operation,
      readRef: readRef,
      observedAt: timestamp(now),
      freshness: state.freshness,
      nativeCarrier: FleetAgentNativeCarrier(
        kind: "opl_fleet_agent_process",
        availability: "available",
        status: state.carrierStatus
      ),
      node: FleetAgentNodeIdentity(
        stableNodeId: identity.machineID,
        displayName: identity.machineName,
        platform: safePlatform(identity.platform),
        agentVersion: OPLFleetAgentProtocol.agentVersion
      ),
      payload: payload
    )
  }

  private static func rateWindow(
    _ metrics: WindowMetrics?,
    seconds: Int
  ) -> FleetAgentRateWindow {
    FleetAgentRateWindow(
      windowSeconds: seconds,
      tokenRatePerSecond: metrics?.tokensPerSecond,
      requestRatePerMinute: metrics?.requestsPerMinute
    )
  }

  private static func megabitsToBytes(_ value: Double) -> Double {
    max(0, value) * 1_000_000 / 8
  }

  private static func safePlatform(_ value: String) -> String {
    let safe = value.replacingOccurrences(
      of: #"[^A-Za-z0-9._-]"#,
      with: "-",
      options: .regularExpression
    )
    return String((safe.isEmpty ? "unknown" : safe).prefix(64))
  }

  private static func collectionReason(_ status: CollectionStatus) -> String {
    switch status {
    case .ready:
      return "sample_unavailable"
    case .sessionsDirectoryMissing:
      return "usage_source_unavailable"
    case .readFailed:
      return "usage_collection_failed"
    }
  }

  private static func timestamp(_ date: Date) -> String {
    date.formatted(
      Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    )
  }
}
