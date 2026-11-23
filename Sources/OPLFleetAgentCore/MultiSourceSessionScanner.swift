import Foundation

public actor MultiSourceSessionScanner {
  private let codexScanner: SessionScanner
  private let antigravityScanner: AntigravitySessionScanner
  private var codexEnabled: Bool
  private var antigravityEnabled: Bool

  public init(
    configuration: UsageSourceConfiguration = UsageSourceConfiguration(),
    calendar: Calendar = .current,
    activeFileHorizon: TimeInterval = 65 * 60
  ) {
    codexEnabled = configuration.codexEnabled
    antigravityEnabled = configuration.antigravityEnabled
    codexScanner = SessionScanner(
      codexHome: configuration.codexHome,
      calendar: calendar,
      activeFileHorizon: activeFileHorizon
    )
    antigravityScanner = AntigravitySessionScanner(
      brainRoots: configuration.antigravityBrainRoots,
      activeFileHorizon: activeFileHorizon
    )
  }

  public func setEnabled(_ enabled: Bool, for source: UsageSourceKind) {
    switch source {
    case .codex:
      codexEnabled = enabled
    case .antigravity:
      antigravityEnabled = enabled
    }
  }

  public func isEnabled(_ source: UsageSourceKind) -> Bool {
    switch source {
    case .codex:
      codexEnabled
    case .antigravity:
      antigravityEnabled
    }
  }

  public func refresh(now: Date = Date()) async -> MultiSourceUsageSnapshot {
    let codexTask: Task<SourceScanResult?, Never>? =
      codexEnabled
      ? Task { await codexScanner.refreshResult(now: now) }
      : nil
    let antigravityTask: Task<SourceScanResult?, Never>? =
      antigravityEnabled
      ? Task { await antigravityScanner.refreshResult(now: now) }
      : nil

    let codexResult = await codexTask?.value
    let antigravityResult = await antigravityTask?.value

    var enabledResults: [SourceScanResult] = []
    var breakdowns: [UsageSourceBreakdown] = []

    if let codexResult {
      enabledResults.append(codexResult)
      breakdowns.append(
        UsageSourceBreakdown(source: .codex, enabled: true, snapshot: codexResult.snapshot)
      )
    } else {
      breakdowns.append(
        UsageSourceBreakdown(
          source: .codex,
          enabled: false,
          snapshot: .empty(at: now, status: .ready)
        )
      )
    }

    if let antigravityResult {
      enabledResults.append(antigravityResult)
      breakdowns.append(
        UsageSourceBreakdown(
          source: .antigravity,
          enabled: true,
          snapshot: antigravityResult.snapshot
        )
      )
    } else {
      breakdowns.append(
        UsageSourceBreakdown(
          source: .antigravity,
          enabled: false,
          snapshot: .empty(at: now, status: .ready)
        )
      )
    }

    let combined = combine(results: enabledResults, now: now)
    return MultiSourceUsageSnapshot(combined: combined, sources: breakdowns)
  }

  private func combine(results: [SourceScanResult], now: Date) -> UsageSnapshot {
    guard !results.isEmpty else {
      return .empty(at: now, status: .sessionsDirectoryMissing)
    }

    let readyResults = results.filter { $0.status == .ready }
    if !readyResults.isEmpty {
      var seenKeys: Set<String> = []
      var mergedEvents: [UsageEvent] = []
      var activeSessions = 0
      var malformedRelevantLines = 0

      for result in readyResults {
        activeSessions += result.activeSessions
        malformedRelevantLines += result.malformedRelevantLines
        for event in result.events where seenKeys.insert(event.deduplicationKey).inserted {
          mergedEvents.append(event)
        }
      }

      return UsageMetricsCalculator.snapshot(
        events: mergedEvents,
        now: now,
        activeSessions: activeSessions,
        malformedRelevantLines: malformedRelevantLines
      )
    }

    let malformed = results.reduce(0) { $0 + $1.malformedRelevantLines }
    let status: CollectionStatus =
      results.contains { $0.status == .readFailed } ? .readFailed : .sessionsDirectoryMissing
    return UsageSnapshot(
      generatedAt: now,
      oneMinute: .empty(windowSeconds: 60),
      fiveMinutes: .empty(windowSeconds: 300),
      thirtyMinutes: .empty(windowSeconds: 1_800),
      oneHour: .empty(windowSeconds: 3_600),
      activeSessions: 0,
      malformedRelevantLines: malformed,
      status: status
    )
  }
}
