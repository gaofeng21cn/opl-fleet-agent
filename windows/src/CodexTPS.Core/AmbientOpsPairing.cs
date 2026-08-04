using System.Buffers.Binary;
using System.Globalization;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace CodexTPS.Core;

public sealed class AmbientOpsDeviceKey : IDisposable
{
    private readonly ECDsa key;

    private AmbientOpsDeviceKey(ECDsa key)
    {
        this.key = key;
    }

    public string PublicKey => Convert.ToBase64String(key.ExportSubjectPublicKeyInfo());

    public string VerificationCode
    {
        get
        {
            var digest = SHA256.HashData(key.ExportSubjectPublicKeyInfo());
            return (BinaryPrimitives.ReadUInt32BigEndian(digest) % 1_000_000)
                .ToString("D6", CultureInfo.InvariantCulture);
        }
    }

    public static AmbientOpsDeviceKey Create() =>
        new(ECDsa.Create(ECCurve.NamedCurves.nistP256));

    public static AmbientOpsDeviceKey Import(string privateKey)
    {
        var encoded = Convert.FromBase64String(privateKey);
        var key = ECDsa.Create();
        try
        {
            key.ImportPkcs8PrivateKey(encoded, out var bytesRead);
            if (bytesRead != encoded.Length)
            {
                throw new CryptographicException("Device key contains trailing data.");
            }
            return new AmbientOpsDeviceKey(key);
        }
        catch
        {
            key.Dispose();
            throw;
        }
    }

    public string ExportPrivateKey() => Convert.ToBase64String(key.ExportPkcs8PrivateKey());

    public string Sign(
        string method,
        string path,
        string timestamp,
        string nonce,
        ReadOnlySpan<byte> body)
    {
        var bodyHash = Convert.ToHexString(SHA256.HashData(body)).ToLowerInvariant();
        var canonical = Encoding.UTF8.GetBytes(
            $"{method.ToUpperInvariant()}\n{path}\n{timestamp}\n{nonce}\n{bodyHash}");
        var signature = key.SignData(
            canonical,
            HashAlgorithmName.SHA256,
            DSASignatureFormat.Rfc3279DerSequence);
        return Convert.ToBase64String(signature);
    }

    public static string CreateNonce() =>
        Convert.ToBase64String(RandomNumberGenerator.GetBytes(18))
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');

    public void Dispose() => key.Dispose();
}

public sealed record AmbientOpsPairingSession(
    string RequestId,
    string MachineId,
    string MachineName,
    string Platform,
    string VerificationCode,
    string Status,
    bool Replacement,
    DateTimeOffset CreatedAt,
    DateTimeOffset ExpiresAt,
    DateTimeOffset? ApprovedAt,
    string ApprovalPath,
    int PollAfterSeconds)
{
    public bool IsApproved => Status == "approved";
    public bool IsPending => Status == "pending";
}

public sealed class AmbientOpsPairingClient
{
    private static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web);
    private readonly HttpClient httpClient;

    public AmbientOpsPairingClient(HttpClient? httpClient = null)
    {
        this.httpClient = httpClient ?? new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
    }

    public HttpRequestMessage CreatePairingRequest(
        Uri endpoint,
        AmbientOpsMachineIdentity identity,
        AmbientOpsDeviceKey deviceKey,
        string? bearerToken = null)
    {
        ValidateEndpoint(endpoint);
        var url = new Uri(endpoint.AbsoluteUri.TrimEnd('/') + "/api/v1/pairings");
        var body = JsonSerializer.Serialize(new
        {
            schemaVersion = 1,
            machineId = identity.MachineId,
            identity.MachineName,
            identity.Platform,
            publicKey = deviceKey.PublicKey,
        }, Options);
        var request = new HttpRequestMessage(HttpMethod.Post, url)
        {
            Content = new StringContent(body, Encoding.UTF8, "application/json"),
        };
        if (!string.IsNullOrWhiteSpace(bearerToken))
        {
            request.Headers.Authorization = new AuthenticationHeaderValue(
                "Bearer",
                bearerToken.Trim());
        }
        return request;
    }

    public async Task<AmbientOpsPairingSession> BeginAsync(
        Uri endpoint,
        AmbientOpsMachineIdentity identity,
        AmbientOpsDeviceKey deviceKey,
        string? bearerToken = null,
        CancellationToken cancellationToken = default)
    {
        using var request = CreatePairingRequest(endpoint, identity, deviceKey, bearerToken);
        return await SendAsync(request, expectedStatusCode: 202, cancellationToken)
            .ConfigureAwait(false);
    }

    public async Task<AmbientOpsPairingSession> GetAsync(
        Uri endpoint,
        string requestId,
        CancellationToken cancellationToken = default)
    {
        ValidateEndpoint(endpoint);
        if (requestId.Length is < 32 or > 80 ||
            requestId.Any(character => !char.IsAsciiLetterOrDigit(character) && character is not '_' and not '-'))
        {
            throw new ArgumentException("Invalid OPL Fleet Gateway pairing request ID.", nameof(requestId));
        }
        using var request = new HttpRequestMessage(
            HttpMethod.Get,
            new Uri(endpoint.AbsoluteUri.TrimEnd('/') + $"/api/v1/pairings/{requestId}"));
        return await SendAsync(request, expectedStatusCode: 200, cancellationToken)
            .ConfigureAwait(false);
    }

    public static Uri ApprovalUri(Uri endpoint, AmbientOpsPairingSession pairing)
    {
        ValidateEndpoint(endpoint);
        if (!pairing.ApprovalPath.StartsWith('/') ||
            pairing.ApprovalPath.StartsWith("//", StringComparison.Ordinal) ||
            pairing.ApprovalPath.Length > 160)
        {
            throw new InvalidOperationException("OPL Fleet Gateway returned an invalid approval path.");
        }
        return new Uri(endpoint, pairing.ApprovalPath);
    }

    private async Task<AmbientOpsPairingSession> SendAsync(
        HttpRequestMessage request,
        int expectedStatusCode,
        CancellationToken cancellationToken)
    {
        using var response = await httpClient.SendAsync(request, cancellationToken)
            .ConfigureAwait(false);
        if ((int)response.StatusCode != expectedStatusCode)
        {
            throw new HttpRequestException(
                $"OPL Fleet Gateway returned HTTP {(int)response.StatusCode}.",
                inner: null,
                response.StatusCode);
        }
        var pairing = await JsonSerializer.DeserializeAsync<AmbientOpsPairingSession>(
            await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false),
            Options,
            cancellationToken).ConfigureAwait(false);
        return pairing ?? throw new HttpRequestException("OPL Fleet Gateway returned an invalid pairing response.");
    }

    private static void ValidateEndpoint(Uri endpoint)
    {
        if (endpoint.Scheme is not ("http" or "https") || string.IsNullOrWhiteSpace(endpoint.Host))
        {
            throw new ArgumentException("OPL Fleet Gateway URL must be HTTP or HTTPS.", nameof(endpoint));
        }
    }
}
