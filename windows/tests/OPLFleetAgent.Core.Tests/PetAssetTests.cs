using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using OPLFleetAgent.Core;

namespace OPLFleetAgent.Core.Tests;

public sealed class PetAssetTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));

    [Fact]
    public void DiscoversLocalPetAndCachesByMetadata()
    {
        var firstBytes = WebP("first");
        var spritesheet = WritePet(root, "build-fox", firstBytes);
        var originalDate = DateTime.UnixEpoch.AddSeconds(1_000);
        File.SetLastWriteTimeUtc(spritesheet, originalDate);
        var catalog = new AmbientOpsPetAssetCatalog(root);

        var first = Assert.IsType<AmbientOpsPetAsset>(catalog.CurrentAsset());
        Assert.Equal("build-fox", first.Definition.Id);
        Assert.Equal("Build Fox", first.Definition.DisplayName);
        Assert.Equal(2, first.Definition.SpriteVersionNumber);
        Assert.Equal(Sha256(firstBytes), first.Definition.AssetHash);

        var replacement = WebP("other");
        Assert.Equal(firstBytes.Length, replacement.Length);
        File.WriteAllBytes(spritesheet, replacement);
        File.SetLastWriteTimeUtc(spritesheet, originalDate);
        Assert.Equal(first.Definition.AssetHash, catalog.CurrentAsset()!.Definition.AssetHash);

        File.SetLastWriteTimeUtc(spritesheet, originalDate.AddSeconds(2));
        var updated = Assert.IsType<AmbientOpsPetAsset>(catalog.CurrentAsset());
        Assert.Equal(Sha256(replacement), updated.Definition.AssetHash);
        Assert.NotEqual(first.Definition.AssetHash, updated.Definition.AssetHash);
    }

    [Fact]
    public void RejectsEscapingManifestAndOversizedAsset()
    {
        WritePet(root, "unsafe", WebP("x"), "../secret.webp");
        Assert.Null(new AmbientOpsPetAssetCatalog(root).CurrentAsset());

        var otherRoot = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        try
        {
            WritePet(
                otherRoot,
                "too-large",
                new byte[AmbientOpsPetAssetCatalog.MaximumAssetBytes + 1]);
            Assert.Null(new AmbientOpsPetAssetCatalog(otherRoot).CurrentAsset());
        }
        finally
        {
            Directory.Delete(otherRoot, recursive: true);
        }
    }

    [Fact]
    public void PetManifestCannotAddConversationContentToSnapshot()
    {
        var directory = Path.Combine(root, "pets", "private-owl");
        Directory.CreateDirectory(directory);
        File.WriteAllText(
            Path.Combine(directory, "pet.json"),
            """
            {
              "id": "private-owl",
              "displayName": "Private Owl",
              "spriteVersionNumber": 1,
              "spritesheetPath": "spritesheet.webp",
              "prompt": "never transmit me",
              "response": "nor me",
              "sessionPath": "C:\\Users\\private\\.codex\\sessions"
            }
            """);
        File.WriteAllBytes(Path.Combine(directory, "spritesheet.webp"), WebP("safe"));

        var asset = Assert.IsType<AmbientOpsPetAsset>(
            new AmbientOpsPetAssetCatalog(root).CurrentAsset());
        var usage = UsageSnapshot.Empty(
            DateTimeOffset.FromUnixTimeSeconds(1_000),
            CollectionStatus.Ready);
        var pet = new AmbientOpsPetTracker().Snapshot(asset.Definition, usage);
        var identity = new AmbientOpsMachineIdentity("private-pc", "Private PC", "Windows");
        var json = System.Text.Json.JsonSerializer.Serialize(
            AmbientOpsAgentSnapshot.FromUsage(usage, identity, pet: pet),
            AmbientOpsPushClient.SerializerOptions);

        Assert.DoesNotContain("never transmit me", json, StringComparison.Ordinal);
        Assert.DoesNotContain("nor me", json, StringComparison.Ordinal);
        Assert.DoesNotContain(@"C:\Users", json, StringComparison.Ordinal);
        Assert.DoesNotContain("spritesheetPath", json, StringComparison.OrdinalIgnoreCase);
    }

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private static string WritePet(
        string codexHome,
        string id,
        byte[] spritesheet,
        string spritesheetPath = "spritesheet.webp")
    {
        var directory = Path.Combine(codexHome, "pets", id);
        Directory.CreateDirectory(directory);
        File.WriteAllText(
            Path.Combine(directory, "pet.json"),
            $$"""
            {
              "id": "{{id}}",
              "displayName": "{{(id == "build-fox" ? "Build Fox" : id)}}",
              "spriteVersionNumber": 2,
              "spritesheetPath": "{{spritesheetPath}}"
            }
            """);
        var path = Path.Combine(directory, "spritesheet.webp");
        File.WriteAllBytes(path, spritesheet);
        return path;
    }

    internal static void WritePetForUpload(string codexHome) =>
        WritePet(codexHome, "local-pet", WebP("pet pixels"));

    private static byte[] WebP(string payload)
    {
        var payloadBytes = Encoding.UTF8.GetBytes(payload);
        var data = new byte[12 + payloadBytes.Length];
        "RIFF"u8.CopyTo(data);
        BinaryPrimitives.WriteUInt32LittleEndian(data.AsSpan(4), (uint)payloadBytes.Length + 4);
        "WEBP"u8.CopyTo(data.AsSpan(8));
        payloadBytes.CopyTo(data.AsSpan(12));
        return data;
    }

    private static string Sha256(byte[] data) =>
        Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();
}
