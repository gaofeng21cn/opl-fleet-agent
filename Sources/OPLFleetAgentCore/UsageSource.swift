import Foundation

public enum UsageSourceKind: String, CaseIterable, Codable, Equatable, Hashable, Sendable,
  Identifiable
{
  case codex
  case antigravity

  public var id: Self { self }

  public var displayName: String {
    switch self {
    case .codex:
      "Codex"
    case .antigravity:
      "Antigravity"
    }
  }
}

public struct UsageSourceBreakdown: Codable, Equatable, Sendable, Identifiable {
  public let source: UsageSourceKind
  public let enabled: Bool
  public let snapshot: UsageSnapshot

  public var id: UsageSourceKind { source }

  public init(source: UsageSourceKind, enabled: Bool, snapshot: UsageSnapshot) {
    self.source = source
    self.enabled = enabled
    self.snapshot = snapshot
  }
}

public struct MultiSourceUsageSnapshot: Codable, Equatable, Sendable {
  public let combined: UsageSnapshot
  public let sources: [UsageSourceBreakdown]

  public init(combined: UsageSnapshot, sources: [UsageSourceBreakdown]) {
    self.combined = combined
    self.sources = sources
  }

  public func breakdown(for source: UsageSourceKind) -> UsageSourceBreakdown? {
    sources.first { $0.source == source }
  }

  public static func empty(
    at date: Date,
    codexEnabled: Bool = true,
    antigravityEnabled: Bool = true,
    status: CollectionStatus = .ready
  ) -> MultiSourceUsageSnapshot {
    MultiSourceUsageSnapshot(
      combined: .empty(at: date, status: status),
      sources: [
        UsageSourceBreakdown(
          source: .codex,
          enabled: codexEnabled,
          snapshot: .empty(at: date, status: .ready)
        ),
        UsageSourceBreakdown(
          source: .antigravity,
          enabled: antigravityEnabled,
          snapshot: .empty(at: date, status: .ready)
        ),
      ]
    )
  }
}

struct SourceScanResult: Sendable {
  let events: [UsageEvent]
  let activeSessions: Int
  let malformedRelevantLines: Int
  let status: CollectionStatus
  let snapshot: UsageSnapshot
}

public struct UsageSourceConfiguration: Equatable, Sendable {
  public static let codexEnabledDefaultsKey = "usageSourceCodexEnabled"
  public static let antigravityEnabledDefaultsKey = "usageSourceAntigravityEnabled"
  public static let sourcesEnvironmentKey = "OPL_FLEET_AGENT_SOURCES"

  public let codexEnabled: Bool
  public let antigravityEnabled: Bool
  public let codexHome: URL
  public let antigravityBrainRoots: [URL]

  public init(
    codexEnabled: Bool = true,
    antigravityEnabled: Bool = true,
    codexHome: URL = SessionScanner.defaultCodexHome(),
    antigravityBrainRoots: [URL] = AntigravitySessionScanner.defaultBrainRoots()
  ) {
    self.codexEnabled = codexEnabled
    self.antigravityEnabled = antigravityEnabled
    self.codexHome = codexHome
    self.antigravityBrainRoots = AntigravitySessionScanner.deduplicatedBrainRoots(
      antigravityBrainRoots)
  }

  public static func defaultSavedSourceEnabled(
    forKey key: String,
    defaultsDomain: [String: Any]? = UserDefaults.standard.persistentDomain(
      forName: AmbientOpsMachineIdentity.defaultsDomain)
  ) -> Bool? {
    defaultsDomain?[key] as? Bool
  }

  public static func resolve(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    savedCodexEnabled: Bool? = defaultSavedSourceEnabled(forKey: codexEnabledDefaultsKey),
    savedAntigravityEnabled: Bool? = defaultSavedSourceEnabled(
      forKey: antigravityEnabledDefaultsKey)
  ) -> UsageSourceConfiguration {
    let codexHome = SessionScanner.defaultCodexHome(environment: environment)
    let explicitCodexHome = nonEmptyValue(environment["CODEX_HOME"]) != nil
    let explicitAntigravityHome = nonEmptyValue(environment["ANTIGRAVITY_HOME"]) != nil
    let explicitAntigravityCLIHome = nonEmptyValue(environment["ANTIGRAVITY_CLI_HOME"]) != nil
    let hasExplicitAntigravityPath = explicitAntigravityHome || explicitAntigravityCLIHome

    let antigravityBrainRoots: [URL] =
      if hasExplicitAntigravityPath {
        AntigravitySessionScanner.explicitBrainRoots(environment: environment)
      } else {
        AntigravitySessionScanner.defaultBrainRoots(environment: environment)
      }

    if let rawSources = nonEmptyValue(environment[sourcesEnvironmentKey]) {
      let parsed = parseSourcesList(rawSources)
      if parsed.recognizedAny {
        return UsageSourceConfiguration(
          codexEnabled: parsed.codexEnabled,
          antigravityEnabled: parsed.antigravityEnabled,
          codexHome: codexHome,
          antigravityBrainRoots: antigravityBrainRoots
        )
      }
      return UsageSourceConfiguration(
        codexEnabled: savedCodexEnabled ?? true,
        antigravityEnabled: savedAntigravityEnabled ?? true,
        codexHome: codexHome,
        antigravityBrainRoots: antigravityBrainRoots
      )
    }

    if explicitCodexHome || hasExplicitAntigravityPath {
      return UsageSourceConfiguration(
        codexEnabled: explicitCodexHome,
        antigravityEnabled: hasExplicitAntigravityPath,
        codexHome: codexHome,
        antigravityBrainRoots: antigravityBrainRoots
      )
    }

    return UsageSourceConfiguration(
      codexEnabled: savedCodexEnabled ?? true,
      antigravityEnabled: savedAntigravityEnabled ?? true,
      codexHome: codexHome,
      antigravityBrainRoots: antigravityBrainRoots
    )
  }

  var bindingComponents: [String] {
    var components: [String] = []
    if codexEnabled {
      components.append("source:codex")
      components.append(codexHome.standardizedFileURL.path)
    }
    if antigravityEnabled {
      components.append("source:antigravity")
      components.append(contentsOf: antigravityBrainRoots.map { $0.standardizedFileURL.path })
    }
    if !codexEnabled && !antigravityEnabled {
      components.append("source:none")
    }
    return components
  }

  private static func nonEmptyValue(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else {
      return nil
    }
    return trimmed
  }

  private static func parseSourcesList(_ raw: String) -> (
    recognizedAny: Bool, codexEnabled: Bool, antigravityEnabled: Bool
  ) {
    let tokens = Set(
      raw
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .filter { !$0.isEmpty }
    )
    if tokens.contains("all") {
      return (true, true, true)
    }
    let hasCodex = tokens.contains("codex")
    let hasAntigravity = tokens.contains("antigravity")
    guard hasCodex || hasAntigravity else {
      return (false, true, true)
    }
    return (true, hasCodex, hasAntigravity)
  }
}
