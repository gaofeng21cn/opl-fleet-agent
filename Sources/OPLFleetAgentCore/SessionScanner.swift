import Foundation

public actor SessionScanner {
  private static let timestampPrefix = Data("{\"timestamp\":\"".utf8)
  private static let newline = Data([0x0A])

  private struct FileCursor: Sendable {
    var offset: UInt64 = 0
    var remainder = Data()
    var parserState = TokenParserState()
    var lastModified = Date.distantPast
  }

  private struct SessionFile: Sendable {
    let url: URL
    let size: UInt64
    let modifiedAt: Date
  }

  public let codexHome: URL
  public let sessionsRoot: URL

  private let fileManager: FileManager
  private let calendar: Calendar
  private let activeFileHorizon: TimeInterval
  private let readChunkSize = 1_048_576
  private let markerOverlapSize = 4_096
  private var cursors: [URL: FileCursor] = [:]
  private var seenDeduplicationKeys: [String: Date] = [:]
  private var events: [UsageEvent] = []
  private var malformedRelevantLines = 0

  public init(
    codexHome: URL = SessionScanner.defaultCodexHome(),
    calendar: Calendar = .current,
    activeFileHorizon: TimeInterval = 65 * 60,
    fileManager: FileManager = .default
  ) {
    self.codexHome = codexHome
    sessionsRoot = codexHome.appendingPathComponent("sessions", isDirectory: true)
    self.calendar = calendar
    self.activeFileHorizon = activeFileHorizon
    self.fileManager = fileManager
  }

  public static func defaultCodexHome(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    if let configured = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !configured.isEmpty
    {
      return URL(
        fileURLWithPath: NSString(string: configured).expandingTildeInPath, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      ".codex", isDirectory: true)
  }

  public func refresh(now: Date = Date()) -> UsageSnapshot {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: sessionsRoot.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      return .empty(at: now, status: .sessionsDirectoryMissing)
    }

    do {
      let retentionStart = now.addingTimeInterval(-65 * 60)
      let files = try discoverSessionFiles(now: now)
      for file in files {
        try readAppendedContent(from: file, retentionStart: retentionStart)
      }

      events.removeAll { $0.timestamp < retentionStart }
      seenDeduplicationKeys = seenDeduplicationKeys.filter { $0.value >= retentionStart }
      let activeStart = now.addingTimeInterval(-2 * 60)
      let activeSessions = Set(files.filter { $0.modifiedAt >= activeStart }.map(\.url)).count

      return UsageMetricsCalculator.snapshot(
        events: events,
        now: now,
        activeSessions: activeSessions,
        malformedRelevantLines: malformedRelevantLines
      )
    } catch {
      return UsageSnapshot(
        generatedAt: now,
        oneMinute: .empty(windowSeconds: 60),
        fiveMinutes: .empty(windowSeconds: 300),
        thirtyMinutes: .empty(windowSeconds: 1_800),
        oneHour: .empty(windowSeconds: 3_600),
        activeSessions: 0,
        malformedRelevantLines: malformedRelevantLines,
        status: .readFailed
      )
    }
  }

  private func discoverSessionFiles(now: Date) throws -> [SessionFile] {
    let cutoff = now.addingTimeInterval(-activeFileHorizon)
    var files: [SessionFile] = []
    let resourceKeys: Set<URLResourceKey> = [
      .contentModificationDateKey, .fileSizeKey, .isRegularFileKey,
    ]
    guard let enumerator = fileManager.enumerator(
      at: sessionsRoot,
      includingPropertiesForKeys: Array(resourceKeys),
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
      return files
    }

    for case let url as URL in enumerator where url.pathExtension == "jsonl" {
      let values = try url.resourceValues(forKeys: resourceKeys)
      guard values.isRegularFile == true else { continue }
      let modifiedAt = values.contentModificationDate ?? .distantPast
      guard modifiedAt >= cutoff || cursors[url] != nil else { continue }
      files.append(
        SessionFile(
          url: url,
          size: UInt64(max(values.fileSize ?? 0, 0)),
          modifiedAt: modifiedAt
        )
      )
    }

    return files.sorted { $0.url.path < $1.url.path }
  }

  private func readAppendedContent(from file: SessionFile, retentionStart: Date) throws {
    var cursor = cursors[file.url] ?? FileCursor()
    if file.size < cursor.offset {
      cursor = FileCursor()
    }

    guard file.size > cursor.offset else {
      cursor.lastModified = file.modifiedAt
      cursors[file.url] = cursor
      return
    }

    let handle = try FileHandle(forReadingFrom: file.url)
    defer { try? handle.close() }
    try handle.seek(toOffset: cursor.offset)
    let fallbackSessionID = file.url.deletingPathExtension().lastPathComponent
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

        let batch = TokenEventParser.parse(
          lines: split.lines,
          state: &cursor.parserState,
          fallbackSessionID: fallbackSessionID
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

    for marker in TokenEventParser.relevantMarkers {
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
    if TokenEventParser.relevantMarkers.contains(where: { data.range(of: $0) != nil }) {
      return data
    }
    guard data.count > markerOverlapSize else { return data }
    return Data(data.suffix(markerOverlapSize))
  }

  private func eventMayBeRecent(_ line: Data, minimumTimestamp: String) -> Bool {
    guard line.starts(with: Self.timestampPrefix) else { return true }
    let start = line.index(line.startIndex, offsetBy: Self.timestampPrefix.count)
    guard let end = line[start...].firstIndex(of: 0x22) else { return true }
    let timestamp = String(decoding: line[start..<end], as: UTF8.self)
    return timestamp >= minimumTimestamp
  }
}
