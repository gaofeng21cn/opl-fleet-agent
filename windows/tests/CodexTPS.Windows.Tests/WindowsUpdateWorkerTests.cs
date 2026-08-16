using CodexTPS.WindowsApp;

namespace CodexTPS.Windows.Tests;

public sealed class WindowsUpdateWorkerTests
{
    [Fact]
    public void UpdateRequestRoundTripsWithoutLosingTransactionIdentity()
    {
        var directory = Directory.CreateTempSubdirectory("codex-tps-worker-test-");
        try
        {
            var path = Path.Combine(directory.FullName, "request.json");
            var request = new UpdateWorkerRequest
            {
                ParentProcessId = 123,
                CurrentExecutablePath = @"C:\Program Files\OPL Fleet Agent\OPLFleetAgent.exe",
                InstallDirectory = @"C:\Program Files\OPL Fleet Agent",
                InstallerPath = @"C:\Temp\OPL-Fleet-Agent-Windows-win-x64-Setup.exe",
                ExpectedSha256 = new string('a', 64),
                ExpectedVersion = "0.2.20",
                ResultPath = @"C:\Temp\result.json",
                StagingDirectory = @"C:\Temp\opl-fleet-agent-update",
            };

            request.Save(path);
            var restored = UpdateWorkerRequest.Load(path);

            Assert.Equal(request.ParentProcessId, restored.ParentProcessId);
            Assert.Equal(request.ExpectedSha256, restored.ExpectedSha256);
            Assert.Equal(request.ExpectedVersion, restored.ExpectedVersion);
            Assert.Equal(request.InstallerPath, restored.InstallerPath);
        }
        finally
        {
            directory.Delete(recursive: true);
        }
    }

    [Fact]
    public void UpdateResultIsConsumedOnlyOnce()
    {
        var directory = Directory.CreateTempSubdirectory("codex-tps-result-test-");
        try
        {
            var path = Path.Combine(directory.FullName, "result.json");
            UpdateResultStore.Write(path, new UpdateResult
            {
                Success = true,
                Version = "0.2.20",
            });

            var first = UpdateResultStore.ReadAndDelete(path);
            var second = UpdateResultStore.ReadAndDelete(path);

            Assert.True(first?.Success);
            Assert.Equal("0.2.20", first?.Version);
            Assert.Null(second);
        }
        finally
        {
            directory.Delete(recursive: true);
        }
    }

    [Fact]
    public void NormalLaunchArgumentsDoNotEnterWorkerMode()
    {
        Assert.False(WindowsUpdateWorker.TryRun(["--background"], out var exitCode));
        Assert.Equal(0, exitCode);
    }
}
