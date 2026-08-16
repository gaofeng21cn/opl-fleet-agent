using System.Net.NetworkInformation;
using System.Runtime.InteropServices;

namespace OPLFleetAgent.Core;

public sealed class HostCpuTelemetrySampler
{
    private ulong? previousIdle;
    private ulong? previousKernel;
    private ulong? previousUser;

    public double? SampleCpuPercent()
    {
        if (!OperatingSystem.IsWindows() ||
            !GetSystemTimes(out var idle, out var kernel, out var user))
        {
            return null;
        }

        var idleValue = idle.Value;
        var kernelValue = kernel.Value;
        var userValue = user.Value;
        var result = previousIdle is { } priorIdle &&
            previousKernel is { } priorKernel &&
            previousUser is { } priorUser
                ? UsagePercent(priorIdle, priorKernel, priorUser, idleValue, kernelValue, userValue)
                : null;
        previousIdle = idleValue;
        previousKernel = kernelValue;
        previousUser = userValue;
        return result;
    }

    public static double? UsagePercent(
        ulong previousIdle,
        ulong previousKernel,
        ulong previousUser,
        ulong currentIdle,
        ulong currentKernel,
        ulong currentUser)
    {
        if (currentIdle < previousIdle ||
            currentKernel < previousKernel ||
            currentUser < previousUser)
        {
            return null;
        }
        var idleDelta = currentIdle - previousIdle;
        var kernelDelta = currentKernel - previousKernel;
        var userDelta = currentUser - previousUser;
        var total = (double)kernelDelta + userDelta;
        if (total <= 0 || idleDelta > total)
        {
            return null;
        }
        return Math.Clamp((total - idleDelta) / total * 100, 0, 100);
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetSystemTimes(
        out FileTime idleTime,
        out FileTime kernelTime,
        out FileTime userTime);

    [StructLayout(LayoutKind.Sequential)]
    private readonly struct FileTime
    {
        private readonly uint low;
        private readonly uint high;

        public ulong Value => ((ulong)high << 32) | low;
    }
}

public sealed record HostNetworkTelemetry(
    double DownloadMbps,
    double UploadMbps,
    DateTimeOffset SampledAt);

public sealed class HostNetworkTelemetrySampler
{
    private static readonly string[] ExcludedNames =
    [
        "bluetooth",
        "hyper-v",
        "loopback",
        "npcap",
        "tailscale",
        "tunnel",
        "virtual",
        "virtualbox",
        "vmware",
        "vpn",
        "wsl",
    ];

    private ulong? previousReceivedBytes;
    private ulong? previousSentBytes;
    private DateTimeOffset? previousSampledAt;

    public HostNetworkTelemetry? Sample(DateTimeOffset? sampledAt = null)
    {
        var now = sampledAt ?? DateTimeOffset.Now;
        var counters = PhysicalInterfaceCounters();
        if (counters is null)
        {
            return null;
        }

        var result = previousReceivedBytes is { } priorReceived &&
            previousSentBytes is { } priorSent &&
            previousSampledAt is { } priorAt
                ? Telemetry(
                    priorReceived,
                    priorSent,
                    counters.Value.Received,
                    counters.Value.Sent,
                    now - priorAt,
                    now)
                : null;
        previousReceivedBytes = counters.Value.Received;
        previousSentBytes = counters.Value.Sent;
        previousSampledAt = now;
        return result;
    }

    public static HostNetworkTelemetry? Telemetry(
        ulong previousReceivedBytes,
        ulong previousSentBytes,
        ulong currentReceivedBytes,
        ulong currentSentBytes,
        TimeSpan elapsed,
        DateTimeOffset sampledAt)
    {
        if (elapsed <= TimeSpan.Zero ||
            currentReceivedBytes < previousReceivedBytes ||
            currentSentBytes < previousSentBytes)
        {
            return null;
        }
        const double bitsPerMegabit = 1_000_000;
        return new HostNetworkTelemetry(
            (currentReceivedBytes - previousReceivedBytes) * 8 / elapsed.TotalSeconds / bitsPerMegabit,
            (currentSentBytes - previousSentBytes) * 8 / elapsed.TotalSeconds / bitsPerMegabit,
            sampledAt);
    }

    internal static bool IsPhysicalInterface(NetworkInterface networkInterface)
    {
        if (networkInterface.OperationalStatus != OperationalStatus.Up ||
            networkInterface.NetworkInterfaceType is not (
                NetworkInterfaceType.Ethernet or
                NetworkInterfaceType.FastEthernetFx or
                NetworkInterfaceType.FastEthernetT or
                NetworkInterfaceType.GigabitEthernet or
                NetworkInterfaceType.Wireless80211 or
                NetworkInterfaceType.Wman or
                NetworkInterfaceType.Wwanpp or
                NetworkInterfaceType.Wwanpp2))
        {
            return false;
        }
        var label = $"{networkInterface.Name} {networkInterface.Description}";
        return !ExcludedNames.Any(term => label.Contains(term, StringComparison.OrdinalIgnoreCase));
    }

    private static (ulong Received, ulong Sent)? PhysicalInterfaceCounters()
    {
        try
        {
            ulong received = 0;
            ulong sent = 0;
            var found = false;
            foreach (var networkInterface in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (!IsPhysicalInterface(networkInterface))
                {
                    continue;
                }
                var statistics = networkInterface.GetIPStatistics();
                received += (ulong)Math.Max(0, statistics.BytesReceived);
                sent += (ulong)Math.Max(0, statistics.BytesSent);
                found = true;
            }
            return found ? (received, sent) : null;
        }
        catch (Exception error) when (
            error is NetworkInformationException or PlatformNotSupportedException or InvalidOperationException)
        {
            return null;
        }
    }
}
