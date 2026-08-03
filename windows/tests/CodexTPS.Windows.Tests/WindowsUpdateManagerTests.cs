using System.Net;
using CodexTPS.WindowsApp;

namespace CodexTPS.Windows.Tests;

public sealed class WindowsUpdateManagerTests
{
    [Fact]
    public async Task FindsNewerReleaseAndKeepsItAvailable()
    {
        using var fixture = new UpdateManagerFixture(
            HttpStatusCode.OK,
            "v0.2.20",
            new SemanticVersion(0, 2, 19));

        await fixture.Manager.CheckForUpdatesAsync();

        Assert.Equal(AppUpdateKind.Available, fixture.Manager.State.Kind);
        Assert.Equal("v0.2.20", fixture.Manager.State.Release?.TagName);
        Assert.Equal(HttpMethod.Head, fixture.Handler.LastMethod);
        Assert.Equal(
            "https://github.com/gaofeng21cn/opl-fleet-agent/releases/latest",
            fixture.Handler.LastUri?.AbsoluteUri);
    }

    [Fact]
    public async Task ReportsUpToDateForSameRelease()
    {
        using var fixture = new UpdateManagerFixture(
            HttpStatusCode.OK,
            "v0.2.20",
            new SemanticVersion(0, 2, 20));

        await fixture.Manager.CheckForUpdatesAsync();

        Assert.Equal(AppUpdateKind.UpToDate, fixture.Manager.State.Kind);
        Assert.Equal("已是最新版本", fixture.Manager.State.Message);
    }

    [Fact]
    public async Task ManualFailureIsVisibleButAutomaticFailureStaysQuiet()
    {
        using var manualFixture = new UpdateManagerFixture(
            HttpStatusCode.ServiceUnavailable,
            null,
            new SemanticVersion(0, 2, 19));
        await manualFixture.Manager.CheckForUpdatesAsync(manual: true);
        Assert.Equal(AppUpdateKind.Failed, manualFixture.Manager.State.Kind);

        using var automaticFixture = new UpdateManagerFixture(
            HttpStatusCode.ServiceUnavailable,
            null,
            new SemanticVersion(0, 2, 19));
        await automaticFixture.Manager.CheckForUpdatesAsync(manual: false);
        Assert.Equal(AppUpdateKind.Idle, automaticFixture.Manager.State.Kind);
    }

    private sealed class UpdateManagerFixture : IDisposable
    {
        private readonly DirectoryInfo directory = Directory.CreateTempSubdirectory(
            "codex-tps-update-manager-test-");
        private readonly HttpClient client;

        public UpdateManagerFixture(
            HttpStatusCode statusCode,
            string? releaseTag,
            SemanticVersion currentVersion)
        {
            Handler = new StubHandler(statusCode, releaseTag);
            client = new HttpClient(Handler);
            var executable = Path.Combine(directory.FullName, "OPLFleetAgent.exe");
            File.WriteAllText(executable, "test executable");
            Manager = new WindowsUpdateManager(
                client,
                currentVersion,
                executable,
                Path.Combine(directory.FullName, "updates"),
                Path.Combine(directory.FullName, "update-result.json"));
        }

        public WindowsUpdateManager Manager { get; }

        public StubHandler Handler { get; }

        public void Dispose()
        {
            Manager.Dispose();
            client.Dispose();
            directory.Delete(recursive: true);
        }
    }

    private sealed class StubHandler(HttpStatusCode statusCode, string? releaseTag)
        : HttpMessageHandler
    {
        public HttpMethod? LastMethod { get; private set; }

        public Uri? LastUri { get; private set; }

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            LastMethod = request.Method;
            LastUri = request.RequestUri;
            var finalUri = releaseTag is null
                ? request.RequestUri
                : new Uri(
                    $"https://github.com/gaofeng21cn/opl-fleet-agent/releases/tag/{releaseTag}");
            return Task.FromResult(new HttpResponseMessage(statusCode)
            {
                RequestMessage = new HttpRequestMessage(request.Method, finalUri),
            });
        }
    }
}
