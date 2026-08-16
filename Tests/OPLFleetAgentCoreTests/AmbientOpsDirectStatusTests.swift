import Foundation
import Testing

@testable import OPLFleetAgentCore

struct AmbientOpsDirectStatusTests {
  @Test
  func directStatusMatchesTheSingleMachineProviderContract() throws {
    let generatedAt = Date(timeIntervalSince1970: 1_000)
    let now = Date(timeIntervalSince1970: 1_005)
    let identity = try AmbientOpsMachineIdentity(
      machineID: "studio",
      machineName: "Studio",
      platform: "macOS"
    )
    let usage = UsageSnapshot(
      generatedAt: generatedAt,
      oneMinute: WindowMetrics(
        windowSeconds: 60,
        requestCount: 10,
        requestsPerMinute: 10,
        tokensPerSecond: 60_000,
        inputTokensPerSecond: 1_000,
        cachedInputTokensPerSecond: 800,
        outputTokensPerSecond: 200,
        reasoningTokensPerSecond: 40,
        cacheRatio: 0.8,
        totalTokens: 3_600_000
      ),
      fiveMinutes: .empty(windowSeconds: 300),
      thirtyMinutes: .empty(windowSeconds: 1_800),
      oneHour: .empty(windowSeconds: 3_600),
      activeSessions: 10,
      malformedRelevantLines: 0,
      status: .ready
    )
    let snapshot = AmbientOpsAgentSnapshot(
      usage: usage,
      identity: identity,
      cpuPercent: 97
    )
    let status = AmbientOpsDirectStatusBuilder.build(
      observation: AmbientOpsMachineObservation(
        identity: identity,
        snapshot: snapshot,
        petAsset: nil
      ),
      serverVersion: "1.2.3",
      now: now
    )

    #expect(status.provider.kind == "opl-fleet-agent")
    #expect(status.productName == OPLFleetAgentProtocol.productName)
    #expect(status.provider.scope == "machine")
    #expect(status.capabilities.network == true)
    #expect(status.network.status == "unavailable")
    #expect(status.overallStatus == "live")
    #expect(status.machines.count == 1)
    #expect(status.machines[0].loadVisualState.modelVersion == 1)
    #expect(status.machines[0].loadVisualState.state == "constrained")
    #expect(status.machines[0].cachePercent == 80)
  }

  @Test
  func directStatusIncludesCurrentHostNetworkThroughput() throws {
    let now = Date(timeIntervalSince1970: 1_005)
    let identity = try AmbientOpsMachineIdentity(
      machineID: "studio",
      machineName: "Studio",
      platform: "macOS"
    )
    let usage = UsageSnapshot.empty(at: now, status: .ready)
    let status = AmbientOpsDirectStatusBuilder.build(
      observation: .init(
        identity: identity,
        snapshot: AmbientOpsAgentSnapshot(usage: usage, identity: identity),
        petAsset: nil
      ),
      serverVersion: "1.2.3",
      networkTelemetry: HostNetworkTelemetry(
        downloadMbps: 123.4,
        uploadMbps: 12.3,
        sampledAt: now.addingTimeInterval(-1)
      ),
      now: now
    )

    #expect(status.network.status == "live")
    #expect(status.network.source == "host")
    #expect(status.network.downloadMbps == 123.4)
    #expect(status.network.uploadMbps == 12.3)
    #expect(status.network.ageSeconds == 1)
  }

  @Test
  func unknownCPUStaysUnknownAndDoesNotCreatePressure() throws {
    let identity = try AmbientOpsMachineIdentity(
      machineID: "studio",
      machineName: "Studio",
      platform: "macOS"
    )
    let usage = UsageSnapshot(
      generatedAt: Date(timeIntervalSince1970: 1_000),
      oneMinute: WindowMetrics(
        windowSeconds: 60,
        requestCount: 10,
        requestsPerMinute: 10,
        tokensPerSecond: 60_000,
        inputTokensPerSecond: 0,
        cachedInputTokensPerSecond: 0,
        outputTokensPerSecond: 0,
        reasoningTokensPerSecond: 0,
        cacheRatio: 0,
        totalTokens: 3_600_000
      ),
      fiveMinutes: .empty(windowSeconds: 300),
      thirtyMinutes: .empty(windowSeconds: 1_800),
      oneHour: .empty(windowSeconds: 3_600),
      activeSessions: 10,
      malformedRelevantLines: 0,
      status: .ready
    )
    let snapshot = AmbientOpsAgentSnapshot(usage: usage, identity: identity)
    let status = AmbientOpsDirectStatusBuilder.build(
      observation: .init(identity: identity, snapshot: snapshot, petAsset: nil),
      serverVersion: "1.2.3",
      now: usage.generatedAt
    )

    #expect(status.codex.cpuPercent == nil)
    #expect(status.codex.cpuReportedMachineCount == 0)
    #expect(status.machines[0].loadVisualState.state == "heavy")
    #expect(status.machines[0].loadVisualState.pressure == 0)
  }

  @Test
  func loadVisualModelV1MatchesTheCrossPlatformContractVectors() {
    let vectors: [(String, Double, Double, Double?, String, Double, Int)] = [
      ("quiet", 0, 0, nil, "quiet", 0, 0),
      ("active", 6_000, 4, 42, "active", 0.3428208823027626, 2),
      ("heavy", 60_000, 10, nil, "heavy", 0.9533333333333334, 3),
      ("constrained", 60_000, 10, 97, "constrained", 0.9567333333333334, 3),
    ]

    #expect(AmbientOpsLoadModel.modelVersion == 1)
    for vector in vectors {
      let visual = AmbientOpsLoadModel.visualState(
        tps: vector.1,
        activeSessions: vector.2,
        cpuPercent: vector.3
      )
      #expect(visual.modelVersion == 1)
      #expect(visual.state == vector.4)
      #expect(abs(visual.score - vector.5) < 1e-12)
      #expect(visual.clusterCount == vector.6)
    }
  }

  @Test
  func serializedDirectStatusContainsOnlyAggregateFields() throws {
    let identity = try AmbientOpsMachineIdentity(
      machineID: "studio",
      machineName: "Studio",
      platform: "macOS"
    )
    let usage = UsageSnapshot.empty(at: Date(timeIntervalSince1970: 1_000), status: .ready)
    let status = AmbientOpsDirectStatusBuilder.build(
      observation: .init(
        identity: identity,
        snapshot: AmbientOpsAgentSnapshot(usage: usage, identity: identity),
        petAsset: nil
      ),
      serverVersion: "1.2.3",
      now: usage.generatedAt
    )
    let json = String(
      decoding: try AmbientOpsDirectStatusBuilder.encoder().encode(status),
      as: UTF8.self
    )

    #expect(!json.localizedCaseInsensitiveContains("prompt"))
    #expect(!json.localizedCaseInsensitiveContains("response"))
    #expect(!json.localizedCaseInsensitiveContains("sessionId"))
    #expect(!json.localizedCaseInsensitiveContains("sessionsRoot"))
  }
}
