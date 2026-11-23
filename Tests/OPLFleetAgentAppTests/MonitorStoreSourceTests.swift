import Foundation
import OPLFleetAgentCore
import XCTest

@testable import OPLFleetAgent

@MainActor
final class MonitorStoreSourceTests: XCTestCase {
  func testCombinesSourcesAndPersistsIndependentSourceToggles() async throws {
    let suiteName = "opl-fleet-agent-app-tests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("opl-fleet-store-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let now = Date()
    let codexHome = root.appendingPathComponent("codex", isDirectory: true)
    let agyBrain = root.appendingPathComponent("agy/brain", isDirectory: true)
    try writeCodexLog(in: codexHome, now: now, total: 600)
    try writeAntigravityLog(
      in: agyBrain, now: now, uncachedInput: 400, cacheRead: 1_000, output: 400)

    let store = MonitorStore(
      codexHome: codexHome,
      antigravityBrainRoots: [agyBrain],
      userDefaults: defaults,
      enableGatewayIntegration: false
    )

    XCTAssertTrue(store.codexEnabled)
    XCTAssertTrue(store.antigravityEnabled)

    await store.refresh(now: now)
    // Combined: 600 + 1800 = 2400 tokens / 60s = 40.0 t/s
    XCTAssertEqual(store.snapshot.oneMinute.totalTokens, 2_400)
    XCTAssertEqual(store.menuBarTitle, "40 t/s")
    XCTAssertEqual(store.breakdown(for: .codex)?.snapshot.oneMinute.totalTokens, 600)
    XCTAssertEqual(store.breakdown(for: .antigravity)?.snapshot.oneMinute.totalTokens, 1_800)

    store.setSourceEnabled(false, for: .codex)
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertFalse(store.codexEnabled)
    XCTAssertEqual(
      defaults.object(forKey: UsageSourceConfiguration.codexEnabledDefaultsKey) as? Bool,
      false
    )
    XCTAssertEqual(store.snapshot.oneMinute.totalTokens, 1_800)
    XCTAssertEqual(store.menuBarTitle, "30 t/s")

    store.setSourceEnabled(false, for: .antigravity)
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertFalse(store.antigravityEnabled)
    XCTAssertEqual(store.menuBarTitle, "-- t/s")

    let reloaded = MonitorStore(
      codexHome: codexHome,
      antigravityBrainRoots: [agyBrain],
      userDefaults: defaults,
      enableGatewayIntegration: false
    )
    XCTAssertFalse(reloaded.codexEnabled)
    XCTAssertFalse(reloaded.antigravityEnabled)
  }

  private func writeCodexLog(in codexHome: URL, now: Date, total: Int64) throws {
    let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let ts = now.addingTimeInterval(-5).formatted(.iso8601)
    let input = total - 100
    let output: Int64 = 100
    let content =
      [
        #"{"timestamp":"\#(ts)","type":"session_meta","payload":{"id":"codex-store","model_provider":"openai"}}"#,
        #"{"timestamp":"\#(ts)","type":"turn_context","payload":{"model":"gpt-5"}}"#,
        #"{"timestamp":"\#(ts)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"output_tokens":\#(output),"total_tokens":\#(total)},"last_token_usage":{"input_tokens":\#(input),"output_tokens":\#(output),"total_tokens":\#(total)}}}}"#,
      ].joined(separator: "\n") + "\n"
    let logURL = sessions.appendingPathComponent("rollout-store.jsonl")
    try Data(content.utf8).write(to: logURL)
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: logURL.path)
  }

  private func writeAntigravityLog(
    in brainRoot: URL,
    now: Date,
    uncachedInput: Int64,
    cacheRead: Int64,
    output: Int64
  ) throws {
    let logs = brainRoot.appendingPathComponent(
      "conv-store/.system_generated/logs", isDirectory: true)
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
