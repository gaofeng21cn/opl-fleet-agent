using CodexTPS.WindowsApp;

namespace CodexTPS.Windows.Tests;

public sealed class StartupRegistrationTests
{
    [Fact]
    public void VisibleStartupNameUsesFleetBrand()
    {
        Assert.Equal("OPL Fleet Agent", StartupRegistration.ValueName);
    }
}
