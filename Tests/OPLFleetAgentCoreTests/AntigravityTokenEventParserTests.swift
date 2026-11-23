import Foundation
import XCTest

@testable import OPLFleetAgentCore

final class AntigravityTokenEventParserTests: XCTestCase {
  func testNormalizesUncachedInputAndCacheReadTokensIntoTotalInput() throws {
    let lines = fixtureLines(
      #"{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-23T08:14:09Z","model":"gemini-4-neon-xhigh","input_tokens":1000,"cache_read_tokens":4000,"output_tokens":500,"content":"ignored","thinking":"ignored","tool_calls":[]}"#
    )

    let batch = AntigravityTokenEventParser.parse(lines: lines, conversationID: "conv-1")

    XCTAssertEqual(batch.malformedRelevantLines, 0)
    XCTAssertEqual(batch.events.count, 1)
    let event = try XCTUnwrap(batch.events.first)
    XCTAssertEqual(event.sessionID, "conv-1")
    XCTAssertEqual(event.usage.inputTokens, 5_000)
    XCTAssertEqual(event.usage.cachedInputTokens, 4_000)
    XCTAssertEqual(event.usage.outputTokens, 500)
    XCTAssertEqual(event.usage.reasoningOutputTokens, 0)
    XCTAssertEqual(event.usage.totalTokens, 5_500)
    XCTAssertEqual(
      Double(event.usage.cachedInputTokens) / Double(event.usage.inputTokens), 0.8, accuracy: 0.001)
  }

  func testCountsCheckpointEventsAlongsidePlannerResponses() throws {
    let lines = fixtureLines(
      #"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-23T08:10:00Z","model":"gemini-4-neon-xhigh","input_tokens":200,"cache_read_tokens":800,"output_tokens":100}"#,
      #"{"step_index":2,"source":"SYSTEM","type":"CHECKPOINT","status":"DONE","created_at":"2026-11-23T08:10:30Z","input_tokens":1000,"cache_read_tokens":0,"output_tokens":250}"#
    )

    let batch = AntigravityTokenEventParser.parse(lines: lines, conversationID: "conv-cp")

    XCTAssertEqual(batch.malformedRelevantLines, 0)
    XCTAssertEqual(batch.events.map(\.usage.totalTokens), [1_100, 1_250])
  }

  func testIgnoresNonTokenLinesAndNonDoneEventsWithoutCountingMalformed() throws {
    let lines = fixtureLines(
      #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-11-23T08:10:00Z","content":"mention \"type\":\"PLANNER_RESPONSE\" and \"input_tokens\":123"}"#,
      #"{"step_index":1,"source":"MODEL","type":"GENERIC","status":"DONE","created_at":"2026-11-23T08:10:01Z","content":"literal \"type\":\"CHECKPOINT\""}"#,
      #"{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","status":"RUNNING","created_at":"2026-11-23T08:10:02Z","input_tokens":100,"output_tokens":20}"#,
      #"{"step_index":3,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-23T08:10:03Z","content":"legacy step without token fields"}"#
    )

    let batch = AntigravityTokenEventParser.parse(lines: lines, conversationID: "conv-ignore")

    XCTAssertEqual(batch.malformedRelevantLines, 0)
    XCTAssertTrue(batch.events.isEmpty)
  }

  func testCountsMalformedRelevantLinesAndSupportsFractionalTimestamps() throws {
    let lines = fixtureLines(
      #"{"step_index":1,"type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-23T08:10:00.250Z","input_tokens":100,"output_tokens":50}"#,
      #"{"step_index":2,"type":"PLANNER_RESPONSE","status":"DONE","created_at":"not-a-timestamp","input_tokens":100,"output_tokens":50}"#,
      #"{"type":"PLANNER_RESPONSE","broken":"#
    )

    let batch = AntigravityTokenEventParser.parse(lines: lines, conversationID: "conv-bad")

    XCTAssertEqual(batch.events.count, 1)
    XCTAssertEqual(batch.events.first?.usage.totalTokens, 150)
    XCTAssertEqual(batch.malformedRelevantLines, 2)
  }

  private func fixtureLines(_ raw: String...) -> [Data] {
    raw.map { Data($0.utf8) }
  }
}
