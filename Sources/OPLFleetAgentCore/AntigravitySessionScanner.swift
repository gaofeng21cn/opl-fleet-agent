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
    let minimumTimestamp = retentionStart.addingTimeInterval(
      -(AntigravityTokenEventParser.maxTurnDurationSeconds + 2)
    ).formatted(.iso8601)
    var pendingRelevantLine: Data?

    while true {
      let appended = try autoreleasepool {
        try handle.read(upToCount: readChunkSize)
      }
      guard let appended, !appended.isEmpty else { break }

      autoreleasepool {
        var combined = cursor.remainder
        combined.append(appended)
        let scanned = scanChunkLines(
          combined,
          minimumTimestamp: minimumTimestamp,
          pendingRelevantLine: &pendingRelevantLine
        )
        cursor.remainder = scanned.remainder

        let batch = AntigravityTokenEventParser.parse(
          entries: scanned.inputs,
          conversationID: file.conversationID
        )
        appendBatch(batch, retentionStart: retentionStart)
      }
    }

    if let pending = pendingRelevantLine {
      let eofBatch = AntigravityTokenEventParser.parse(
        entries: [
          AntigravityTranscriptLineInput(
            line: pending,
            nextStep: nil,
            eofModifiedAt: file.modifiedAt
          )
        ],
        conversationID: file.conversationID
      )
      appendBatch(eofBatch, retentionStart: retentionStart)
    }

    cursor.offset = file.size
    cursor.lastModified = file.modifiedAt
    cursor.fileID = file.fileID
    cursors[file.url] = cursor
  }

  private func appendBatch(_ batch: TokenParseBatch, retentionStart: Date) {
    malformedRelevantLines += batch.malformedRelevantLines
    for event in batch.events where event.timestamp >= retentionStart {
      if seenDeduplicationKeys[event.deduplicationKey] == nil {
        seenDeduplicationKeys[event.deduplicationKey] = event.timestamp
        events.append(event)
      }
    }
  }

  private func scanChunkLines(
    _ data: Data,
    minimumTimestamp: String,
    pendingRelevantLine: inout Data?
  ) -> (inputs: [AntigravityTranscriptLineInput], remainder: Data) {
    guard let finalNewline = data.lastIndex(of: 0x0A) else {
      if let pending = pendingRelevantLine,
        data.count > markerOverlapSize,
        let hint = AntigravityTokenEventParser.extractStepHint(from: data)
      {
        pendingRelevantLine = nil
        return (
          [AntigravityTranscriptLineInput(line: pending, nextStep: hint, eofModifiedAt: nil)],
          retainedIncompleteLine(data)
        )
      }
      return ([], retainedIncompleteLine(data))
    }

    let completeEnd = data.index(after: finalNewline)
    var inputs: [AntigravityTranscriptLineInput] = []
    var lineStart = data.startIndex

    while lineStart < completeEnd {
      guard
        let newlineIndex = data.range(
          of: Self.newline,
          options: [],
          in: lineStart..<completeEnd
        )?.lowerBound
      else {
        break
      }

      let lineRange = lineStart..<newlineIndex
      lineStart = data.index(after: newlineIndex)
      guard !lineRange.isEmpty else { continue }

      if let pending = pendingRelevantLine {
        let hintEnd = data.index(
          lineRange.lowerBound,
          offsetBy: min(
            data.distance(from: lineRange.lowerBound, to: lineRange.upperBound),
            timestampHeaderScanLimit
          )
        )
        let hint = AntigravityTokenEventParser.extractStepHint(
          from: Data(data[lineRange.lowerBound..<hintEnd])
        )
        inputs.append(
          AntigravityTranscriptLineInput(line: pending, nextStep: hint, eofModifiedAt: nil)
        )
        pendingRelevantLine = nil
      }

      if AntigravityTokenEventParser.relevantMarkers.contains(where: {
        data.range(of: $0, options: [], in: lineRange) != nil
      }) && eventMayBeRecent(in: data, range: lineRange, minimumTimestamp: minimumTimestamp) {
        pendingRelevantLine = Data(data[lineRange])
      }
    }

    let remainderSlice =
      completeEnd < data.endIndex
      ? data[completeEnd...]
      : Data.SubSequence()
    if !remainderSlice.isEmpty {
      if let pending = pendingRelevantLine,
        remainderSlice.count > markerOverlapSize,
        let hint = AntigravityTokenEventParser.extractStepHint(
          from: Data(remainderSlice.prefix(timestampHeaderScanLimit))
        )
      {
        inputs.append(
          AntigravityTranscriptLineInput(line: pending, nextStep: hint, eofModifiedAt: nil)
        )
        pendingRelevantLine = nil
      }
      return (inputs, retainedIncompleteLine(Data(remainderSlice)))
    }
    return (inputs, Data())
  }

  private func retainedIncompleteLine(_ data: Data) -> Data {
    if AntigravityTokenEventParser.relevantMarkers.contains(where: { data.range(of: $0) != nil }) {
      return data
    }
    guard data.count > markerOverlapSize else { return data }
    return Data(data.suffix(markerOverlapSize))
  }

  private func eventMayBeRecent(
    in data: Data,
    range: Range<Data.Index>,
    minimumTimestamp: String
  ) -> Bool {
    let headerDistance = min(
      data.distance(from: range.lowerBound, to: range.upperBound),
      timestampHeaderScanLimit
    )
    let headerEnd = data.index(range.lowerBound, offsetBy: headerDistance)
    let searchRange = range.lowerBound..<headerEnd
    let match =
      data.range(of: Self.createdAtPrefixCompact, options: [], in: searchRange)
      ?? data.range(of: Self.createdAtPrefixSpaced, options: [], in: searchRange)
    guard let match else { return true }

    let valueStart = match.upperBound
    guard let valueEnd = data[valueStart..<range.upperBound].firstIndex(of: 0x22) else {
      return true
    }
    let timestamp = String(decoding: data[valueStart..<valueEnd], as: UTF8.self)
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
