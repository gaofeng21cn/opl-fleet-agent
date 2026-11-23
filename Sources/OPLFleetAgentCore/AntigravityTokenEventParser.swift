import Foundation

public enum AntigravityTokenEventParser {
  static let relevantMarkers = [
    Data("\"type\":\"PLANNER_RESPONSE\"".utf8),
    Data("\"type\": \"PLANNER_RESPONSE\"".utf8),
    Data("\"type\":\"CHECKPOINT\"".utf8),
    Data("\"type\": \"CHECKPOINT\"".utf8),
  ]

  private static let relevantTypes: Set<String> = [
    "PLANNER_RESPONSE",
    "CHECKPOINT",
  ]

  public static func parse(lines: [Data], conversationID: String) -> TokenParseBatch {
    var events: [UsageEvent] = []
    var malformed = 0
    let decoder = JSONDecoder()

    for line in lines where shouldInspect(line) {
      let entry: AntigravityTranscriptEntry
      do {
        entry = try decoder.decode(AntigravityTranscriptEntry.self, from: line)
      } catch {
        malformed += 1
        continue
      }

      guard let type = entry.type, relevantTypes.contains(type) else {
        continue
      }

      if let status = entry.status, status != "DONE" {
        continue
      }

      guard
        entry.inputTokens != nil || entry.cacheReadTokens != nil || entry.outputTokens != nil
      else {
        continue
      }

      let uncachedInput = max(entry.inputTokens ?? 0, 0)
      let cachedInput = max(entry.cacheReadTokens ?? 0, 0)
      let totalInput = uncachedInput + cachedInput
      let output = max(entry.outputTokens ?? 0, 0)
      let total = totalInput + output
      guard total > 0 else { continue }

      guard let timestamp = parseTimestamp(entry.createdAt) else {
        malformed += 1
        continue
      }

      let usage = TokenUsage(
        inputTokens: totalInput,
        cachedInputTokens: cachedInput,
        outputTokens: output,
        reasoningOutputTokens: 0,
        totalTokens: total
      )
      let key = deduplicationKey(
        type: type,
        stepIndex: entry.stepIndex,
        model: entry.model.nonEmpty ?? "unknown",
        timestamp: timestamp,
        usage: usage
      )
      events.append(
        UsageEvent(
          timestamp: timestamp,
          usage: usage,
          sessionID: conversationID,
          deduplicationKey: key
        )
      )
    }

    return TokenParseBatch(events: events, malformedRelevantLines: malformed)
  }

  static func shouldInspect(_ line: Data) -> Bool {
    relevantMarkers.contains { line.range(of: $0) != nil }
  }

  private static func parseTimestamp(_ value: String?) -> Date? {
    guard let trimmed = value.nonEmpty else { return nil }
    if let parsed = try? Date(trimmed, strategy: .iso8601) {
      return parsed
    }
    return try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(trimmed)
  }

  private static func deduplicationKey(
    type: String,
    stepIndex: Int?,
    model: String,
    timestamp: Date,
    usage: TokenUsage
  ) -> String {
    [
      "antigravity",
      "event",
      type,
      stepIndex.map(String.init) ?? "none",
      model,
      timestamp.formatted(.iso8601),
      String(usage.inputTokens),
      String(usage.cachedInputTokens),
      String(usage.outputTokens),
    ].joined(separator: ":")
  }
}

/// Decodes only structural metadata and token counters; conversation bodies stay unread.
private struct AntigravityTranscriptEntry: Decodable {
  let stepIndex: Int?
  let type: String?
  let status: String?
  let createdAt: String?
  let model: String?
  let inputTokens: Int64?
  let cacheReadTokens: Int64?
  let outputTokens: Int64?

  enum CodingKeys: String, CodingKey {
    case stepIndex = "step_index"
    case type
    case status
    case createdAt = "created_at"
    case model
    case inputTokens = "input_tokens"
    case cacheReadTokens = "cache_read_tokens"
    case outputTokens = "output_tokens"
  }
}
