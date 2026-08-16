using OPLFleetAgent.Core;

namespace OPLFleetAgent.Core.Tests;

public sealed class UsageMetricsTests
{
    [Fact]
    public void UsesFixedWindowDenominators()
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(1_000);
        var recent = Event(now.AddSeconds(-30), 600, 500, 400, 100);
        var older = Event(now.AddSeconds(-120), 1_500, 1_200, 800, 300);

        var snapshot = UsageMetrics.Snapshot([recent, older], now, 2, 0);

        Assert.Equal(10, snapshot.OneMinute.TokensPerSecond, 3);
        Assert.Equal(1, snapshot.OneMinute.RequestsPerMinute, 3);
        Assert.Equal(0.8, snapshot.OneMinute.CacheRatio, 3);
        Assert.Equal(7, snapshot.FiveMinutes.TokensPerSecond, 3);
        Assert.Equal(0.4, snapshot.FiveMinutes.RequestsPerMinute, 3);
        Assert.Equal(7d / 6, snapshot.ThirtyMinutes.TokensPerSecond, 3);
        Assert.Equal(7d / 12, snapshot.OneHour.TokensPerSecond, 3);
        Assert.Equal(2, snapshot.ActiveSessions);
    }

    private static UsageEvent Event(
        DateTimeOffset date,
        long total,
        long input,
        long cached,
        long output) =>
        new(
            date,
            new TokenUsage(input, cached, output, totalTokens: total),
            Guid.NewGuid().ToString(),
            Guid.NewGuid().ToString());
}
