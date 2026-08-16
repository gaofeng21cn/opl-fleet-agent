using OPLFleetAgent.WindowsApp;

namespace OPLFleetAgent.Windows.Tests;

public sealed class StartupRegistrationTests
{
    [Fact]
    public void VisibleStartupNameUsesFleetBrand()
    {
        Assert.Equal("OPL Fleet Agent", StartupRegistration.ValueName);
    }
}
