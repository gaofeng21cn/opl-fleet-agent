import Foundation

public actor AntigravitySessionScanner {
  private static let createdAtPrefixCompact = Data("\"created_at\":\"".utf8)
  private static let createdAtPrefixSpaced = Data("\"created_at\": \"".utf8)
  private static let newline = Data([0x0A])

  private struct FileCursor: Sendable {
    var offset: UInt64 = 0
    var remainder = Data()
    var lastModified = Date.distantPast
    var fileID: UInt64?
  }

  private struct TranscriptFile: Sendable {
    let url: URL
    let conversationID: String
    let size: UInt64
    let modifiedAt: Date
    let fileID: UInt64?
  }

  public let brainRoots: [URL]

  private let fileManager: FileManager
  private let activeFileHorizon: TimeInterval
  private let readChunkSize = 1_048_576
  private let markerOverlapSize = 4_096
  private let timestampHeaderScanLimit = 512
  private var cursors: [URL: FileCursor] = [:]
  private var seenDeduplicationKeys: [String: Date] = [:]
  private var events: [UsageEvent] = []
  private var malformedRelevantLines = 0

  public init(
    brainRoots: [URL] = AntigravitySessionScanner.defaultBrainRoots(),
    activeFileHorizon: TimeInterval = 65 * 60,
    fileManager: FileManager = .default
  ) {
    self.brainRoots = Self.deduplicatedBrainRoots(brainRoots)
    self.activeFileHorizon = activeFileHorizon
    self.fileManager = fileManager
  }

  public static func defaultAntigravityHome(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    if let configured = nonEmptyExpandedURL(environment["ANTIGRAVITY_HOME"]) {
      return configured
    }
    return resolvedUserHome(environment: environment)
      .appendingPathComponent(".gemini", isDirectory: true)
      .appendingPathComponent("antigravity", isDirectory: true)
  }

  public static func defaultAntigravityCLIHome(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    if let configured = nonEmptyExpandedURL(environment["ANTIGRAVITY_CLI_HOME"]) {
      return configured
    }
    return resolvedUserHome(environment: environment)
      .appendingPathComponent(".gemini", isDirectory: true)
      .appendingPathComponent("antigravity-cli", isDirectory: true)
  }

  public static func defaultBrainRoots(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> [URL] {
    deduplicatedBrainRoots([
      defaultAntigravityHome(environment: environment)
        .appendingPathComponent("brain", isDirectory: true),
      defaultAntigravityCLIHome(environment: environment)
        .appendingPathComponent("brain", isDirectory: true),
    ])
  }

  static func explicitBrainRoots(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> [URL] {
    var roots: [URL] = []
    if let appHome = nonEmptyExpandedURL(environment["ANTIGRAVITY_HOME"]) {
      roots.append(appHome.appendingPathComponent("brain", isDirectory: true))
    }
    if let cliHome = nonEmptyExpandedURL(environment["ANTIGRAVITY_CLI_HOME"]) {
      roots.append(cliHome.appendingPathComponent("brain", isDirectory: true))
    }
    return deduplicatedBrainRoots(roots)
  }

  static func deduplicatedBrainRoots(_ roots: [URL]) -> [URL] {
    var seen: Set<String> = []
    var result: [URL] = []
    for root in roots {
      let standardized = root.standardizedFileURL
      if seen.insert(standardized.path).inserted {
        result.append(standardized)
      }
    }
    return result
  }

  public func refresh(now: Date = Date()) -> UsageSnapshot {
    refreshResult(now: now).snapshot
  }

  func refreshResult(now: Date = Date()) -> SourceScanResult {
    let existingRoots = brainRoots.filter { root in
      var isDirectory: ObjCBool = false
      return fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory)
        && isDirectory.boolValue
    }

    guard !existingRoots.isEmpty else {
      let empty = UsageSnapshot.empty(at: now, status: .sessionsDirectoryMissing)
      return SourceScanResult(
        events: [],
        activeSessions: 0,
        malformedRelevantLines: malformedRelevantLines,
        status: .sessionsDirectoryMissing,
        snapshot: empty
      )
    }

    do {
      let retentionStart = now.addingTimeInterval(-65 * 60)
      let files = try discoverTranscriptFiles(in: existingRoots, now: now)
      for file in files {
        try readAppendedContent(from: file, retentionStart: retentionStart)
      }

      events.removeAll { $0.timestamp < retentionStart }
      seenDeduplicationKeys = seenDeduplicationKeys.filter { $0.value >= retentionStart }
      let activeStart = now.addingTimeInterval(-2 * 60)
      let activeSessions = Set(files.filter { $0.modifiedAt >= activeStart }.map(\.url)).count

      let snapshot = UsageMetricsCalculator.snapshot(
        events: events,
        now: now,
        activeSessions: activeSessions,
        malformedRelevantLines: malformedRelevantLines
      )
      return SourceScanResult(
        events: events,
        activeSessions: activeSessions,
        malformedRelevantLines: malformedRelevantLines,
        status: .ready,
        snapshot: snapshot
      )
    } catch {
      let snapshot = UsageSnapshot(
        generatedAt: now,
        oneMinute: .empty(windowSeconds: 60),
        fiveMinutes: .empty(windowSeconds: 300),
        thirtyMinutes: .empty(windowSeconds: 1_800),
        oneHour: .empty(windowSeconds: 3_600),
        activeSessions: 0,
        malformedRelevantLines: malformedRelevantLines,
        status: .readFailed
      )
      return SourceScanResult(
        events: [],
        activeSessions: 0,
        malformedRelevantLines: malformedRelevantLines,
        status: .readFailed,
        snapshot: snapshot
      )
    }
  }

  private func discoverTranscriptFiles(in roots: [URL], now: Date) throws -> [TranscriptFile] {
    let cutoff = now.addingTimeInterval(-activeFileHorizon)
    var files: [TranscriptFile] = []
    let conversationKeys: Set<URLResourceKey> = [.isDirectoryKey]
    let fileKeys: Set<URLResourceKey> = [
      .isRegularFileKey, .contentModificationDateKey, .fileSizeKey,
    ]

    for root in roots {
      let entries = try fileManager.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: Array(conversationKeys),
        options: [.skipsHiddenFiles]
      )
      for conversationURL in entries {
        let dirValues = try? conversationURL.resourceValues(forKeys: conversationKeys)
        guard dirValues?.isDirectory == true else { continue }

        let transcriptURL =
          conversationURL
          .appendingPathComponent(".system_generated", isDirectory: true)
          .appendingPathComponent("logs", isDirectory: true)
          .appendingPathComponent("transcript.jsonl", isDirectory: false)
        guard fileManager.fileExists(atPath: transcriptURL.path) else { continue }

        let values = try transcriptURL.resourceValues(forKeys: fileKeys)
        guard values.isRegularFile == true else { continue }

        let modifiedAt = values.contentModificationDate ?? .distantPast
        guard modifiedAt >= cutoff || cursors[transcriptURL] != nil else { continue }

        let attributes = try? fileManager.attributesOfItem(atPath: transcriptURL.path)
        let fileID = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
        files.append(
          TranscriptFile(
            url: transcriptURL,
            conversationID: conversationURL.lastPathComponent,
            size: UInt64(max(values.fileSize ?? 0, 0)),
            modifiedAt: modifiedAt,
            fileID: fileID
          )
        )
      }
    }

    return files.sorted { $0.url.path < $1.url.path }
  }

  private func readAppendedContent(from file: TranscriptFile, retentionStart: Date) throws {
    var cursor = cursors[file.url] ?? FileCursor()
    let inodeChanged =
      cursor.fileID != nil && file.fileID != nil && cursor.fileID != file.fileID
    if file.size < cursor.offset || inodeChanged {
      cursor = FileCursor()
    }

    guard file.size > cursor.offset else {
      cursor.lastModified = file.modifiedAt
      cursor.fileID = file.fileID ?? cursor.fileID
      cursors[file.url] = cursor
      return
    }

    let handle = try FileHandle(forReadingFrom: file.url)
    defer { try? handle.close() }
    try handle.seek(toOffset: cursor.offset)
    let minimumTimestamp = retentionStart.addingTimeInterval(-2).formatted(.iso8601)

    while true {
      let appended = try autoreleasepool {
        try handle.read(upToCount: readChunkSize)
      }
      guard let appended, !appended.isEmpty else { break }

      autoreleasepool {
        var combined = cursor.remainder
        combined.append(appended)
        let split = splitRelevantCompleteLines(combined, minimumTimestamp: minimumTimestamp)
        cursor.remainder = split.remainder

        let batch = AntigravityTokenEventParser.parse(
          lines: split.lines,
          conversationID: file.conversationID
        )
        malformedRelevantLines += batch.malformedRelevantLines

        for event in batch.events where event.timestamp >= retentionStart {
          if seenDeduplicationKeys[event.deduplicationKey] == nil {
            seenDeduplicationKeys[event.deduplicationKey] = event.timestamp
            events.append(event)
          }
        }
      }
    }

    cursor.offset = file.size
    cursor.lastModified = file.modifiedAt
    cursor.fileID = file.fileID
    cursors[file.url] = cursor
  }

  private func splitRelevantCompleteLines(
    _ data: Data,
    minimumTimestamp: String
  ) -> (lines: [Data], remainder: Data) {
    guard let finalNewline = data.lastIndex(of: 0x0A) else {
      return ([], retainedIncompleteLine(data))
    }

    let completeEnd = data.index(after: finalNewline)
    let completeRange = data.startIndex..<completeEnd
    var lineStarts: Set<Data.Index> = []

    for marker in AntigravityTokenEventParser.relevantMarkers {
      var searchStart = completeRange.lowerBound
      while searchStart < completeRange.upperBound,
        let match = data.range(
          of: marker,
          options: [],
          in: searchStart..<completeRange.upperBound
        )
      {
        let lineStart =
          data.range(
            of: Self.newline,
            options: .backwards,
            in: data.startIndex..<match.lowerBound
          )?.upperBound ?? data.startIndex
        lineStarts.insert(lineStart)
        searchStart = match.upperBound
      }
    }

    let lines = lineStarts.sorted().compactMap { start -> Data? in
      guard
        let end = data.range(
          of: Self.newline,
          options: [],
          in: start..<completeEnd
        )?.lowerBound, start < end
      else {
        return nil
      }
      let line = Data(data[start..<end])
      return eventMayBeRecent(line, minimumTimestamp: minimumTimestamp) ? line : nil
    }
    let remainder =
      completeEnd < data.endIndex
      ? retainedIncompleteLine(data[completeEnd...])
      : Data()
    return (lines, remainder)
  }

  private func retainedIncompleteLine(_ data: Data) -> Data {
    if AntigravityTokenEventParser.relevantMarkers.contains(where: { data.range(of: $0) != nil }) {
      return data
    }
    guard data.count > markerOverlapSize else { return data }
    return Data(data.suffix(markerOverlapSize))
  }

  private func eventMayBeRecent(_ line: Data, minimumTimestamp: String) -> Bool {
    let headerEnd = min(line.count, timestampHeaderScanLimit)
    let searchRange = line.startIndex..<line.index(line.startIndex, offsetBy: headerEnd)
    let match =
      line.range(of: Self.createdAtPrefixCompact, options: [], in: searchRange)
      ?? line.range(of: Self.createdAtPrefixSpaced, options: [], in: searchRange)
    guard let match else { return true }

    let valueStart = match.upperBound
    guard let valueEnd = line[valueStart...].firstIndex(of: 0x22) else { return true }
    let timestamp = String(decoding: line[valueStart..<valueEnd], as: UTF8.self)
    guard timestamp.hasSuffix("Z") else { return true }
    return timestamp >= minimumTimestamp
  }

  private static func nonEmptyExpandedURL(_ value: String?) -> URL? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else {
      return nil
    }
    return URL(
      fileURLWithPath: NSString(string: trimmed).expandingTildeInPath,
      isDirectory: true
    )
  }

  private static func resolvedUserHome(environment: [String: String]) -> URL {
    if let home = nonEmptyExpandedURL(environment["HOME"]) {
      return home
    }
    return FileManager.default.homeDirectoryForCurrentUser
  }
}
