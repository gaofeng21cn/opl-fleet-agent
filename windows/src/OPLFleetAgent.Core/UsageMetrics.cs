namespace OPLFleetAgent.Core;

public static class UsageMetrics
{
    public static UsageSnapshot Snapshot(
        IEnumerable<UsageEvent> events,
        DateTimeOffset now,
        int activeSessions,
        int malformedRelevantLines,
        CollectionStatus status = CollectionStatus.Ready)
    {
        var materialized = events.ToArray();
        return new UsageSnapshot(
            now,
            Calculate(materialized, now, 60),
            Calculate(materialized, now, 300),
            Calculate(materialized, now, 1_800),
            Calculate(materialized, now, 3_600),
            activeSessions,
            malformedRelevantLines,
            status);
    }

    private static WindowMetrics Calculate(
        IReadOnlyList<UsageEvent> events,
        DateTimeOffset now,
        int seconds)
    {
        var start = now.AddSeconds(-seconds);
        var futureTolerance = now.AddSeconds(5);
        var matching = events
            .Where(item => item.Timestamp > start && item.Timestamp <= futureTolerance)
            .ToArray();
        var input = matching.Sum(item => item.Usage.InputTokens);
        var cached = matching.Sum(item => item.Usage.CachedInputTokens);
        var output = matching.Sum(item => item.Usage.OutputTokens);
        var reasoning = matching.Sum(item => item.Usage.ReasoningOutputTokens);
        var total = matching.Sum(item => item.Usage.TotalTokens);

        return new WindowMetrics(
            seconds,
            matching.Length,
            matching.Length * 60d / seconds,
            total / (double)seconds,
            input / (double)seconds,
            cached / (double)seconds,
            output / (double)seconds,
            reasoning / (double)seconds,
            input > 0 ? cached / (double)input : 0,
            total);
    }
}
