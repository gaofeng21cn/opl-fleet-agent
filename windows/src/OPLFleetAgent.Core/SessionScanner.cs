using System.Text;

namespace OPLFleetAgent.Core;

public sealed class SessionScanner
{
    private sealed class FileCursor
    {
        public long Offset { get; set; }
        public byte[] Remainder { get; set; } = [];
        public TokenParserState ParserState { get; } = new();
    }

    private sealed record SessionFile(string Path, long Size, DateTimeOffset ModifiedAt);

    private const int ReadChunkSize = 1_048_576;
    private const int MarkerOverlapSize = 4_096;
    private static readonly byte[][] MarkerBytes =
        TokenEventParser.RelevantMarkers.Select(Encoding.UTF8.GetBytes).ToArray();

    private readonly object gate = new();
    private readonly Dictionary<string, FileCursor> cursors =
        new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, DateTimeOffset> seenDeduplicationKeys =
        new(StringComparer.Ordinal);
    private readonly List<UsageEvent> events = [];
    private int malformedRelevantLines;

    public SessionScanner(string? codexHome = null)
    {
        CodexHome = ResolveCodexHome(codexHome);
        SessionsRoot = Path.Combine(CodexHome, "sessions");
    }

    public string CodexHome { get; }
    public string SessionsRoot { get; }

    public UsageSnapshot Refresh(DateTimeOffset? generatedAt = null)
    {
        lock (gate)
        {
            var now = generatedAt ?? DateTimeOffset.Now;
            if (!Directory.Exists(SessionsRoot))
            {
                return UsageSnapshot.Empty(now, CollectionStatus.SessionsDirectoryMissing);
            }

            try
            {
                var retentionStart = now.AddMinutes(-65);
                var files = DiscoverSessionFiles(now);
                foreach (var file in files)
                {
                    ReadAppendedContent(file, retentionStart);
                }

                events.RemoveAll(item => item.Timestamp < retentionStart);
                foreach (var key in seenDeduplicationKeys
                    .Where(item => item.Value < retentionStart)
                    .Select(item => item.Key)
                    .ToArray())
                {
                    seenDeduplicationKeys.Remove(key);
                }

                var activeStart = now.AddMinutes(-2);
                var activeSessions = files.Count(file => file.ModifiedAt >= activeStart);
                return UsageMetrics.Snapshot(
                    events,
                    now,
                    activeSessions,
                    malformedRelevantLines);
            }
            catch (IOException)
            {
                return UsageSnapshot.Empty(now, CollectionStatus.ReadFailed) with
                {
                    MalformedRelevantLines = malformedRelevantLines,
                };
            }
            catch (UnauthorizedAccessException)
            {
                return UsageSnapshot.Empty(now, CollectionStatus.ReadFailed) with
                {
                    MalformedRelevantLines = malformedRelevantLines,
                };
            }
        }
    }

    public static string ResolveCodexHome(string? explicitPath = null)
    {
        var configured = string.IsNullOrWhiteSpace(explicitPath)
            ? Environment.GetEnvironmentVariable("CODEX_HOME")
            : explicitPath;
        if (string.IsNullOrWhiteSpace(configured))
        {
            return Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".codex");
        }

        var expanded = Environment.ExpandEnvironmentVariables(configured.Trim().Trim('"'));
        if (expanded == "~")
        {
            expanded = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        }
        else if (expanded.StartsWith($"~{Path.DirectorySeparatorChar}", StringComparison.Ordinal))
        {
            expanded = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                expanded[2..]);
        }
        return Path.GetFullPath(expanded);
    }

    private List<SessionFile> DiscoverSessionFiles(DateTimeOffset now)
    {
        var cutoff = now.AddMinutes(-65);
        var files = new List<SessionFile>();
        foreach (var path in Directory.EnumerateFiles(
                     SessionsRoot,
                     "*.jsonl",
                     SearchOption.AllDirectories))
        {
            var info = new FileInfo(path);
            var modifiedAt = new DateTimeOffset(info.LastWriteTimeUtc, TimeSpan.Zero);
            if (modifiedAt < cutoff && !cursors.ContainsKey(path))
            {
                continue;
            }
            files.Add(new SessionFile(path, Math.Max(info.Length, 0), modifiedAt));
        }
        return files.OrderBy(item => item.Path, StringComparer.OrdinalIgnoreCase).ToList();
    }

    private void ReadAppendedContent(SessionFile file, DateTimeOffset retentionStart)
    {
        if (!cursors.TryGetValue(file.Path, out var cursor) || file.Size < cursor.Offset)
        {
            cursor = new FileCursor();
            cursors[file.Path] = cursor;
        }
        if (file.Size <= cursor.Offset)
        {
            return;
        }

        using var stream = new FileStream(
            file.Path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete,
            ReadChunkSize,
            FileOptions.SequentialScan);
        stream.Seek(cursor.Offset, SeekOrigin.Begin);
        var buffer = new byte[ReadChunkSize];
        while (true)
        {
            var count = stream.Read(buffer, 0, buffer.Length);
            if (count <= 0)
            {
                break;
            }

            var combined = new byte[cursor.Remainder.Length + count];
            cursor.Remainder.CopyTo(combined, 0);
            buffer.AsSpan(0, count).CopyTo(combined.AsSpan(cursor.Remainder.Length));
            var split = SplitRelevantCompleteLines(combined);
            cursor.Remainder = split.Remainder;
            var batch = TokenEventParser.Parse(
                split.Lines,
                cursor.ParserState,
                Path.GetFileNameWithoutExtension(file.Path));
            malformedRelevantLines += batch.MalformedRelevantLines;
            foreach (var usageEvent in batch.Events.Where(item => item.Timestamp >= retentionStart))
            {
                if (seenDeduplicationKeys.TryAdd(
                    usageEvent.DeduplicationKey,
                    usageEvent.Timestamp))
                {
                    events.Add(usageEvent);
                }
            }
        }
        cursor.Offset = stream.Position;
    }

    private static (IReadOnlyList<string> Lines, byte[] Remainder) SplitRelevantCompleteLines(
        byte[] data)
    {
        var finalNewline = Array.LastIndexOf(data, (byte)'\n');
        if (finalNewline < 0)
        {
            return ([], RetainIncompleteLine(data));
        }

        var lines = new List<string>();
        var lineStart = 0;
        while (lineStart <= finalNewline)
        {
            var lineEnd = Array.IndexOf(data, (byte)'\n', lineStart, finalNewline - lineStart + 1);
            if (lineEnd < 0)
            {
                break;
            }
            var line = data.AsSpan(lineStart, lineEnd - lineStart);
            if (line.Length > 0 && ContainsRelevantMarker(line))
            {
                lines.Add(Encoding.UTF8.GetString(line));
            }
            lineStart = lineEnd + 1;
        }

        return (lines, data[(finalNewline + 1)..]);
    }

    private static byte[] RetainIncompleteLine(byte[] data)
    {
        if (ContainsRelevantMarker(data) || data.Length <= MarkerOverlapSize)
        {
            return data;
        }
        return data[^MarkerOverlapSize..];
    }

    private static bool ContainsRelevantMarker(ReadOnlySpan<byte> line)
    {
        foreach (var marker in MarkerBytes)
        {
            if (line.IndexOf(marker) >= 0)
            {
                return true;
            }
        }
        return false;
    }
}
