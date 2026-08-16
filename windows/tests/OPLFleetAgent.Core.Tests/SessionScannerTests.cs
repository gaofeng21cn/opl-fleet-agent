using OPLFleetAgent.Core;

namespace OPLFleetAgent.Core.Tests;

public sealed class SessionScannerTests : IDisposable
{
    private readonly string root = Path.Combine(
        Path.GetTempPath(),
        $"opl-fleet-agent-windows-tests-{Guid.NewGuid():N}");

    [Fact]
    public void IncludesRecentlyModifiedSessionFileFromOlderDirectory()
    {
        var now = DateTimeOffset.Now;
        var directory = SessionsDirectory(now.AddDays(-2));
        Directory.CreateDirectory(directory);
        var log = Path.Combine(directory, "rollout-session-a.jsonl");
        var timestamp = now.AddSeconds(-5).ToString("O");
        File.WriteAllText(
            log,
            string.Join('\n',
                At("""{"timestamp":"$TIMESTAMP","type":"session_meta","payload":{"id":"session-a","model_provider":"test-provider"}}""", timestamp),
                At("""{"timestamp":"$TIMESTAMP","type":"turn_context","payload":{"model":"gpt-test"}}""", timestamp),
                At("""{"timestamp":"$TIMESTAMP","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120}}}}""", timestamp),
                string.Empty));
        File.SetLastWriteTimeUtc(log, now.UtcDateTime);

        var snapshot = new SessionScanner(root).Refresh(now);

        Assert.Equal(1, snapshot.OneMinute.RequestCount);
        Assert.Equal(120, snapshot.OneMinute.TotalTokens);
        Assert.Equal(1, snapshot.ActiveSessions);
    }

    [Fact]
    public void ReadsOnlyAppendedEventsAfterBootstrap()
    {
        var now = DateTimeOffset.Now;
        var directory = SessionsDirectory(now);
        Directory.CreateDirectory(directory);
        var log = Path.Combine(directory, "rollout-session-a.jsonl");
        var firstTimestamp = now.AddSeconds(-20).ToString("O");
        File.WriteAllText(
            log,
            string.Join('\n',
                At("""{"timestamp":"$TIMESTAMP","type":"session_meta","payload":{"id":"session-a","model_provider":"test-provider"}}""", firstTimestamp),
                At("""{"timestamp":"$TIMESTAMP","type":"turn_context","payload":{"model":"gpt-test"}}""", firstTimestamp),
                At("""{"timestamp":"$TIMESTAMP","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120}}}}""", firstTimestamp),
                string.Empty));

        var scanner = new SessionScanner(root);
        Assert.Equal(120, scanner.Refresh(now).OneMinute.TotalTokens);

        var secondTimestamp = now.AddSeconds(-5).ToString("O");
        File.AppendAllText(
            log,
            At("""{"timestamp":"$TIMESTAMP","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"output_tokens":30,"total_tokens":180},"last_token_usage":{"input_tokens":50,"output_tokens":10,"total_tokens":60}}}}""", secondTimestamp) + "\n");
        var second = scanner.Refresh(now);
        var unchanged = scanner.Refresh(now);

        Assert.Equal(180, second.OneMinute.TotalTokens);
        Assert.Equal(180, unchanged.OneMinute.TotalTokens);
        Assert.Equal(2, unchanged.OneMinute.RequestCount);
    }

    [Fact]
    public void DeduplicatesReplayedEventAcrossFiles()
    {
        var now = DateTimeOffset.Now;
        var directory = SessionsDirectory(now);
        Directory.CreateDirectory(directory);
        var timestamp = now.AddSeconds(-5).ToString("O");
        var token = At(
            """{"timestamp":"$TIMESTAMP","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120}}}}""",
            timestamp);
        File.WriteAllText(
            Path.Combine(directory, "rollout-parent.jsonl"),
            string.Join('\n',
                At("""{"timestamp":"$TIMESTAMP","type":"session_meta","payload":{"id":"parent","model_provider":"test-provider"}}""", timestamp),
                At("""{"timestamp":"$TIMESTAMP","type":"turn_context","payload":{"model":"gpt-test"}}""", timestamp),
                token,
                string.Empty));
        File.WriteAllText(
            Path.Combine(directory, "rollout-child.jsonl"),
            string.Join('\n',
                At("""{"timestamp":"$TIMESTAMP","type":"session_meta","payload":{"id":"child","forked_from_id":"parent","model_provider":"test-provider"}}""", timestamp),
                At("""{"timestamp":"$TIMESTAMP","type":"turn_context","payload":{"model":"gpt-test"}}""", timestamp),
                token,
                string.Empty));

        var snapshot = new SessionScanner(root).Refresh(now);

        Assert.Equal(1, snapshot.OneMinute.RequestCount);
        Assert.Equal(120, snapshot.OneMinute.TotalTokens);
    }

    [Fact]
    public void DoesNotRetainConversationOnlyLines()
    {
        var now = DateTimeOffset.Now;
        var directory = SessionsDirectory(now);
        Directory.CreateDirectory(directory);
        var log = Path.Combine(directory, "rollout-session.jsonl");
        File.WriteAllText(
            log,
            """{"timestamp":"2026-01-01T00:00:00Z","type":"response_item","payload":{"prompt":"private prompt","response":"private response"}}""" + "\n");

        var snapshot = new SessionScanner(root).Refresh(now);

        Assert.Equal(0, snapshot.OneMinute.RequestCount);
        Assert.Equal(0, snapshot.MalformedRelevantLines);
    }

    private string SessionsDirectory(DateTimeOffset date) =>
        Path.Combine(
            root,
            "sessions",
            date.Year.ToString("0000"),
            date.Month.ToString("00"),
            date.Day.ToString("00"));

    private static string At(string value, string timestamp) =>
        value.Replace("$TIMESTAMP", timestamp, StringComparison.Ordinal);

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }
}
