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

  private func makeTemporaryRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("opl-fleet-agy-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
