using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;

namespace CodexTPS.WindowsApp;

internal enum AppUpdateKind
{
    Idle,
    Checking,
    UpToDate,
    Available,
    Installing,
    Restarting,
    Failed,
}

internal sealed record AppUpdateState(
    AppUpdateKind Kind,
    AppRelease? Release = null,
    string? Message = null)
{
    public static AppUpdateState Idle { get; } = new(AppUpdateKind.Idle);

    public bool IsBusy => Kind is
        AppUpdateKind.Checking or
        AppUpdateKind.Installing or
        AppUpdateKind.Restarting;
}

internal sealed record AppRelease(
    string TagName,
    SemanticVersion Version,
    Uri InstallerUri,
    Uri ChecksumUri);

internal readonly record struct SemanticVersion(int Major, int Minor, int Patch)
    : IComparable<SemanticVersion>
{
    public static bool TryParse(string? value, out SemanticVersion version)
    {
        version = default;
        if (string.IsNullOrWhiteSpace(value))
        {
            return false;
        }

        var normalized = value.Trim();
        if (normalized.StartsWith('v') || normalized.StartsWith('V'))
        {
            normalized = normalized[1..];
        }

        var components = normalized.Split('.');
        if (components.Length != 3 ||
            !int.TryParse(components[0], NumberStyles.None, CultureInfo.InvariantCulture, out var major) ||
            !int.TryParse(components[1], NumberStyles.None, CultureInfo.InvariantCulture, out var minor) ||
            !int.TryParse(components[2], NumberStyles.None, CultureInfo.InvariantCulture, out var patch) ||
            major < 0 ||
            minor < 0 ||
            patch < 0)
        {
            return false;
        }

        version = new SemanticVersion(major, minor, patch);
        return true;
    }

    public int CompareTo(SemanticVersion other)
    {
        var major = Major.CompareTo(other.Major);
        if (major != 0)
        {
            return major;
        }

        var minor = Minor.CompareTo(other.Minor);
        return minor != 0 ? minor : Patch.CompareTo(other.Patch);
    }

    public override string ToString() => $"{Major}.{Minor}.{Patch}";

    public static bool operator >(SemanticVersion left, SemanticVersion right) =>
        left.CompareTo(right) > 0;

    public static bool operator <(SemanticVersion left, SemanticVersion right) =>
        left.CompareTo(right) < 0;
}

internal static class GitHubReleaseParser
{
    private static readonly string[] AllowedRepositories =
    [
        "opl-fleet-agent",
        "codex-tps",
    ];

    public static AppRelease Parse(string json)
    {
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        if (!root.TryGetProperty("tag_name", out var tagElement) ||
            tagElement.GetString() is not { } tagName ||
            !SemanticVersion.TryParse(tagName, out var version) ||
            !root.TryGetProperty("assets", out var assets) ||
            assets.ValueKind != JsonValueKind.Array)
        {
            throw new InvalidDataException("GitHub 返回了无效的版本信息。");
        }

        Uri? canonicalInstallerUri = null;
        Uri? legacyInstallerUri = null;
        Uri? canonicalChecksumUri = null;
        Uri? legacyChecksumUri = null;
        foreach (var asset in assets.EnumerateArray())
        {
            if (!asset.TryGetProperty("name", out var nameElement) ||
                !asset.TryGetProperty("browser_download_url", out var urlElement) ||
                nameElement.GetString() is not { } name ||
                urlElement.GetString() is not { } url ||
                !Uri.TryCreate(url, UriKind.Absolute, out var uri))
            {
                continue;
            }

            if (name == WindowsProductIdentity.InstallerAssetName &&
                IsAllowedAsset(uri, tagName, name))
            {
                canonicalInstallerUri = uri;
            }
            else if (name == WindowsProductIdentity.LegacyInstallerAssetName &&
                IsAllowedAsset(uri, tagName, name))
            {
                legacyInstallerUri = uri;
            }
            else if (name == WindowsProductIdentity.InstallerAssetName + ".sha256" &&
                IsAllowedAsset(uri, tagName, name))
            {
                canonicalChecksumUri = uri;
            }
            else if (name == WindowsProductIdentity.LegacyInstallerAssetName + ".sha256" &&
                IsAllowedAsset(uri, tagName, name))
            {
                legacyChecksumUri = uri;
            }
        }

        var installerUri = canonicalInstallerUri is not null && canonicalChecksumUri is not null
            ? canonicalInstallerUri
            : legacyInstallerUri;
        var checksumUri = canonicalInstallerUri is not null && canonicalChecksumUri is not null
            ? canonicalChecksumUri
            : legacyInstallerUri is not null && legacyChecksumUri is not null
                ? legacyChecksumUri
                : null;
        if (installerUri is null || checksumUri is null)
        {
            throw new InvalidDataException("最新版缺少 Windows 安装包或校验文件。");
        }

        return new AppRelease(tagName, version, installerUri, checksumUri);
    }

    private static bool IsAllowedAsset(Uri uri, string tagName, string fileName)
    {
        if (uri.Scheme != Uri.UriSchemeHttps ||
            !string.Equals(uri.Host, "github.com", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        return AllowedRepositories.Any(repository => string.Equals(
            uri.AbsolutePath,
            $"/gaofeng21cn/{repository}/releases/download/{tagName}/{fileName}",
            StringComparison.Ordinal));
    }
}

internal static class UpdatePackageVerifier
{
    public static string ParseExpectedSha256(string content, string expectedFileName)
    {
        foreach (var rawLine in content.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            var line = rawLine.Trim();
            var separator = line.IndexOfAny([' ', '\t']);
            if (separator <= 0)
            {
                continue;
            }

            var hash = line[..separator].Trim().ToLowerInvariant();
            var fileName = line[separator..].Trim().TrimStart('*');
            if (!string.Equals(fileName, expectedFileName, StringComparison.Ordinal) ||
                hash.Length != 64 ||
                !hash.All(Uri.IsHexDigit))
            {
                continue;
            }

            return hash;
        }

        throw new InvalidDataException("更新校验文件无效。");
    }

    public static async Task<string> ComputeSha256Async(
        string path,
        CancellationToken cancellationToken = default)
    {
        await using var stream = File.OpenRead(path);
        var digest = await SHA256.HashDataAsync(stream, cancellationToken);
        return Convert.ToHexString(digest).ToLowerInvariant();
    }

    public static async Task VerifyAsync(
        string path,
        string expectedSha256,
        CancellationToken cancellationToken = default)
    {
        var actual = await ComputeSha256Async(path, cancellationToken);
        var expectedBytes = Convert.FromHexString(expectedSha256);
        var actualBytes = Convert.FromHexString(actual);
        if (!CryptographicOperations.FixedTimeEquals(expectedBytes, actualBytes))
        {
            throw new InvalidDataException("Windows 安装包 SHA-256 校验失败。");
        }
    }
}
