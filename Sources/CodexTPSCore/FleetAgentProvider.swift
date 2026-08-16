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
    fallbackLastObservedAt: String? = nil,
    cpuPercent: Double? = nil,
    network: HostNetworkTelemetry? = nil,
    unavailableReasonCode: String? = nil,
    now: Date = Date()
  ) -> FleetAgentProviderEnvelope<FleetAgentTelemetryPayload> {
    let state = projectionState(
      usage: usage,
      fallback: fallback,
      fallbackLastObservedAt: fallbackLastObservedAt,
      unavailableReasonCode: unavailableReasonCode,
      now: now
    )
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
    fallbackLastObservedAt: String? = nil,
    unavailableReasonCode: String? = nil,
    now: Date = Date()
  ) -> FleetAgentProviderEnvelope<FleetAgentDoctorPayload> {
    let state = projectionState(
      usage: usage,
      fallback: fallback,
      fallbackLastObservedAt: fallbackLastObservedAt,
      unavailableReasonCode: unavailableReasonCode,
      now: now
    )
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
    fallbackLastObservedAt: String?,
    unavailableReasonCode: String?,
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
          reasonCode: unavailableReasonCode ?? collectionReason(usage.status)
        ),
        collectionStatus: "unavailable",
        carrierStatus: "degraded"
      )
    }

    let age = max(0, now.timeIntervalSince(source.generatedAt))
    let fresh = usage.status == .ready && age <= freshAgeSeconds
    let lastObservedAt = usage.status == .ready
      ? timestamp(source.generatedAt)
      : (fallbackLastObservedAt ?? timestamp(source.generatedAt))
    return ProjectionState(
      source: source,
      freshness: FleetAgentFreshness(
        state: fresh ? "fresh" : "stale",
        lastObservedAt: lastObservedAt,
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

public struct FleetAgentLastKnownSample: Equatable, Sendable {
  public let lastObservedAt: String
  public let observedAt: Date
  public let payload: FleetAgentTelemetryPayload

  public func usageSnapshot() -> UsageSnapshot {
    UsageSnapshot(
      generatedAt: observedAt,
      oneMinute: metrics(payload.windows.oneMinute),
      fiveMinutes: metrics(payload.windows.fiveMinutes),
      thirtyMinutes: .empty(windowSeconds: 1_800),
      oneHour: .empty(windowSeconds: 3_600),
      activeSessions: payload.activeConversationCount ?? 0,
      malformedRelevantLines: 0,
      status: .ready
    )
  }

  public var cpuPercent: Double? {
    payload.hostCpuPercent
  }

  public func networkTelemetry() -> HostNetworkTelemetry? {
    guard
      let receive = payload.hostNetworkReceiveBytesPerSecond,
      let transmit = payload.hostNetworkTransmitBytesPerSecond
    else {
      return nil
    }
    return HostNetworkTelemetry(
      downloadMbps: receive * 8 / 1_000_000,
      uploadMbps: transmit * 8 / 1_000_000,
      sampledAt: observedAt
    )
  }

  private func metrics(_ value: FleetAgentRateWindow) -> WindowMetrics {
    WindowMetrics(
      windowSeconds: value.windowSeconds,
      requestCount: 0,
      requestsPerMinute: value.requestRatePerMinute ?? 0,
      tokensPerSecond: value.tokenRatePerSecond ?? 0,
      inputTokensPerSecond: 0,
      cachedInputTokensPerSecond: 0,
      outputTokensPerSecond: 0,
      reasoningTokensPerSecond: 0,
      cacheRatio: 0,
      totalTokens: 0
    )
  }
}

public enum FleetAgentLastKnownLoad: Equatable, Sendable {
  case available(FleetAgentLastKnownSample)
  case missing
  case expired
  case invalid
  case privacyRejected

  public var sample: FleetAgentLastKnownSample? {
    guard case .available(let sample) = self else { return nil }
    return sample
  }

  public var unavailableReasonCode: String? {
    switch self {
    case .available, .missing:
      return nil
    case .expired:
      return "last_known_cache_expired"
    case .invalid:
      return "last_known_cache_invalid"
    case .privacyRejected:
      return "last_known_cache_privacy_rejected"
    }
  }
}

public struct FleetAgentLastKnownStore: Sendable {
  public static let ttlSeconds: TimeInterval = 15 * 60

  private static let maximumBytes = 65_536
  private static let forbiddenKeyParts = [
    "prompt", "response", "session", "path", "address", "credential", "secret", "raw_log",
    "rawlog",
  ]
  private static let forbiddenAuthorityKeys: Set<String> = [
    "admission", "lease", "dispatch", "task_completion", "completion_verdict",
  ]

  private let url: URL

  public init(url: URL) {
    self.url = url
  }

  public static func defaultURL(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    if let configured = environment["OPL_FLEET_AGENT_PROVIDER_CACHE"]?
      .trimmingCharacters(in: .whitespacesAndNewlines), !configured.isEmpty
    {
      return URL(fileURLWithPath: NSString(string: configured).expandingTildeInPath)
    }
    let home = environment["HOME"]
      .flatMap { $0.isEmpty ? nil : $0 }
      .map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? FileManager.default.homeDirectoryForCurrentUser
    return home
      .appendingPathComponent("Library/Application Support/OPL Fleet Agent", isDirectory: true)
      .appendingPathComponent("provider-last-known.json")
  }

  public func load(now: Date = Date()) -> FleetAgentLastKnownLoad {
    guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
    let data: Data
    do {
      data = try Data(contentsOf: url, options: [.mappedIfSafe])
    } catch {
      remove()
      return .invalid
    }
    guard data.count <= Self.maximumBytes else {
      remove()
      return .invalid
    }
    guard let object = try? JSONSerialization.jsonObject(with: data) else {
      remove()
      return .invalid
    }
    if Self.containsForbiddenKey(object) {
      remove()
      return .privacyRejected
    }
    guard Self.hasExactCacheShape(object) else {
      remove()
      return .invalid
    }

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    guard
      let record = try? decoder.decode(CacheRecord.self, from: data),
      let observedAt = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        .parse(record.lastObservedAt),
      Self.isValid(record.payload)
    else {
      remove()
      return .invalid
    }
    let age = now.timeIntervalSince(observedAt)
    guard age >= 0 else {
      remove()
      return .invalid
    }
    guard age <= Self.ttlSeconds else {
      remove()
      return .expired
    }
    return .available(
      FleetAgentLastKnownSample(
        lastObservedAt: record.lastObservedAt,
        observedAt: observedAt,
        payload: record.payload
      )
    )
  }

  public func save(
    _ projection: FleetAgentProviderEnvelope<FleetAgentTelemetryPayload>
  ) throws {
    guard
      projection.freshness.state == "fresh",
      projection.freshness.lastKnown == false,
      let lastObservedAt = projection.freshness.lastObservedAt,
      Self.isValid(projection.payload)
    else {
      throw CacheError.invalidProjection
    }
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try OPLFleetAgentProvider.encoder().encode(
      CacheRecord(lastObservedAt: lastObservedAt, payload: projection.payload)
    )
    try data.write(to: url, options: [.atomic])
    do {
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))],
        ofItemAtPath: url.path
      )
    } catch {
      remove()
      throw error
    }
  }

  private struct CacheRecord: Codable {
    let lastObservedAt: String
    let payload: FleetAgentTelemetryPayload
  }

  private enum CacheError: Error {
    case invalidProjection
  }

  private func remove() {
    try? FileManager.default.removeItem(at: url)
  }

  private static func containsForbiddenKey(_ value: Any) -> Bool {
    if let array = value as? [Any] {
      return array.contains(where: containsForbiddenKey)
    }
    guard let dictionary = value as? [String: Any] else { return false }
    return dictionary.contains { key, child in
      let normalized = key.lowercased()
      return forbiddenKeyParts.contains(where: normalized.contains)
        || forbiddenAuthorityKeys.contains(normalized)
        || containsForbiddenKey(child)
    }
  }

  private static func hasExactCacheShape(_ value: Any) -> Bool {
    guard
      let root = value as? [String: Any],
      Set(root.keys) == ["last_observed_at", "payload"],
      let payload = root["payload"] as? [String: Any],
      Set(payload.keys) == [
        "collection_status", "windows", "active_conversation_count", "host_cpu_percent",
        "host_network_receive_bytes_per_second", "host_network_transmit_bytes_per_second",
        "host_capability_flags",
      ],
      let windows = payload["windows"] as? [String: Any],
      Set(windows.keys) == ["one_minute", "five_minutes"],
      hasExactWindowShape(windows["one_minute"]),
      hasExactWindowShape(windows["five_minutes"])
    else {
      return false
    }
    return true
  }

  private static func hasExactWindowShape(_ value: Any?) -> Bool {
    guard let window = value as? [String: Any] else { return false }
    return Set(window.keys) == [
      "window_seconds", "token_rate_per_second", "request_rate_per_minute",
    ]
  }

  private static func isValid(_ payload: FleetAgentTelemetryPayload) -> Bool {
    guard
      payload.collectionStatus == "available",
      payload.windows.oneMinute.windowSeconds == 60,
      payload.windows.fiveMinutes.windowSeconds == 300,
      isNonNegative(payload.windows.oneMinute.tokenRatePerSecond),
      isNonNegative(payload.windows.oneMinute.requestRatePerMinute),
      isNonNegative(payload.windows.fiveMinutes.tokenRatePerSecond),
      isNonNegative(payload.windows.fiveMinutes.requestRatePerMinute),
      let active = payload.activeConversationCount, active >= 0,
      isOptionalRange(payload.hostCpuPercent, minimum: 0, maximum: 100),
      isOptionalNonNegative(payload.hostNetworkReceiveBytesPerSecond),
      isOptionalNonNegative(payload.hostNetworkTransmitBytesPerSecond),
      Set(payload.hostCapabilityFlags).count == payload.hostCapabilityFlags.count,
      payload.hostCapabilityFlags.allSatisfy({ flag in
        flag.count <= 64
          && flag.range(of: #"^[a-z][a-z0-9._-]*$"#, options: .regularExpression) != nil
      })
    else {
      return false
    }
    return true
  }

  private static func isNonNegative(_ value: Double?) -> Bool {
    guard let value else { return false }
    return value.isFinite && value >= 0
  }

  private static func isOptionalNonNegative(_ value: Double?) -> Bool {
    value.map { $0.isFinite && $0 >= 0 } ?? true
  }

  private static func isOptionalRange(
    _ value: Double?,
    minimum: Double,
    maximum: Double
  ) -> Bool {
    value.map { $0.isFinite && $0 >= minimum && $0 <= maximum } ?? true
  }
}
