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
}
