using System.Text.Json;
using OPLFleetAgent.Core;

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

if (readRef is not (OplFleetAgentProvider.TelemetryRef or OplFleetAgentProvider.DoctorRef))
{
    Console.Error.WriteLine("Unsupported provider ref");
    return 2;
}

FleetAgentLocalSettings settings;
SessionScanner scanner;
try
{
    settings = FleetAgentLocalSettings.Load();
    scanner = new SessionScanner(settings.CodexHome);
}
catch (Exception error) when (error is IOException or UnauthorizedAccessException
    or JsonException or ArgumentException or NotSupportedException)
{
    Console.Error.WriteLine("Local observation settings could not be read");
    return 2;
}
var identity = settings.Identity;
var now = DateTimeOffset.UtcNow;
var usage = scanner.Refresh(now);
var lastKnownStore = new FleetAgentLastKnownStore(
    FleetAgentLastKnownStore.DefaultPath(), identity, scanner.CodexHome);
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
        if (usage.Status == CollectionStatus.Ready)
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
