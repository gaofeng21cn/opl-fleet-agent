using System.Text.Json;
using System.Text.RegularExpressions;
using CodexTPS.Core;

if (args is ["--help"] or ["-h"])
{
    Console.WriteLine(
        "Usage: OPLFleetAgentProvider --ref <fleet.agent.telemetry.v1#local|fleet.agent.doctor.v1#current>");
    return 0;
}
if (args is not ["--ref", var readRef])
{
    Console.Error.WriteLine("Invalid arguments");
    return 2;
}

var identity = LocalIdentity();
var now = DateTimeOffset.UtcNow;
var usage = new SessionScanner().Refresh(now);
var lastKnownStore = new FleetAgentLastKnownStore(FleetAgentLastKnownStore.DefaultPath());
var lastKnownLoad = lastKnownStore.Load(now);
var lastKnown = lastKnownLoad.Sample;
var fallback = lastKnown?.UsageSnapshot();
object projection;
switch (readRef)
{
    case OplFleetAgentProvider.TelemetryRef:
        var cpuSampler = new HostCpuTelemetrySampler();
        var networkSampler = new HostNetworkTelemetrySampler();
        _ = cpuSampler.SampleCpuPercent();
        _ = networkSampler.Sample();
        await Task.Delay(100);
        var telemetry = OplFleetAgentProvider.Telemetry(
            usage,
            identity,
            fallback: fallback,
            fallbackLastObservedAt: lastKnown?.LastObservedAt,
            cpuPercent: usage.Status == CollectionStatus.Ready
                ? cpuSampler.SampleCpuPercent()
                : lastKnown?.Payload.HostCpuPercent,
            network: usage.Status == CollectionStatus.Ready
                ? networkSampler.Sample()
                : lastKnown?.NetworkTelemetry(),
            unavailableReasonCode: lastKnownLoad.UnavailableReasonCode,
            now: DateTimeOffset.UtcNow);
        if (telemetry.Freshness.State == "fresh")
        {
            try
            {
                lastKnownStore.Save(telemetry);
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
        }
        projection = telemetry;
        break;
    case OplFleetAgentProvider.DoctorRef:
        if (usage.Status == CollectionStatus.Ready && lastKnown is null)
        {
            try
            {
                lastKnownStore.Save(OplFleetAgentProvider.Telemetry(usage, identity, now: now));
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
        }
        projection = OplFleetAgentProvider.Doctor(
            usage,
            identity,
            fallback: fallback,
            fallbackLastObservedAt: lastKnown?.LastObservedAt,
            unavailableReasonCode: lastKnownLoad.UnavailableReasonCode,
            now: now);
        break;
    default:
        Console.Error.WriteLine("Unsupported provider ref");
        return 2;
}

Console.WriteLine(JsonSerializer.Serialize(projection, OplFleetAgentProvider.SerializerOptions));
return 0;

static AmbientOpsMachineIdentity LocalIdentity()
{
    var defaultId = Regex.Replace(
        Environment.MachineName.ToLowerInvariant(),
        "[^a-z0-9._-]",
        "-",
        RegexOptions.CultureInvariant);
    if (string.IsNullOrEmpty(defaultId))
    {
        defaultId = "windows";
    }
    var machineId = Environment.GetEnvironmentVariable("CODEX_TPS_MACHINE_ID") ?? defaultId;
    var machineName =
        Environment.GetEnvironmentVariable("CODEX_TPS_MACHINE_NAME") ?? Environment.MachineName;
    var platform = Environment.GetEnvironmentVariable("CODEX_TPS_PLATFORM") ?? "Windows";
    return new AmbientOpsMachineIdentity(machineId, machineName, platform);
}
