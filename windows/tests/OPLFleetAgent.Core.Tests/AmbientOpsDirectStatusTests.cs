using OPLFleetAgent.Core;

namespace OPLFleetAgent.Core.Tests;

public sealed class AmbientOpsDirectStatusTests
{
    [Theory]
    [InlineData(0, 0, null, "quiet", 0, 0)]
    [InlineData(6_000, 4, 42.0, "active", 0.3428208823027626, 2)]
    [InlineData(60_000, 10, null, "heavy", 0.9533333333333334, 3)]
    [InlineData(60_000, 10, 97.0, "constrained", 0.9567333333333334, 3)]
    public void LoadVisualModelV1MatchesCrossPlatformContractVectors(
        double tps,
        double sessions,
        double? cpu,
        string expectedState,
        double expectedScore,
        int expectedClusters)
    {
        var visual = AmbientOpsLoadModel.VisualState(tps, sessions, cpu);

        Assert.Equal(1, AmbientOpsLoadModel.ModelVersion);
        Assert.Equal(1, visual.ModelVersion);
        Assert.Equal(expectedState, visual.State);
        Assert.Equal(expectedScore, visual.Score, 12);
        Assert.Equal(expectedClusters, visual.ClusterCount);
    }
}
