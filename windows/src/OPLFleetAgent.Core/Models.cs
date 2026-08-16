using System.Text.Json.Serialization;

namespace OPLFleetAgent.Core;

public sealed record TokenUsage
{
    [JsonPropertyName("input_tokens")]
    public long InputTokens { get; }

    [JsonPropertyName("cached_input_tokens")]
    public long CachedInputTokens { get; }

    [JsonPropertyName("output_tokens")]
    public long OutputTokens { get; }

    [JsonPropertyName("reasoning_output_tokens")]
    public long ReasoningOutputTokens { get; }

    [JsonPropertyName("total_tokens")]
    public long TotalTokens { get; }

    [JsonConstructor]
    public TokenUsage(
        long inputTokens = 0,
        long cachedInputTokens = 0,
        long outputTokens = 0,
        long reasoningOutputTokens = 0,
        long? totalTokens = null)
    {
        InputTokens = Math.Max(inputTokens, 0);
        CachedInputTokens = Math.Clamp(cachedInputTokens, 0, InputTokens);
        OutputTokens = Math.Max(outputTokens, 0);
        ReasoningOutputTokens = Math.Clamp(reasoningOutputTokens, 0, OutputTokens);
        TotalTokens = Math.Max(totalTokens ?? InputTokens + OutputTokens, 0);
    }
}

internal readonly record struct UsageTotals(
    long Input,
    long Output,
    long Cached,
    long Reasoning,
    long ReportedTotal)
{
    public UsageTotals(TokenUsage usage)
        : this(
            usage.InputTokens,
            usage.OutputTokens,
            usage.CachedInputTokens,
            usage.ReasoningOutputTokens,
            usage.TotalTokens)
    {
    }

    private long ComparisonTotal => Input + Output;

    public UsageTotals? DeltaFrom(UsageTotals previous)
    {
        if (Input < previous.Input || Output < previous.Output || Cached < previous.Cached ||
            Reasoning < previous.Reasoning)
        {
            return null;
        }

        return new UsageTotals(
            Input - previous.Input,
            Output - previous.Output,
            Cached - previous.Cached,
            Reasoning - previous.Reasoning,
            Math.Max(ReportedTotal - previous.ReportedTotal, 0));
    }

    public bool IsWithin(UsageTotals baseline) =>
        Input <= baseline.Input && Output <= baseline.Output && Cached <= baseline.Cached &&
        Reasoning <= baseline.Reasoning;

    public bool LooksLikeStaleRegression(UsageTotals previous, UsageTotals last)
    {
        var old = previous.ComparisonTotal;
        var current = ComparisonTotal;
        var increment = last.ComparisonTotal;
        return old > 0 && current > 0 && increment > 0 &&
            (current * 100 >= old * 98 || current + increment * 2 >= old);
    }

    public TokenUsage AsUsage() => new(
        Input,
        Cached,
        Output,
        Reasoning,
        ReportedTotal > 0 ? ReportedTotal : Input + Output);
}

public sealed record UsageEvent(
    DateTimeOffset Timestamp,
    TokenUsage Usage,
    string SessionId,
    string DeduplicationKey);

public sealed record TokenParseBatch(IReadOnlyList<UsageEvent> Events, int MalformedRelevantLines);

public sealed record WindowMetrics(
    int WindowSeconds,
    int RequestCount,
    double RequestsPerMinute,
    double TokensPerSecond,
    double InputTokensPerSecond,
    double CachedInputTokensPerSecond,
    double OutputTokensPerSecond,
    double ReasoningTokensPerSecond,
    double CacheRatio,
    long TotalTokens)
{
    public static WindowMetrics Empty(int seconds) =>
        new(seconds, 0, 0, 0, 0, 0, 0, 0, 0, 0);
}

public enum CollectionStatus
{
    Ready,
    SessionsDirectoryMissing,
    ReadFailed,
}

public sealed record UsageSnapshot(
    DateTimeOffset GeneratedAt,
    WindowMetrics OneMinute,
    WindowMetrics FiveMinutes,
    WindowMetrics ThirtyMinutes,
    WindowMetrics OneHour,
    int ActiveSessions,
    int MalformedRelevantLines,
    CollectionStatus Status)
{
    public static UsageSnapshot Empty(DateTimeOffset date, CollectionStatus status) =>
        new(
            date,
            WindowMetrics.Empty(60),
            WindowMetrics.Empty(300),
            WindowMetrics.Empty(1_800),
            WindowMetrics.Empty(3_600),
            0,
            0,
            status);
}
