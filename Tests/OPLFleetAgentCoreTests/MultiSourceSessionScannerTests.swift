import Foundation
import XCTest

@testable import OPLFleetAgentCore

final class MultiSourceSessionScannerTests: XCTestCase {
  func testCombinesCodexAndAntigravityAndHonorsSourceToggles() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let now = Date()
    let codexHome = root.appendingPathComponent("codex", isDirectory: true)
    let agyBrain = root.appendingPathComponent("agy/brain", isDirectory: true)
    try writeCodexSample(in: codexHome, now: now, input: 100, cached: 50, output: 20, reasoning: 10)
    try writeAntigravitySample(
      in: agyBrain,
      conversationID: "conv-1",
      now: now,
      uncachedInput: 80,
      cacheRead: 200,
      output: 40
    )

    let scanner = MultiSourceSessionScanner(
      configuration: UsageSourceConfiguration(
        codexEnabled: true,
        antigravityEnabled: true,
        codexHome: codexHome,
        antigravityBrainRoots: [agyBrain]
      )
    )

    let both = await scanner.refresh(now: now)
    XCTAssertEqual(both.combined.status, .ready)
    XCTAssertEqual(both.combined.activeSessions, 2)
    XCTAssertEqual(both.combined.oneMinute.requestCount, 2)
    // Codex (100+20=120) + Antigravity (80+200+40=320) = 440
    XCTAssertEqual(both.combined.oneMinute.totalTokens, 440)
    XCTAssertEqual(
      both.combined.oneMinute.cacheRatio,
      250.0 / 380.0,
      accuracy: 0.001
    )
    XCTAssertEqual(both.breakdown(for: .codex)?.snapshot.oneMinute.totalTokens, 120)
    XCTAssertEqual(both.breakdown(for: .antigravity)?.snapshot.oneMinute.totalTokens, 320)

    await scanner.setEnabled(false, for: .codex)
    let agyOnly = await scanner.refresh(now: now)
    XCTAssertEqual(agyOnly.combined.status, .ready)
    XCTAssertEqual(agyOnly.combined.oneMinute.totalTokens, 320)
    XCTAssertEqual(agyOnly.combined.activeSessions, 1)
    XCTAssertEqual(agyOnly.breakdown(for: .codex)?.enabled, false)
    XCTAssertEqual(agyOnly.breakdown(for: .codex)?.snapshot.oneMinute.totalTokens, 0)

    await scanner.setEnabled(false, for: .antigravity)
    let none = await scanner.refresh(now: now)
    XCTAssertEqual(none.combined.status, .sessionsDirectoryMissing)
    XCTAssertEqual(none.combined.oneMinute.totalTokens, 0)
  }

  func testRemainsReadyWhenOnlyOneEnabledSourceExists() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let now = Date()
    let missingCodexHome = root.appendingPathComponent("missing-codex", isDirectory: true)
    let agyBrain = root.appendingPathComponent("agy/brain", isDirectory: true)
    try writeAntigravitySample(
      in: agyBrain,
      conversationID: "conv-only",
      now: now,
      uncachedInput: 100,
      cacheRead: 200,
      output: 60
    )

    let scanner = MultiSourceSessionScanner(
      configuration: UsageSourceConfiguration(
        codexEnabled: true,
        antigravityEnabled: true,
        codexHome: missingCodexHome,
        antigravityBrainRoots: [agyBrain]
      )
    )
    let result = await scanner.refresh(now: now)

    XCTAssertEqual(result.combined.status, .ready)
    XCTAssertEqual(result.combined.oneMinute.totalTokens, 360)
    XCTAssertEqual(result.breakdown(for: .codex)?.snapshot.status, .sessionsDirectoryMissing)
    XCTAssertEqual(result.breakdown(for: .antigravity)?.snapshot.status, .ready)
  }

  func testSourceConfigurationResolutionPreservesExplicitHomeIsolation() throws {
    let defaultConfig = UsageSourceConfiguration.resolve(
      environment: ["HOME": "/tmp/user-home"],
      savedCodexEnabled: nil,
      savedAntigravityEnabled: nil
    )
    XCTAssertTrue(defaultConfig.codexEnabled)
    XCTAssertTrue(defaultConfig.antigravityEnabled)
    XCTAssertEqual(
      defaultConfig.antigravityBrainRoots.map(\.path),
      [
        "/tmp/user-home/.gemini/antigravity/brain",
        "/tmp/user-home/.gemini/antigravity-cli/brain",
      ]
    )

    let savedDisabled = UsageSourceConfiguration.resolve(
      environment: ["HOME": "/tmp/user-home"],
      savedCodexEnabled: true,
      savedAntigravityEnabled: false
    )
    XCTAssertTrue(savedDisabled.codexEnabled)
    XCTAssertFalse(savedDisabled.antigravityEnabled)

    let codexOnly = UsageSourceConfiguration.resolve(
      environment: [
        "HOME": "/tmp/user-home",
        "CODEX_HOME": "/tmp/custom-codex",
      ],
      savedCodexEnabled: true,
      savedAntigravityEnabled: true
    )
    XCTAssertTrue(codexOnly.codexEnabled)
    XCTAssertFalse(codexOnly.antigravityEnabled)
    XCTAssertEqual(codexOnly.codexHome.path, "/tmp/custom-codex")

    let agyOnly = UsageSourceConfiguration.resolve(
      environment: [
        "HOME": "/tmp/user-home",
        "ANTIGRAVITY_HOME": "/tmp/custom-agy",
      ],
      savedCodexEnabled: true,
      savedAntigravityEnabled: true
    )
    XCTAssertFalse(agyOnly.codexEnabled)
    XCTAssertTrue(agyOnly.antigravityEnabled)
    XCTAssertEqual(agyOnly.antigravityBrainRoots.map(\.path), ["/tmp/custom-agy/brain"])

    let forcedAll = UsageSourceConfiguration.resolve(
      environment: [
        "HOME": "/tmp/user-home",
        "CODEX_HOME": "/tmp/custom-codex",
        "OPL_FLEET_AGENT_SOURCES": "all",
      ],
      savedCodexEnabled: false,
      savedAntigravityEnabled: false
    )
    XCTAssertTrue(forcedAll.codexEnabled)
    XCTAssertTrue(forcedAll.antigravityEnabled)
    XCTAssertEqual(
      forcedAll.antigravityBrainRoots.map(\.path),
      [
        "/tmp/user-home/.gemini/antigravity/brain",
        "/tmp/user-home/.gemini/antigravity-cli/brain",
      ]
    )
  }

  func testProviderObservationBindingMatchesLegacyCodexOnlyAndSeparatesMultiSource() throws {
    let identity = try AmbientOpsMachineIdentity(
      machineID: "test-node",
      machineName: "Test Node",
      platform: "macOS"
    )
    let codexHome = URL(fileURLWithPath: "/tmp/codex-home", isDirectory: true)
    let agyBrain = URL(fileURLWithPath: "/tmp/agy/brain", isDirectory: true)

    let legacyBinding = FleetAgentLastKnownStore.observationBinding(
      identity: identity,
      codexHome: codexHome
    )
    let codexOnlyConfig = UsageSourceConfiguration(
      codexEnabled: true,
      antigravityEnabled: false,
      codexHome: codexHome,
      antigravityBrainRoots: [agyBrain]
    )
    let bothConfig = UsageSourceConfiguration(
      codexEnabled: true,
      antigravityEnabled: true,
      codexHome: codexHome,
      antigravityBrainRoots: [agyBrain]
    )
    let agyOnlyConfig = UsageSourceConfiguration(
      codexEnabled: false,
      antigravityEnabled: true,
      codexHome: codexHome,
      antigravityBrainRoots: [agyBrain]
    )

    XCTAssertEqual(
      FleetAgentLastKnownStore.observationBinding(
        identity: identity, configuration: codexOnlyConfig),
      legacyBinding
    )
    XCTAssertNotEqual(
      FleetAgentLastKnownStore.observationBinding(identity: identity, configuration: bothConfig),
      legacyBinding
    )
    XCTAssertNotEqual(
      FleetAgentLastKnownStore.observationBinding(identity: identity, configuration: agyOnlyConfig),
      FleetAgentLastKnownStore.observationBinding(identity: identity, configuration: bothConfig)
    )
  }

  private func makeTemporaryRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("opl-fleet-multi-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func writeCodexSample(
    in codexHome: URL,
    now: Date,
    input: Int64,
    cached: Int64,
    output: Int64,
    reasoning: Int64
  ) throws {
    let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let ts = now.addingTimeInterval(-5).formatted(.iso8601)
    let total = input + output
    let log =
      [
        #"{"timestamp":"\#(ts)","type":"session_meta","payload":{"id":"codex-a","model_provider":"openai"}}"#,
        #"{"timestamp":"\#(ts)","type":"turn_context","payload":{"model":"gpt-5"}}"#,
        #"{"timestamp":"\#(ts)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output),"reasoning_output_tokens":\#(reasoning),"total_tokens":\#(total)},"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output),"reasoning_output_tokens":\#(reasoning),"total_tokens":\#(total)}}}}"#,
      ].joined(separator: "\n") + "\n"
    let logURL = sessions.appendingPathComponent("rollout-a.jsonl")
    try Data(log.utf8).write(to: logURL)
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: logURL.path)
  }

  private func writeAntigravitySample(
    in brainRoot: URL,
    conversationID: String,
    now: Date,
    uncachedInput: Int64,
    cacheRead: Int64,
    output: Int64
  ) throws {
    let logs = brainRoot.appendingPathComponent(
      "\(conversationID)/.system_generated/logs", isDirectory: true)
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let ts = now.addingTimeInterval(-5).formatted(.iso8601)
    let line =
      #"{"step_index":2,"type":"PLANNER_RESPONSE","status":"DONE","created_at":"\#(ts)","model":"gemini-4-neon-xhigh","input_tokens":\#(uncachedInput),"cache_read_tokens":\#(cacheRead),"output_tokens":\#(output)}"#
      + "\n"
    let transcript = logs.appendingPathComponent("transcript.jsonl")
    try Data(line.utf8).write(to: transcript)
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: transcript.path)
  }
}
