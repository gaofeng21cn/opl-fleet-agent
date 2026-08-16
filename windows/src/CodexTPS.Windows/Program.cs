namespace CodexTPS.WindowsApp;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        if (WindowsUpdateWorker.TryRun(args, out var updateExitCode))
        {
            Environment.ExitCode = updateExitCode;
            return;
        }

        using var mutex = new Mutex(initiallyOwned: true, @"Local\OPLFleetAgent.Windows", out var created);
        if (!created)
        {
            MessageBox.Show(
                "OPL Fleet Agent is already running.",
                "OPL Fleet Agent",
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
            return;
        }

        ApplicationConfiguration.Initialize();
        var background = args.Contains("--background", StringComparer.OrdinalIgnoreCase);
        Application.Run(new TrayApplicationContext(showDashboard: !background));
    }
}
