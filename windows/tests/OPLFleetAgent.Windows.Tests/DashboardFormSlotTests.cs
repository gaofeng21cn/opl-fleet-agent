using OPLFleetAgent.WindowsApp;

namespace OPLFleetAgent.Windows.Tests;

public sealed class DashboardFormSlotTests
{
    [Fact]
    public void RecreatesDashboardAfterPreviousFormWasDisposed()
    {
        var created = 0;
        using var slot = new DashboardFormSlot(() =>
        {
            created++;
            return new DashboardForm(string.Empty);
        });

        var first = slot.Current;
        Assert.Same(first, slot.Current);

        first.Dispose();
        var replacement = slot.Current;

        Assert.NotSame(first, replacement);
        Assert.False(replacement.IsDisposed);
        Assert.Equal(2, created);
    }

    [Fact]
    public void DoesNotRecreateDashboardAfterSlotWasDisposed()
    {
        var slot = new DashboardFormSlot(() => new DashboardForm(string.Empty));
        _ = slot.Current;

        slot.Dispose();

        Assert.Throws<ObjectDisposedException>(() => slot.Current);
    }
}
