using CodexTPS.WindowsApp;

namespace CodexTPS.Windows.Tests;

public sealed class StartupRegistrationTests
{
    [Fact]
    public void VisibleStartupNameReplacesLegacyName()
    {
        Assert.Equal("OPL Fleet Agent", StartupRegistration.ValueName);
        Assert.Equal("Codex TPS", StartupRegistration.LegacyValueName);
    }
}
