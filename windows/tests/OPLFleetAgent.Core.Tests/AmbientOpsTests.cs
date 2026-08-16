using System.Text;
using System.Text.Json;
using OPLFleetAgent.Core;

namespace OPLFleetAgent.Core.Tests;

public sealed class AmbientOpsTests
{
    [Fact]
    public void UsesCurrentGatewayProductName()
    {
        Assert.Equal("OPL Fleet Gateway", OplFleetAgentProtocol.GatewayProductName);
        Assert.Equal("Fleet Gateway", OplFleetAgentProtocol.GatewayShortName);
    }

    [Fact]
    public void ParsesDiscoveryContractAndSelectsPreferredFallback()
    {
        var preferred = AmbientOpsDiscoveryContract.CreateService(
            "Preferred",
            "preferred.local.",
            8791,
            new Dictionary<string, string>
            {
                ["id"] = "preferred",
                ["name"] = "Preferred Ops",
                ["path"] = "/display/pet",
                ["protocol"] = "1",
            });
        var other = AmbientOpsDiscoveryContract.CreateService(
            "Other",
            "other.local.",
            8791,
            new Dictionary<string, string>
            {
                ["id"] = "other",
                ["protocol"] = "1",
            });
        var selector = new AmbientOpsServiceSelector("preferred");

        Assert.Equal(preferred, selector.Select([other!, preferred!]));
        selector.RecordPushFailure(preferred!);
        Assert.Equal(other, selector.Select([preferred!, other!]));
        Assert.Equal("/display/pet", preferred!.DisplayPath);
        Assert.False(preferred.SupportsPairing);
        Assert.True(AmbientOpsDiscoveryContract.CreateService(
            "Pairing",
            "pairing.local",
            8791,
            new Dictionary<string, string>
            {
                ["protocol"] = "1",
                ["pairing"] = "1",
            })!.SupportsPairing);
        Assert.Null(AmbientOpsDiscoveryContract.CreateService(
            "Future",
            "future.local",
            8791,
            new Dictionary<string, string> { ["protocol"] = "2" }));
    }

    [Fact]
    public void SerializesOnlyAggregatePayloadFields()
    {
        var identity = new AmbientOpsMachineIdentity("windows-pc", "Windows PC", "Windows");
        var payload = AmbientOpsAgentSnapshot.FromUsage(Usage(), identity);
        var json = JsonSerializer.Serialize(payload, AmbientOpsPushClient.SerializerOptions);
        using var document = JsonDocument.Parse(json);
        var keys = document.RootElement.EnumerateObject().Select(item => item.Name).ToHashSet();

        Assert.Equal(
            new HashSet<string>
            {
                "schemaVersion", "machineName", "platform", "generatedAt", "status",
                "oneMinute", "fiveMinutes", "activeSessions", "oplFleet",
            },
            keys);
        Assert.DoesNotContain("prompt", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("response", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("sessionId", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("sessionsRoot", json, StringComparison.OrdinalIgnoreCase);
        Assert.Equal(3, payload.SchemaVersion);
        Assert.Equal("OPL Fleet Agent", payload.OplFleet!.Product);
        Assert.Equal("windows-pc", payload.OplFleet.StableNodeId);
        Assert.Equal("node_agent", payload.OplFleet.Authority);
        var envelope = document.RootElement.GetProperty("oplFleet");
        Assert.Equal("windows-pc", envelope.GetProperty("stableNodeID").GetString());
        Assert.False(envelope.TryGetProperty("stableNodeId", out _));
    }

    [Fact]
    public void SerializesOnlyAggregateHostNetworkTelemetryWhenSampled()
    {
        var identity = new AmbientOpsMachineIdentity("windows-pc", "Windows PC", "Windows");
        var sampledAt = new DateTimeOffset(2026, 8, 1, 8, 0, 0, TimeSpan.Zero);
        var payload = AmbientOpsAgentSnapshot.FromUsage(
            Usage(),
            identity,
            network: new HostNetworkTelemetry(123.5, 12.25, sampledAt));
        var json = JsonSerializer.Serialize(payload, AmbientOpsPushClient.SerializerOptions);
        using var document = JsonDocument.Parse(json);
        var network = document.RootElement.GetProperty("network");

        Assert.Equal(123.5, network.GetProperty("downloadMbps").GetDouble());
        Assert.Equal(12.25, network.GetProperty("uploadMbps").GetDouble());
        Assert.Equal(sampledAt, network.GetProperty("sampledAt").GetDateTimeOffset());
        Assert.False(network.TryGetProperty("interface", out _));
        Assert.False(network.TryGetProperty("address", out _));
    }

    [Fact]
    public void IncludesHostCpuInAggregatePayload()
    {
        var identity = new AmbientOpsMachineIdentity("windows-pc", "Windows PC", "Windows");
        var payload = AmbientOpsAgentSnapshot.FromUsage(Usage(), identity, cpuPercent: 37.5);
        var json = JsonSerializer.Serialize(payload, AmbientOpsPushClient.SerializerOptions);
        using var document = JsonDocument.Parse(json);

        Assert.Equal(37.5, payload.CpuPercent);
        Assert.Equal(37.5, document.RootElement.GetProperty("cpuPercent").GetDouble());
    }

    [Fact]
    public async Task BuildsAuthenticatedRequestWithoutConversationContent()
    {
        var identity = new AmbientOpsMachineIdentity("windows-pc", "Windows PC", "Windows");
        var request = new AmbientOpsPushClient().CreateRequest(
            new Uri("https://ops.example.test/base"),
            "test-token",
            identity,
            AmbientOpsAgentSnapshot.FromUsage(Usage(), identity));
        var body = await request.Content!.ReadAsStringAsync();

        Assert.Equal(
            "https://ops.example.test/base/api/v1/agents/windows-pc/snapshot",
            request.RequestUri!.AbsoluteUri);
        Assert.Equal("Bearer", request.Headers.Authorization!.Scheme);
        Assert.Equal("test-token", request.Headers.Authorization.Parameter);
        Assert.DoesNotContain("prompt", body, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("response", body, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void EncodesPetStateWithAmbientOpsWireCasing()
    {
        var identity = new AmbientOpsMachineIdentity("windows-pc", "Windows PC", "Windows");
        var usage = Usage();
        var pet = new AmbientOpsPetTracker().Snapshot(AmbientOpsPetDefinition.LedgerOwl, usage);
        var payload = AmbientOpsAgentSnapshot.FromUsage(usage, identity, pet: pet);
        var json = JsonSerializer.Serialize(payload, AmbientOpsPushClient.SerializerOptions);

        Assert.Contains("\"state\":\"running\"", json, StringComparison.Ordinal);
        Assert.DoesNotContain("prompt", json, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task UploadsOnlyPetAssetRequestedBySnapshotResponse()
    {
        var temporary = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        try
        {
            PetAssetTests.WritePetForUpload(temporary);
            var asset = Assert.IsType<AmbientOpsPetAsset>(
                new AmbientOpsPetAssetCatalog(temporary).CurrentAsset());
            var handler = new PetUploadHandler(asset.Definition.AssetHash);
            var client = new AmbientOpsPushClient(new HttpClient(handler));
            var identity = new AmbientOpsMachineIdentity("windows-pc", "Windows PC", "Windows");
            var usage = Usage();
            var pet = new AmbientOpsPetTracker().Snapshot(asset.Definition, usage);

            await client.PushAsync(
                new Uri("https://ops.example.test/base"),
                "test-token",
                identity,
                AmbientOpsAgentSnapshot.FromUsage(usage, identity, pet: pet),
                asset);

            Assert.Equal(2, handler.Requests.Count);
            Assert.Equal(HttpMethod.Put, handler.Requests[1].Method);
            Assert.Equal(
                $"https://ops.example.test/base/api/v1/agents/windows-pc/pets/{asset.Definition.AssetHash}",
                handler.Requests[1].Url);
            Assert.Equal("Bearer test-token", handler.Requests[1].Authorization);
            Assert.Equal("image/webp", handler.Requests[1].ContentType);
            Assert.Equal(asset.Data.ToArray(), handler.Requests[1].Body);
        }
        finally
        {
            Directory.Delete(temporary, recursive: true);
        }
    }

    [Fact]
    public async Task DoesNotUploadForeignMissingHash()
    {
        var handler = new PetUploadHandler(new string('a', 64));
        var client = new AmbientOpsPushClient(new HttpClient(handler));
        var identity = new AmbientOpsMachineIdentity("windows-pc", "Windows PC", "Windows");

        await client.PushAsync(
            new Uri("https://ops.example.test"),
            "test-token",
            identity,
            AmbientOpsAgentSnapshot.FromUsage(Usage(), identity));

        Assert.Single(handler.Requests);
    }

    [Fact]
    public async Task RetriesSnapshotOnceAfterUploadManifestConflict()
    {
        var temporary = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        try
        {
            PetAssetTests.WritePetForUpload(temporary);
            var asset = Assert.IsType<AmbientOpsPetAsset>(
                new AmbientOpsPetAssetCatalog(temporary).CurrentAsset());
            var handler = new PetUploadHandler(asset.Definition.AssetHash, conflictOnce: true);
            var client = new AmbientOpsPushClient(new HttpClient(handler));
            var identity = new AmbientOpsMachineIdentity("windows-pc", "Windows PC", "Windows");

            await client.PushAsync(
                new Uri("https://ops.example.test"),
                "test-token",
                identity,
                AmbientOpsAgentSnapshot.FromUsage(Usage(), identity),
                asset);

            Assert.Equal(
                [HttpMethod.Post, HttpMethod.Put, HttpMethod.Post, HttpMethod.Put],
                handler.Requests.Select(item => item.Method));
        }
        finally
        {
            Directory.Delete(temporary, recursive: true);
        }
    }

    [Fact]
    public async Task BuildsPairingAndSignedRequestsWithoutASharedToken()
    {
        using var deviceKey = AmbientOpsDeviceKey.Create();
        var identity = new AmbientOpsMachineIdentity("windows-pc", "Windows PC", "Windows");
        var pairing = new AmbientOpsPairingClient().CreatePairingRequest(
            new Uri("http://ambient-ops.local:8787"),
            identity,
            deviceKey);
        var pairingBody = await pairing.Content!.ReadAsStringAsync();

        Assert.Null(pairing.Headers.Authorization);
        Assert.Contains("\"publicKey\":", pairingBody, StringComparison.Ordinal);
        Assert.DoesNotContain("private", pairingBody, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("token", pairingBody, StringComparison.OrdinalIgnoreCase);
        Assert.Matches("^[0-9]{6}$", deviceKey.VerificationCode);

        var snapshot = AmbientOpsAgentSnapshot.FromUsage(Usage(), identity);
        var signed = new AmbientOpsPushClient().CreateSignedRequest(
            new Uri("http://ambient-ops.local:8787"),
            deviceKey,
            identity,
            snapshot,
            DateTimeOffset.FromUnixTimeSeconds(1_000),
            "abcdefghijklmnop");
        var signedBody = await signed.Content!.ReadAsByteArrayAsync();

        Assert.Equal("AmbientKey", signed.Headers.Authorization!.Scheme);
        Assert.Equal("windows-pc", signed.Headers.Authorization.Parameter);
        Assert.Equal("1000", signed.Headers.GetValues("X-Ambient-Timestamp").Single());
        Assert.Equal("abcdefghijklmnop", signed.Headers.GetValues("X-Ambient-Nonce").Single());
        Assert.NotEmpty(signed.Headers.GetValues("X-Ambient-Signature").Single());
        Assert.DoesNotContain("prompt", Encoding.UTF8.GetString(signedBody), StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task SignedPushUploadsOnlyTheRequestedPetAsset()
    {
        var temporary = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        try
        {
            PetAssetTests.WritePetForUpload(temporary);
            var asset = Assert.IsType<AmbientOpsPetAsset>(
                new AmbientOpsPetAssetCatalog(temporary).CurrentAsset());
            var handler = new PetUploadHandler(asset.Definition.AssetHash);
            var client = new AmbientOpsPushClient(new HttpClient(handler));
            var identity = new AmbientOpsMachineIdentity("windows-pc", "Windows PC", "Windows");
            var usage = Usage();
            var pet = new AmbientOpsPetTracker().Snapshot(asset.Definition, usage);
            using var deviceKey = AmbientOpsDeviceKey.Create();

            await client.PushSignedAsync(
                new Uri("https://ops.example.test/base"),
                deviceKey,
                identity,
                AmbientOpsAgentSnapshot.FromUsage(usage, identity, pet: pet),
                asset);

            Assert.Equal(2, handler.Requests.Count);
            Assert.Equal([HttpMethod.Post, HttpMethod.Put], handler.Requests.Select(item => item.Method));
            Assert.All(handler.Requests, request => Assert.Equal("AmbientKey windows-pc", request.Authorization));
            Assert.All(handler.Requests, request => Assert.False(string.IsNullOrWhiteSpace(request.Signature)));
            Assert.Equal("image/webp", handler.Requests[1].ContentType);
            Assert.Equal(asset.Data.ToArray(), handler.Requests[1].Body);
        }
        finally
        {
            Directory.Delete(temporary, recursive: true);
        }
    }

    [Fact]
    public void ExportsAndImportsTheSameDeviceKey()
    {
        using var original = AmbientOpsDeviceKey.Create();
        var privateKey = original.ExportPrivateKey();
        using var imported = AmbientOpsDeviceKey.Import(privateKey);

        Assert.Equal(original.PublicKey, imported.PublicKey);
        Assert.Equal(original.VerificationCode, imported.VerificationCode);
    }

    private static UsageSnapshot Usage()
    {
        var oneMinute = new WindowMetrics(60, 2, 2, 10, 8, 5, 2, 1, 0.625, 600);
        return new UsageSnapshot(
            DateTimeOffset.FromUnixTimeSeconds(1_000),
            oneMinute,
            WindowMetrics.Empty(300),
            WindowMetrics.Empty(1_800),
            WindowMetrics.Empty(3_600),
            3,
            0,
            CollectionStatus.Ready);
    }

    private sealed record RecordedRequest(
        HttpMethod Method,
        string Url,
        string? Authorization,
        string? ContentType,
        string? Signature,
        byte[] Body);

    private sealed class PetUploadHandler(
        string missingHash,
        bool conflictOnce = false) : HttpMessageHandler
    {
        public List<RecordedRequest> Requests { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            var body = request.Content is null
                ? []
                : await request.Content.ReadAsByteArrayAsync(cancellationToken);
            Requests.Add(new RecordedRequest(
                request.Method,
                request.RequestUri!.AbsoluteUri,
                request.Headers.Authorization?.ToString(),
                request.Content?.Headers.ContentType?.MediaType,
                request.Headers.TryGetValues("X-Ambient-Signature", out var signatures)
                    ? signatures.Single()
                    : null,
                body));

            return request.Method == HttpMethod.Put
                ? new HttpResponseMessage(
                    conflictOnce && Requests.Count == 2
                        ? System.Net.HttpStatusCode.Conflict
                        : System.Net.HttpStatusCode.Created)
                : new HttpResponseMessage(System.Net.HttpStatusCode.Accepted)
                {
                    Content = new StringContent(
                        $$"""{"accepted":true,"missingPetAssets":["{{missingHash}}"]}"""),
                };
        }
    }
}
