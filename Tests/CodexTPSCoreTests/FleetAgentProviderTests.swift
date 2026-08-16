import Foundation
import XCTest

@testable import CodexTPSCore

final class FleetAgentProviderTests: XCTestCase {
  private let observedAt = Date(timeIntervalSince1970: 1_755_331_200)

  func testAdvertisesOnlyImplementedNativeCapabilities() {
    XCTAssertEqual(
      OPLFleetAgentProtocol.capabilities,
      [
        "node_local_observation",
        "node_local_doctor",
        "local_codex_telemetry",
        "host_dashboard",
      ])
  }

  func testProjectsFreshAggregateTelemetryWithoutAuthorityVerdicts() throws {
    let projection = OPLFleetAgentProvider.telemetry(
      usage: usage(at: observedAt),
      identity: try identity(),
      cpuPercent: 42.5,
      network: HostNetworkTelemetry(
        downloadMbps: 123.5,
        uploadMbps: 12.25,
        sampledAt: observedAt
      ),
      now: observedAt.addingTimeInterval(30)
    )

    XCTAssertEqual(projection.schema, "opl_fleet_agent_provider.v1")
    XCTAssertEqual(projection.capabilityAbi.id, "opl-fleet-agent.capabilities")
    XCTAssertEqual(projection.access, "read_only")
    XCTAssertEqual(projection.authority, "observation_only")
    XCTAssertEqual(projection.operation, "telemetry.read")
    XCTAssertEqual(projection.readRef, "fleet.agent.telemetry.v1#local")
    XCTAssertEqual(projection.observedAt, "2025-08-16T08:00:30.000Z")
    XCTAssertEqual(projection.freshness.state, "fresh")
    XCTAssertEqual(projection.freshness.lastObservedAt, "2025-08-16T08:00:00.000Z")
    XCTAssertEqual(projection.freshness.lastKnown, false)
    XCTAssertEqual(projection.nativeCarrier.availability, "available")
    XCTAssertEqual(projection.nativeCarrier.status, "ready")
    XCTAssertEqual(projection.node?.stableNodeId, "fixture-node")
    XCTAssertEqual(projection.payload.collectionStatus, "available")
    XCTAssertEqual(projection.payload.windows.oneMinute.tokenRatePerSecond, 10)
    XCTAssertEqual(projection.payload.windows.oneMinute.requestRatePerMinute, 2)
    XCTAssertEqual(projection.payload.windows.fiveMinutes.tokenRatePerSecond, 4)
    XCTAssertEqual(projection.payload.windows.fiveMinutes.requestRatePerMinute, 1)
    XCTAssertEqual(projection.payload.activeConversationCount, 3)
    XCTAssertEqual(projection.payload.hostCpuPercent, 42.5)
    XCTAssertEqual(projection.payload.hostNetworkReceiveBytesPerSecond, 15_437_500)
    XCTAssertEqual(projection.payload.hostNetworkTransmitBytesPerSecond, 1_531_250)
    XCTAssertTrue(
      projection.payload.hostCapabilityFlags.contains("execution_constraints.not_projected"))
    XCTAssertTrue(
      projection.payload.hostCapabilityFlags.contains("sanitized_execution_receipts.deferred"))
  }

  func testCollectionFallbackIsExplicitlyStale() throws {
    let failedAt = observedAt.addingTimeInterval(300)
    let projection = OPLFleetAgentProvider.telemetry(
      usage: .empty(at: failedAt, status: .readFailed),
      identity: try identity(),
      fallback: usage(at: observedAt),
      now: failedAt
    )

    XCTAssertEqual(projection.observedAt, "2025-08-16T08:05:00.000Z")
    XCTAssertEqual(projection.freshness.state, "stale")
    XCTAssertEqual(projection.freshness.lastObservedAt, "2025-08-16T08:00:00.000Z")
    XCTAssertEqual(projection.freshness.lastKnown, true)
    XCTAssertEqual(projection.freshness.reasonCode, "usage_collection_failed")
    XCTAssertEqual(projection.payload.collectionStatus, "degraded")
    XCTAssertEqual(projection.payload.windows.oneMinute.tokenRatePerSecond, 10)
    XCTAssertEqual(projection.payload.activeConversationCount, 3)
  }

  func testUnavailableCollectionUsesNullMetricsWithoutInventingLastKnownData() throws {
    let projection = OPLFleetAgentProvider.telemetry(
      usage: .empty(at: observedAt, status: .sessionsDirectoryMissing),
      identity: try identity(),
      now: observedAt
    )

    XCTAssertEqual(projection.nativeCarrier.availability, "available")
    XCTAssertEqual(projection.nativeCarrier.status, "degraded")
    XCTAssertEqual(projection.freshness.state, "unavailable")
    XCTAssertNil(projection.freshness.lastObservedAt)
    XCTAssertFalse(projection.freshness.lastKnown)
    XCTAssertEqual(projection.payload.collectionStatus, "unavailable")
    XCTAssertNil(projection.payload.windows.oneMinute.tokenRatePerSecond)
    XCTAssertNil(projection.payload.windows.fiveMinutes.requestRatePerMinute)
    XCTAssertNil(projection.payload.activeConversationCount)
    XCTAssertTrue(projection.payload.hostCapabilityFlags.isEmpty)

    let encoded = try OPLFleetAgentProvider.encoder().encode(projection)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    XCTAssertTrue(object.keys.contains("node"))
    let payload = try XCTUnwrap(object["payload"] as? [String: Any])
    XCTAssertTrue(payload.keys.contains("host_cpu_percent"))
  }

  func testDoctorReportsBoundedChecksAndDeferredSurfaces() throws {
    let doctor = OPLFleetAgentProvider.doctor(
      usage: usage(at: observedAt),
      identity: try identity(),
      now: observedAt.addingTimeInterval(30)
    )

    XCTAssertEqual(doctor.payload.doctorState, "healthy")
    XCTAssertEqual(doctor.payload.capabilityCurrentness, "current")
    XCTAssertEqual(
      doctor.payload.checks.map(\.checkId),
      [
        "provider_executable",
        "usage_collection",
        "sample_freshness",
        "execution_constraints",
        "sanitized_execution_receipts",
      ])
    XCTAssertEqual(doctor.payload.checks[3].state, "unavailable")
    XCTAssertEqual(doctor.payload.checks[3].reasonCode, "not_projected")
    XCTAssertEqual(doctor.payload.checks[4].state, "unavailable")
    XCTAssertEqual(doctor.payload.checks[4].reasonCode, "deferred_no_source")
  }

  func testProjectionContainsNoSensitiveOrAuthorityKeys() throws {
    let projection = OPLFleetAgentProvider.telemetry(
      usage: usage(at: observedAt),
      identity: try identity(),
      now: observedAt.addingTimeInterval(30)
    )
    let data = try OPLFleetAgentProvider.encoder().encode(projection)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let keys = recursiveKeys(object)

    for forbidden in [
      "prompt", "response", "session", "path", "address", "credential", "secret", "raw_log",
    ] {
      XCTAssertFalse(
        keys.contains(where: { $0.contains(forbidden) }), "Found forbidden key: \(forbidden)")
    }
    for forbidden in ["admission", "dispatch", "completion_verdict"] {
      XCTAssertFalse(keys.contains(forbidden))
    }
  }

  func testSwiftProjectionMatchesSharedProviderFixture() throws {
    let projection = OPLFleetAgentProvider.telemetry(
      usage: usage(at: observedAt),
      identity: try identity(),
      cpuPercent: 42.5,
      network: HostNetworkTelemetry(
        downloadMbps: 123.5,
        uploadMbps: 12.25,
        sampledAt: observedAt
      ),
      now: observedAt.addingTimeInterval(30)
    )
    let actualData = try OPLFleetAgentProvider.encoder().encode(projection)
    let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: actualData) as? NSDictionary)
    let fixtureURL = repositoryRoot()
      .appendingPathComponent("plugins/opl-fleet-agent/tests/fixtures/provider-telemetry.json")
    let expected = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? NSDictionary)

    XCTAssertEqual(actual, expected)
  }

  func testLastKnownStoreExpiresAndRejectsInvalidOrSensitiveBytes() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("opl-fleet-last-known-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cacheURL = directory.appendingPathComponent("provider-last-known.json")
    let store = FleetAgentLastKnownStore(url: cacheURL)
    let projection = OPLFleetAgentProvider.telemetry(
      usage: usage(at: observedAt),
      identity: try identity(),
      now: observedAt.addingTimeInterval(30)
    )

    try store.save(projection)
    guard case .available(let sample) = store.load(now: observedAt.addingTimeInterval(60)) else {
      return XCTFail("Expected a valid sanitized last-known sample")
    }
    XCTAssertEqual(sample.payload.windows.oneMinute.tokenRatePerSecond, 10)
    let cacheObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any]
    )
    XCTAssertEqual(Set(cacheObject.keys), ["last_observed_at", "payload"])
    XCTAssertFalse(recursiveKeys(cacheObject).contains(where: { key in
      ["prompt", "response", "session", "path", "address", "credential", "secret"]
        .contains(where: key.contains)
    }))

    XCTAssertEqual(
      store.load(now: observedAt.addingTimeInterval(FleetAgentLastKnownStore.ttlSeconds + 1)),
      .expired
    )
    try Data("{}".utf8).write(to: cacheURL)
    XCTAssertEqual(store.load(now: observedAt), .invalid)
    try Data(#"{"last_observed_at":"2025-08-16T08:00:00.000Z","prompt":"secret"}"#.utf8)
      .write(to: cacheURL)
    XCTAssertEqual(store.load(now: observedAt), .privacyRejected)
  }

  func testProviderCLIReusesSanitizedLastKnownAcrossIndependentProcesses() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("opl-fleet-provider-process-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sessions = directory.appendingPathComponent("codex/sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let now = Date()
    let timestamp = now.addingTimeInterval(-5).formatted(.iso8601)
    let log = [
      #"{"timestamp":"\#(timestamp)","type":"session_meta","payload":{"id":"session-a","model_provider":"test-provider"}}"#,
      #"{"timestamp":"\#(timestamp)","type":"turn_context","payload":{"model":"gpt-test"}}"#,
      #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120}}}}"#,
    ].joined(separator: "\n") + "\n"
    let logURL = sessions.appendingPathComponent("rollout-session-a.jsonl")
    try Data(log.utf8).write(to: logURL)
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: logURL.path)

    let executable = repositoryRoot().appendingPathComponent(".build/debug/OPLFleetAgentProvider")
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
    let cacheURL = directory.appendingPathComponent("provider-last-known.json")
    let environment = [
      "OPL_FLEET_AGENT_PROVIDER_CACHE": cacheURL.path,
      "CODEX_TPS_MACHINE_ID": "process-fixture",
      "CODEX_TPS_MACHINE_NAME": "Process Fixture",
      "CODEX_TPS_PLATFORM": "macOS",
    ]
    let first = try runProvider(
      executable: executable,
      codexHome: directory.appendingPathComponent("codex"),
      environment: environment
    )
    let second = try runProvider(
      executable: executable,
      codexHome: directory.appendingPathComponent("missing-codex-home"),
      environment: environment
    )

    let firstFreshness = try XCTUnwrap(first["freshness"] as? [String: Any])
    let secondFreshness = try XCTUnwrap(second["freshness"] as? [String: Any])
    XCTAssertEqual(firstFreshness["state"] as? String, "fresh")
    XCTAssertEqual(firstFreshness["last_known"] as? Bool, false)
    XCTAssertEqual(secondFreshness["state"] as? String, "stale")
    XCTAssertEqual(secondFreshness["last_known"] as? Bool, true)
    XCTAssertEqual(
      secondFreshness["last_observed_at"] as? String,
      firstFreshness["last_observed_at"] as? String
    )
    let firstPayload = try XCTUnwrap(first["payload"] as? [String: Any])
    let secondPayload = try XCTUnwrap(second["payload"] as? [String: Any])
    XCTAssertEqual(
      rate(firstPayload, window: "one_minute", field: "token_rate_per_second"),
      rate(secondPayload, window: "one_minute", field: "token_rate_per_second")
    )
  }

  func testDoctorCLIRefreshesLastKnownBeforeIndependentProcessFailure() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("opl-fleet-provider-doctor-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let codexHome = directory.appendingPathComponent("codex", isDirectory: true)
    let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let now = Date()
    let timestamp = now.addingTimeInterval(-5).formatted(.iso8601)
    let log = [
      #"{"timestamp":"\#(timestamp)","type":"session_meta","payload":{"id":"session-doctor","model_provider":"test-provider"}}"#,
      #"{"timestamp":"\#(timestamp)","type":"turn_context","payload":{"model":"gpt-test"}}"#,
      #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":200,"output_tokens":40,"total_tokens":240},"last_token_usage":{"input_tokens":200,"output_tokens":40,"total_tokens":240}}}}"#,
    ].joined(separator: "\n") + "\n"
    let logURL = sessions.appendingPathComponent("rollout-session-doctor.jsonl")
    try Data(log.utf8).write(to: logURL)
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: logURL.path)

    let executable = repositoryRoot().appendingPathComponent(".build/debug/OPLFleetAgentProvider")
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
    let cacheURL = directory.appendingPathComponent("provider-last-known.json")
    let environment = [
      "OPL_FLEET_AGENT_PROVIDER_CACHE": cacheURL.path,
      "CODEX_TPS_MACHINE_ID": "doctor-process-fixture",
      "CODEX_TPS_MACHINE_NAME": "Doctor Process Fixture",
      "CODEX_TPS_PLATFORM": "macOS",
    ]

    _ = try runProvider(
      executable: executable,
      ref: OPLFleetAgentProvider.doctorRef,
      codexHome: codexHome,
      environment: environment
    )
    try rebaseCache(cacheURL, to: Date().addingTimeInterval(-14 * 60))

    _ = try runProvider(
      executable: executable,
      ref: OPLFleetAgentProvider.doctorRef,
      codexHome: codexHome,
      environment: environment
    )
    let refreshedAt = try cacheObservedAt(cacheURL)
    XCTAssertLessThan(abs(refreshedAt.timeIntervalSinceNow), 5)

    // Advancing the simulated clock by two minutes makes an unrefreshed t0 sample expire.
    let failureObservedAt = refreshedAt.addingTimeInterval(-2 * 60)
    try rebaseCache(cacheURL, to: failureObservedAt)
    let failure = try runProvider(
      executable: executable,
      ref: OPLFleetAgentProvider.telemetryRef,
      codexHome: directory.appendingPathComponent("missing-codex-home"),
      environment: environment
    )

    let freshness = try XCTUnwrap(failure["freshness"] as? [String: Any])
    XCTAssertEqual(freshness["state"] as? String, "stale")
    XCTAssertEqual(freshness["last_known"] as? Bool, true)
    XCTAssertEqual(
      freshness["last_observed_at"] as? String,
      failureObservedAt.formatted(
        Date.ISO8601FormatStyle(includingFractionalSeconds: true)
      )
    )
    let payload = try XCTUnwrap(failure["payload"] as? [String: Any])
    XCTAssertEqual(rate(payload, window: "one_minute", field: "token_rate_per_second"), 4)
  }

  private func identity() throws -> AmbientOpsMachineIdentity {
    try AmbientOpsMachineIdentity(
      machineID: "fixture-node",
      machineName: "Fixture Node",
      platform: "macOS"
    )
  }

  private func usage(at date: Date) -> UsageSnapshot {
    UsageSnapshot(
      generatedAt: date,
      oneMinute: WindowMetrics(
        windowSeconds: 60,
        requestCount: 2,
        requestsPerMinute: 2,
        tokensPerSecond: 10,
        inputTokensPerSecond: 8,
        cachedInputTokensPerSecond: 5,
        outputTokensPerSecond: 2,
        reasoningTokensPerSecond: 1,
        cacheRatio: 0.625,
        totalTokens: 600
      ),
      fiveMinutes: WindowMetrics(
        windowSeconds: 300,
        requestCount: 5,
        requestsPerMinute: 1,
        tokensPerSecond: 4,
        inputTokensPerSecond: 3,
        cachedInputTokensPerSecond: 2,
        outputTokensPerSecond: 1,
        reasoningTokensPerSecond: 0.5,
        cacheRatio: 0.5,
        totalTokens: 1_200
      ),
      thirtyMinutes: .empty(windowSeconds: 1_800),
      oneHour: .empty(windowSeconds: 3_600),
      activeSessions: 3,
      malformedRelevantLines: 0,
      status: .ready
    )
  }

  private func recursiveKeys(_ value: Any) -> [String] {
    if let dictionary = value as? [String: Any] {
      return dictionary.flatMap { key, child in
        [key.lowercased()] + recursiveKeys(child)
      }
    }
    if let array = value as? [Any] {
      return array.flatMap(recursiveKeys)
    }
    return []
  }

  private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func runProvider(
    executable: URL,
    ref: String = OPLFleetAgentProvider.telemetryRef,
    codexHome: URL,
    environment: [String: String]
  ) throws -> [String: Any] {
    let process = Process()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = executable
    process.arguments = ["--ref", ref]
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
    process.environment?["CODEX_HOME"] = codexHome.path
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    process.waitUntilExit()
    let outputData = output.fileHandleForReading.readDataToEndOfFile()
    let errorData = errors.fileHandleForReading.readDataToEndOfFile()
    XCTAssertEqual(
      process.terminationStatus,
      0,
      String(data: errorData, encoding: .utf8) ?? "provider failed"
    )
    return try XCTUnwrap(
      JSONSerialization.jsonObject(with: outputData) as? [String: Any]
    )
  }

  private func cacheObservedAt(_ cacheURL: URL) throws -> Date {
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any]
    )
    let value = try XCTUnwrap(object["last_observed_at"] as? String)
    return try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value)
  }

  private func rebaseCache(_ cacheURL: URL, to observedAt: Date) throws {
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any]
    )
    object["last_observed_at"] = observedAt.formatted(
      Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    )
    try JSONSerialization.data(withJSONObject: object).write(to: cacheURL, options: .atomic)
  }

  private func rate(
    _ payload: [String: Any],
    window: String,
    field: String
  ) -> Double? {
    let windows = payload["windows"] as? [String: Any]
    let value = windows?[window] as? [String: Any]
    return value?[field] as? Double
  }
}
