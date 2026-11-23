import Foundation

struct AntigravityStepHint: Sendable, Equatable {
  let type: String?
  let source: String?
  let createdAt: String?
}

struct AntigravityTranscriptLineInput: Sendable {
  let line: Data
  let nextStep: AntigravityStepHint?
  let eofModifiedAt: Date?
}

public enum AntigravityTokenEventParser {
  static let maxTurnDurationSeconds: TimeInterval = 900

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
  private static let headerInspectionLimit = 512
  private static let typePrefixes = [
    Data("\"type\":\"".utf8),
    Data("\"type\": \"".utf8),
  ]
  private static let sourcePrefixes = [
    Data("\"source\":\"".utf8),
    Data("\"source\": \"".utf8),
  ]
  private static let createdAtPrefixes = [
    Data("\"created_at\":\"".utf8),
    Data("\"created_at\": \"".utf8),
  ]

  public static func parse(lines: [Data], conversationID: String) -> TokenParseBatch {
    let entries = lines.map {
      AntigravityTranscriptLineInput(line: $0, nextStep: nil, eofModifiedAt: nil)
    }
    return parse(entries: entries, conversationID: conversationID)
  }

  static func parse(
    entries: [AntigravityTranscriptLineInput],
    conversationID: String
  ) -> TokenParseBatch {
    var events: [UsageEvent] = []
    var malformed = 0
    let decoder = JSONDecoder()

    for input in entries where shouldInspect(input.line) {
      let entry: AntigravityTranscriptEntry
      do {
        entry = try decoder.decode(AntigravityTranscriptEntry.self, from: input.line)
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

      guard let startTimestamp = parseTimestamp(entry.createdAt) else {
        malformed += 1
        continue
      }

      let eventTimestamp = resolveCompletionTimestamp(
        start: startTimestamp,
        nextStep: input.nextStep,
        eofModifiedAt: input.eofModifiedAt
      )
      let usage = TokenUsage(
        inputTokens: totalInput,
        cachedInputTokens: cachedInput,
        outputTokens: output,
        reasoningOutputTokens: 0,
        totalTokens: total
      )
      // Key deduplication on the immutable start timestamp so EOF mtime -> successor transitions
      // never double-count the same completed step across atomic file rewrites.
      let key = deduplicationKey(
        type: type,
        stepIndex: entry.stepIndex,
        model: entry.model.nonEmpty ?? "unknown",
        startTimestamp: startTimestamp,
        usage: usage
      )
      events.append(
        UsageEvent(
          timestamp: eventTimestamp,
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

  static func extractStepHint(from line: Data) -> AntigravityStepHint? {
    let limit = min(line.count, headerInspectionLimit)
    let header = line.prefix(limit)
    let type = extractQuotedStringValue(forAnyPrefix: typePrefixes, in: header)
    let source = extractQuotedStringValue(forAnyPrefix: sourcePrefixes, in: header)
    let createdAt = extractQuotedStringValue(forAnyPrefix: createdAtPrefixes, in: header)
    guard type != nil || source != nil || createdAt != nil else { return nil }
    return AntigravityStepHint(type: type, source: source, createdAt: createdAt)
  }

  static func resolveCompletionTimestamp(
    start: Date,
    nextStep: AntigravityStepHint?,
    eofModifiedAt: Date?
  ) -> Date {
    if let nextStep {
      guard nextStep.source == "MODEL",
        nextStep.type != "USER_INPUT",
        nextStep.type != "SYSTEM_MESSAGE",
        nextStep.type != "ERROR_MESSAGE",
        let nextDate = parseTimestamp(nextStep.createdAt)
      else {
        return start
      }
      let duration = nextDate.timeIntervalSince(start)
      guard duration >= 0, duration <= maxTurnDurationSeconds else {
        return start
      }
      return nextDate
    }

    if let eofModifiedAt {
      let duration = eofModifiedAt.timeIntervalSince(start)
      guard duration >= 0, duration <= maxTurnDurationSeconds else {
        return start
      }
      return eofModifiedAt
    }

    return start
  }

  private static func extractQuotedStringValue(
    forAnyPrefix prefixes: [Data],
    in header: Data
  ) -> String? {
    for prefix in prefixes {
      guard let match = header.range(of: prefix) else { continue }
      var index = match.upperBound
      var escaped = false
      while index < header.endIndex {
        let byte = header[index]
        if escaped {
          escaped = false
        } else if byte == 0x5C {
          escaped = true
        } else if byte == 0x22 {
          let value = String(decoding: header[match.upperBound..<index], as: UTF8.self)
          return value.isEmpty ? nil : value
        }
        index = header.index(after: index)
      }
    }
    return nil
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
    startTimestamp: Date,
    usage: TokenUsage
  ) -> String {
    [
      "antigravity",
      "event",
      type,
      stepIndex.map(String.init) ?? "none",
      model,
      startTimestamp.formatted(.iso8601),
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
