import Foundation
import XCTest

@testable import OPLFleetAgentCore

final class AntigravitySessionScannerTests: XCTestCase {
  func testDiscoversHiddenTranscriptFilesAndIgnoresTranscriptFull() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let now = Date()
    let appBrain = root.appendingPathComponent("app/brain", isDirectory: true)
    let cliBrain = root.appendingPathComponent("cli/brain", isDirectory: true)
    let convLogs = appBrain.appendingPathComponent(
      "conv-a/.system_generated/logs", isDirectory: true)
    let cliLogs = cliBrain.appendingPathComponent(
      "conv-cli/.system_generated/logs", isDirectory: true)
    try FileManager.default.createDirectory(at: convLogs, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: cliLogs, withIntermediateDirectories: true)

    let ts = now.addingTimeInterval(-10).formatted(.iso8601)
    let appLine =
      #"{"step_index":2,"type":"PLANNER_RESPONSE","status":"DONE","created_at":"\#(ts)","model":"gemini-4-neon-xhigh","input_tokens":100,"cache_read_tokens":400,"output_tokens":100}"#
      + "\n"
    let cliLine =
      #"{"step_index":2,"type":"PLANNER_RESPONSE","status":"DONE","created_at":"\#(ts)","model":"gemini-4-neon-xhigh","input_tokens":200,"cache_read_tokens":0,"output_tokens":100}"#
      + "\n"
    // transcript_full.jsonl should never be double-counted alongside transcript.jsonl.
    let appTranscript = convLogs.appendingPathComponent("transcript.jsonl")
    let appFullTranscript = convLogs.appendingPathComponent("transcript_full.jsonl")
    let cliTranscript = cliLogs.appendingPathComponent("transcript.jsonl")
    try Data(appLine.utf8).write(to: appTranscript)
    try Data(appLine.utf8).write(to: appFullTranscript)
    try Data(cliLine.utf8).write(to: cliTranscript)
    try FileManager.default.setAttributes(
      [.modificationDate: now], ofItemAtPath: appTranscript.path)
    try FileManager.default.setAttributes(
      [.modificationDate: now], ofItemAtPath: cliTranscript.path)

    let scanner = AntigravitySessionScanner(brainRoots: [appBrain, cliBrain])
    let snapshot = await scanner.refresh(now: now)

    XCTAssertEqual(snapshot.status, .ready)
    XCTAssertEqual(snapshot.oneMinute.requestCount, 2)
    XCTAssertEqual(snapshot.oneMinute.totalTokens, 900)
    XCTAssertEqual(snapshot.oneMinute.cacheRatio, 400.0 / 700.0, accuracy: 0.001)
    XCTAssertEqual(snapshot.activeSessions, 2)
  }

  func testMissingAndPartialBrainRootsReportExpectedCollectionStatus() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let missingRoot = root.appendingPathComponent("missing/brain", isDirectory: true)
    let missingScanner = AntigravitySessionScanner(brainRoots: [missingRoot])
    let missingSnapshot = await missingScanner.refresh(now: Date())
    XCTAssertEqual(missingSnapshot.status, .sessionsDirectoryMissing)

    let existingRoot = root.appendingPathComponent("existing/brain", isDirectory: true)
    try FileManager.default.createDirectory(at: existingRoot, withIntermediateDirectories: true)
    let partialScanner = AntigravitySessionScanner(brainRoots: [existingRoot, missingRoot])
    let partialSnapshot = await partialScanner.refresh(now: Date())
    XCTAssertEqual(partialSnapshot.status, .ready)
    XCTAssertEqual(partialSnapshot.oneMinute.totalTokens, 0)
  }

  func testIncrementalAppendTruncationAndReplacementDoNotDuplicateSteps() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let now = Date()
    let brain = root.appendingPathComponent("brain", isDirectory: true)
    let logs = brain.appendingPathComponent("conv-append/.system_generated/logs", isDirectory: true)
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)

    let transcript = logs.appendingPathComponent("transcript.jsonl")
    let t1 = now.addingTimeInterval(-20).formatted(.iso8601)
    let t2 = now.addingTimeInterval(-10).formatted(.iso8601)
    let t3 = now.addingTimeInterval(-5).formatted(.iso8601)
    let step1 =
      #"{"step_index":2,"type":"PLANNER_RESPONSE","status":"DONE","created_at":"\#(t1)","model":"gemini-4-neon-xhigh","input_tokens":100,"cache_read_tokens":0,"output_tokens":20}"#
      + "\n"
    let step2 =
      #"{"step_index":4,"type":"PLANNER_RESPONSE","status":"DONE","created_at":"\#(t2)","model":"gemini-4-neon-xhigh","input_tokens":50,"cache_read_tokens":120,"output_tokens":30}"#
      + "\n"
    let step3 =
      #"{"step_index":6,"type":"CHECKPOINT","status":"DONE","created_at":"\#(t3)","input_tokens":200,"cache_read_tokens":0,"output_tokens":50}"#
      + "\n"

    try Data(step1.utf8).write(to: transcript)
    let scanner = AntigravitySessionScanner(brainRoots: [brain])
    let first = await scanner.refresh(now: now)
    XCTAssertEqual(first.oneMinute.totalTokens, 120)

    let handle = try FileHandle(forWritingTo: transcript)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(step2.utf8))
    try handle.close()

    let second = await scanner.refresh(now: now)
    XCTAssertEqual(second.oneMinute.totalTokens, 320)
    XCTAssertEqual(second.oneMinute.requestCount, 2)

    // Atomic file replacement (new inode, same size or expanded) must not double-count step1/step2.
    let replacement = logs.appendingPathComponent("transcript.tmp")
    try Data((step1 + step2 + step3).utf8).write(to: replacement)
    _ = try FileManager.default.replaceItemAt(transcript, withItemAt: replacement)

    let third = await scanner.refresh(now: now)
    XCTAssertEqual(third.oneMinute.totalTokens, 570)
    XCTAssertEqual(third.oneMinute.requestCount, 3)

    // Truncation and rewrite of step1 alone keeps all deduplicated prior events in the window.
    try Data(step1.utf8).write(to: transcript, options: .atomic)
    let fourth = await scanner.refresh(now: now)
    XCTAssertEqual(fourth.oneMinute.totalTokens, 570)
    XCTAssertEqual(fourth.oneMinute.requestCount, 3)
  }

  func testDeduplicatesIdenticalForkStepsWhileKeepingDistinctSubagents() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let now = Date()
    let brain = root.appendingPathComponent("brain", isDirectory: true)
    let ts = now.addingTimeInterval(-8).formatted(.iso8601)
    let parentLogs = brain.appendingPathComponent(
      "parent/.system_generated/logs", isDirectory: true)
    let childLogs = brain.appendingPathComponent("child/.system_generated/logs", isDirectory: true)
    let subagentLogs = brain.appendingPathComponent(
      "subagent/.system_generated/logs", isDirectory: true)
    try FileManager.default.createDirectory(at: parentLogs, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: childLogs, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: subagentLogs, withIntermediateDirectories: true)

    let sharedLine =
      #"{"step_index":2,"type":"PLANNER_RESPONSE","status":"DONE","created_at":"\#(ts)","model":"gemini-4-neon-xhigh","input_tokens":100,"cache_read_tokens":200,"output_tokens":50}"#
      + "\n"
    let distinctSubagentLine =
      #"{"step_index":2,"type":"PLANNER_RESPONSE","status":"DONE","created_at":"\#(ts)","model":"gemini-4-neon-xhigh","input_tokens":105,"cache_read_tokens":0,"output_tokens":45}"#
      + "\n"
    try Data(sharedLine.utf8).write(to: parentLogs.appendingPathComponent("transcript.jsonl"))
    try Data(sharedLine.utf8).write(to: childLogs.appendingPathComponent("transcript.jsonl"))
    try Data(distinctSubagentLine.utf8).write(
      to: subagentLogs.appendingPathComponent("transcript.jsonl"))

    let snapshot = await AntigravitySessionScanner(brainRoots: [brain]).refresh(now: now)
    XCTAssertEqual(snapshot.oneMinute.requestCount, 2)
    XCTAssertEqual(snapshot.oneMinute.totalTokens, 500)
  }

  func testLongRunningStepUsesCompletionTimeForOneMinuteWindowWithoutDoubleCounting() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let now = Date()
    let brain = root.appendingPathComponent("brain", isDirectory: true)
    let logs = brain.appendingPathComponent("conv-slow/.system_generated/logs", isDirectory: true)
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)

    let plannerStart = now.addingTimeInterval(-95).formatted(.iso8601)
    let plannerDone = now.addingTimeInterval(-8).formatted(.iso8601)
    let idlePlannerStart = now.addingTimeInterval(-120).formatted(.iso8601)
    let userReturn = now.addingTimeInterval(-4).formatted(.iso8601)

    let plannerLine =
      #"{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"\#(plannerStart)","model":"gemini-4-neon-xhigh","input_tokens":100,"cache_read_tokens":400,"output_tokens":100}"#
      + "\n"
    let genericLine =
      #"{"step_index":3,"source":"MODEL","type":"GENERIC","status":"DONE","created_at":"\#(plannerDone)"}"#
      + "\n"
    let idlePlannerLine =
      #"{"step_index":4,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"\#(idlePlannerStart)","model":"gemini-4-neon-xhigh","input_tokens":50,"cache_read_tokens":150,"output_tokens":40}"#
      + "\n"
    let userLine =
      #"{"step_index":5,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"\#(userReturn)"}"#
      + "\n"

    // Sub-case A: slow step completed before GENERIC lands in 1m; slow step before USER_INPUT stays in 5m only.
    let transcriptA = logs.appendingPathComponent("transcript.jsonl")
    try Data((plannerLine + genericLine + idlePlannerLine + userLine).utf8).write(to: transcriptA)
    try FileManager.default.setAttributes(
      [.modificationDate: now.addingTimeInterval(-4)],
      ofItemAtPath: transcriptA.path
    )

    // Sub-case B: slow EOF reply flushed 5s ago lands in 1m, and later replacement with GENERIC does not double-count.
    let eofLogs = brain.appendingPathComponent("conv-eof/.system_generated/logs", isDirectory: true)
    try FileManager.default.createDirectory(at: eofLogs, withIntermediateDirectories: true)
    let eofTranscript = eofLogs.appendingPathComponent("transcript.jsonl")
    let eofStart = now.addingTimeInterval(-85).formatted(.iso8601)
    let eofReply =
      #"{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"\#(eofStart)","model":"gemini-4-neon-xhigh","input_tokens":120,"cache_read_tokens":180,"output_tokens":60}"#
      + "\n"
    try Data(eofReply.utf8).write(to: eofTranscript)
    let eofMtime = now.addingTimeInterval(-5)
    try FileManager.default.setAttributes(
      [.modificationDate: eofMtime], ofItemAtPath: eofTranscript.path)

    let scanner = AntigravitySessionScanner(brainRoots: [brain])
    let first = await scanner.refresh(now: now)
    // 1m: conv-slow step 2 (600) + conv-eof step 2 (360) = 960; 5m adds conv-slow step 4 (240) = 1200.
    XCTAssertEqual(first.oneMinute.requestCount, 2)
    XCTAssertEqual(first.oneMinute.totalTokens, 960)
    XCTAssertEqual(first.fiveMinutes.requestCount, 3)
    XCTAssertEqual(first.fiveMinutes.totalTokens, 1_200)

    // Replace conv-eof transcript with a trailing GENERIC step; deduplication keeps exact totals.
    let trailingGeneric =
      #"{"step_index":3,"source":"MODEL","type":"GENERIC","status":"DONE","created_at":"\#(eofMtime.formatted(.iso8601))"}"#
      + "\n"
    let replacement = eofLogs.appendingPathComponent("transcript.tmp")
    try Data((eofReply + trailingGeneric).utf8).write(to: replacement)
    _ = try FileManager.default.replaceItemAt(eofTranscript, withItemAt: replacement)

    let second = await scanner.refresh(now: now)
    XCTAssertEqual(second.oneMinute.requestCount, 2)
    XCTAssertEqual(second.oneMinute.totalTokens, 960)
    XCTAssertEqual(second.fiveMinutes.requestCount, 3)
    XCTAssertEqual(second.fiveMinutes.totalTokens, 1_200)
  }

  private func makeTemporaryRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("opl-fleet-agy-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
