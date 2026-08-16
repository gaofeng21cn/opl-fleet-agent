using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace OPLFleetAgent.Core;

public sealed record AmbientOpsPetAsset
{
    internal AmbientOpsPetAsset(AmbientOpsPetDefinition definition, byte[] data)
    {
        Definition = definition;
        Data = data;
    }

    public AmbientOpsPetDefinition Definition { get; }
    public ReadOnlyMemory<byte> Data { get; }
}

public sealed partial class AmbientOpsPetAssetCatalog
{
    public const int MaximumAssetBytes = 8 * 1_024 * 1_024;
    private const int MaximumManifestBytes = 64 * 1_024;

    private sealed record Manifest(
        string Id,
        string DisplayName,
        int SpriteVersionNumber,
        string SpritesheetPath);

    private sealed record FileMetadata(long Size, DateTime ModifiedAtUtc);
    private sealed record Fingerprint(FileMetadata Manifest, FileMetadata Spritesheet);
    private sealed record CachedAsset(string Directory, Fingerprint Fingerprint, AmbientOpsPetAsset Asset);

    private readonly string petsRoot;
    private readonly string? preferredPetId;
    private CachedAsset? cache;

    public AmbientOpsPetAssetCatalog(string codexHome, string? preferredPetId = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(codexHome);
        petsRoot = Path.Combine(Path.GetFullPath(codexHome), "pets");
        this.preferredPetId = preferredPetId?.Trim().ToLowerInvariant();
    }

    public AmbientOpsPetAsset? CurrentAsset()
    {
        foreach (var directory in CandidateDirectories())
        {
            var asset = LoadAsset(directory);
            if (asset is not null)
            {
                return asset;
            }
        }
        cache = null;
        return null;
    }

    private IEnumerable<string> CandidateDirectories()
    {
        if (preferredPetId is not null)
        {
            if (!PetIdPattern().IsMatch(preferredPetId))
            {
                return [];
            }
            var directory = Path.Combine(petsRoot, preferredPetId);
            return IsSafeDirectory(directory) ? [directory] : [];
        }

        try
        {
            return new DirectoryInfo(petsRoot)
                .EnumerateDirectories()
                .Where(directory => directory.LinkTarget is null)
                .OrderBy(directory => directory.Name, StringComparer.Ordinal)
                .Select(directory => directory.FullName)
                .ToArray();
        }
        catch (Exception error) when (
            error is DirectoryNotFoundException or IOException or UnauthorizedAccessException)
        {
            return [];
        }
    }

    private AmbientOpsPetAsset? LoadAsset(string directory)
    {
        try
        {
            var directoryId = Path.GetFileName(directory);
            if (!PetIdPattern().IsMatch(directoryId) || !IsSafeDirectory(directory))
            {
                return null;
            }

            var manifestPath = Path.Combine(directory, "pet.json");
            var spritesheetPath = Path.Combine(directory, "spritesheet.webp");
            var manifestMetadata = Metadata(manifestPath, MaximumManifestBytes);
            var spritesheetMetadata = Metadata(spritesheetPath, MaximumAssetBytes);
            if (manifestMetadata is null || spritesheetMetadata is null)
            {
                return null;
            }
            var fingerprint = new Fingerprint(manifestMetadata, spritesheetMetadata);
            if (cache is not null &&
                string.Equals(cache.Directory, directory, StringComparison.OrdinalIgnoreCase) &&
                cache.Fingerprint == fingerprint)
            {
                return cache.Asset;
            }

            var manifest = JsonSerializer.Deserialize<Manifest>(
                File.ReadAllBytes(manifestPath),
                new JsonSerializerOptions(JsonSerializerDefaults.Web));
            if (manifest is null ||
                !string.Equals(manifest.Id, directoryId, StringComparison.Ordinal) ||
                !string.Equals(manifest.SpritesheetPath, "spritesheet.webp", StringComparison.Ordinal))
            {
                return null;
            }

            var data = File.ReadAllBytes(spritesheetPath);
            if (!IsWebP(data))
            {
                return null;
            }
            var hash = Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();
            var definition = new AmbientOpsPetDefinition(
                manifest.Id,
                string.IsNullOrWhiteSpace(manifest.DisplayName) ? manifest.Id : manifest.DisplayName,
                Math.Max(1, manifest.SpriteVersionNumber),
                hash);
            var asset = new AmbientOpsPetAsset(definition, data);
            cache = new CachedAsset(directory, fingerprint, asset);
            return asset;
        }
        catch (Exception error) when (
            error is IOException or UnauthorizedAccessException or JsonException)
        {
            return null;
        }
    }

    private static bool IsSafeDirectory(string path)
    {
        var directory = new DirectoryInfo(path);
        return directory.Exists && directory.LinkTarget is null;
    }

    private static FileMetadata? Metadata(string path, long maximumBytes)
    {
        var file = new FileInfo(path);
        return file.Exists &&
            file.LinkTarget is null &&
            file.Length is > 0 &&
            file.Length <= maximumBytes
                ? new FileMetadata(file.Length, file.LastWriteTimeUtc)
                : null;
    }

    private static bool IsWebP(ReadOnlySpan<byte> data)
    {
        return data.Length >= 12 &&
            data[..4].SequenceEqual("RIFF"u8) &&
            data.Slice(8, 4).SequenceEqual("WEBP"u8) &&
            BinaryPrimitives.ReadUInt32LittleEndian(data.Slice(4, 4)) + 8UL == (ulong)data.Length;
    }

    [GeneratedRegex("^[a-z0-9][a-z0-9._-]{0,79}$", RegexOptions.CultureInvariant)]
    private static partial Regex PetIdPattern();
}
