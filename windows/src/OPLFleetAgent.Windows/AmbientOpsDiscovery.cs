using OPLFleetAgent.Core;
using Zeroconf;

namespace OPLFleetAgent.WindowsApp;

internal sealed class AmbientOpsDiscovery
{
    public async Task<IReadOnlyList<AmbientOpsService>> DiscoverAsync(
        CancellationToken cancellationToken)
    {
        var hosts = await ZeroconfResolver.ResolveAsync(
            AmbientOpsDiscoveryContract.ServiceType,
            TimeSpan.FromSeconds(3),
            retries: 2,
            retryDelayMilliseconds: 200,
            callback: null,
            cancellationToken: cancellationToken).ConfigureAwait(false);
        var results = new List<AmbientOpsService>();
        foreach (var host in hosts)
        {
            foreach (var service in host.Services.Values)
            {
                var txt = new Dictionary<string, string>(StringComparer.Ordinal);
                foreach (var propertySet in service.Properties)
                {
                    foreach (var property in propertySet)
                    {
                        txt[property.Key] = property.Value;
                    }
                }
                var name = service.ServiceName.Split("._", 2, StringSplitOptions.None)[0];
                var candidate = AmbientOpsDiscoveryContract.CreateService(
                    name,
                    host.IPAddress,
                    service.Port,
                    txt);
                if (candidate is not null && !results.Contains(candidate))
                {
                    results.Add(candidate);
                }
            }
        }
        return results;
    }
}
