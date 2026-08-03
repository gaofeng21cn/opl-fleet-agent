using System.Diagnostics;

namespace CodexTPS.WindowsApp;

internal static class LegacyExecutableBridge
{
    public const string CleanupArgument = "--cleanup-legacy";
    private const int HandoffGracePeriodMilliseconds = 3_000;

    public static bool TryRun(string[] args)
    {
        if (TryRunCleanup(args))
        {
            return true;
        }

        var currentPath = Environment.ProcessPath;
        if (string.IsNullOrWhiteSpace(currentPath) ||
            !WindowsProductIdentity.IsLegacyExecutable(currentPath))
        {
            return false;
        }

        var canonicalPath = WindowsProductIdentity.FindCanonicalExecutable(currentPath);
        if (canonicalPath is null)
        {
            return false;
        }

        var child = StartCanonical(canonicalPath, args);
        StartCleanupWorker(canonicalPath, currentPath);

        // Keep the bridge alive just long enough for the old updater to observe
        // a successful handoff. The canonical process owns the app lifetime;
        // waiting for it here would prevent the cleanup worker from deleting
        // this one-time compatibility executable.
        _ = child;
        Thread.Sleep(HandoffGracePeriodMilliseconds);

        return true;
    }

    public static void RemoveLegacySibling()
    {
        var currentPath = Environment.ProcessPath;
        if (string.IsNullOrWhiteSpace(currentPath) ||
            WindowsProductIdentity.IsLegacyExecutable(currentPath))
        {
            return;
        }

        var legacyPath = Path.Combine(
            Path.GetDirectoryName(currentPath) ?? string.Empty,
            WindowsProductIdentity.LegacyExecutableName);
        try
        {
            if (File.Exists(legacyPath))
            {
                File.Delete(legacyPath);
            }
        }
        catch
        {
            // The bridge is best effort; the next canonical launch retries cleanup.
        }
    }

    private static bool TryRunCleanup(string[] args)
    {
        if (args.Length != 3 ||
            !string.Equals(args[0], CleanupArgument, StringComparison.OrdinalIgnoreCase) ||
            !int.TryParse(args[1], out var parentProcessId) ||
            !Path.IsPathFullyQualified(args[2]))
        {
            return false;
        }

        try
        {
            using var parent = Process.GetProcessById(parentProcessId);
            parent.WaitForExit((int)TimeSpan.FromSeconds(30).TotalMilliseconds);
        }
        catch (ArgumentException)
        {
            // The bridge exited before the cleanup worker attached.
        }

        try
        {
            File.Delete(args[2]);
        }
        catch
        {
            // A locked or already removed bridge needs no further action.
        }

        return true;
    }

    private static Process? StartCanonical(string canonicalPath, string[] args)
    {
        var startInfo = new ProcessStartInfo(canonicalPath)
        {
            UseShellExecute = true,
        };
        foreach (var argument in args)
        {
            startInfo.ArgumentList.Add(argument);
        }
        return Process.Start(startInfo);
    }

    private static void StartCleanupWorker(string canonicalPath, string legacyPath)
    {
        try
        {
            _ = Process.Start(new ProcessStartInfo(canonicalPath)
            {
                UseShellExecute = false,
                ArgumentList =
                {
                    CleanupArgument,
                    Environment.ProcessId.ToString(),
                    legacyPath,
                },
            });
        }
        catch
        {
            // Cleanup is retried by the canonical process on its next launch.
        }
    }
}
