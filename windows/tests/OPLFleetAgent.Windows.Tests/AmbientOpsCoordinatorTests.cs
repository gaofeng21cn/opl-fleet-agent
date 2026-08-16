using OPLFleetAgent.Core;
using OPLFleetAgent.WindowsApp;

namespace OPLFleetAgent.Windows.Tests;

public sealed class AmbientOpsCoordinatorTests
{
    private static readonly AmbientOpsService LegacyService = new(
        "ao-test",
        "Gaofeng Home",
        new Uri("http://192.168.1.170:8787"),
        "/display/pet",
        SupportsPairing: false);

    [Fact]
    public void SamplesHostNetworkAtFourHertzWithoutChangingPushCadence()
    {
        Assert.Equal(TimeSpan.FromMilliseconds(250), AmbientOpsCoordinator.HostNetworkSampleInterval);
    }

    [Fact]
    public void RefreshesLegacyCapabilityAfterCacheIntervalWithoutToken()
    {
        var discoveredAt = new DateTimeOffset(2026, 7, 26, 9, 0, 0, TimeSpan.Zero);

        Assert.True(AmbientOpsCoordinator.ShouldRefreshPairingCapability(
            string.Empty,
            LegacyService,
            discoveredAt,
            discoveredAt + AmbientOpsCoordinator.PairingCapabilityRefreshInterval));
    }

    [Fact]
    public void KeepsFreshCapabilityCache()
    {
        var discoveredAt = new DateTimeOffset(2026, 7, 26, 9, 0, 0, TimeSpan.Zero);

        Assert.False(AmbientOpsCoordinator.ShouldRefreshPairingCapability(
            string.Empty,
            LegacyService,
            discoveredAt,
            discoveredAt + TimeSpan.FromSeconds(29)));
    }

    [Fact]
    public void TokenOrPairingSupportDoesNotTriggerCapabilityRefresh()
    {
        var discoveredAt = new DateTimeOffset(2026, 7, 26, 9, 0, 0, TimeSpan.Zero);
        var pairingService = LegacyService with { SupportsPairing = true };
        var afterInterval = discoveredAt + TimeSpan.FromMinutes(1);

        Assert.False(AmbientOpsCoordinator.ShouldRefreshPairingCapability(
            "configured",
            LegacyService,
            discoveredAt,
            afterInterval));
        Assert.False(AmbientOpsCoordinator.ShouldRefreshPairingCapability(
            string.Empty,
            pairingService,
            discoveredAt,
            afterInterval));
    }
}
