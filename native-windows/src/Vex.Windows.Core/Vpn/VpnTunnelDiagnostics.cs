namespace Vex.Windows.Core.Vpn;

public enum VpnLeakProtectionState
{
    Off,
    Armed,
    Blocking,
    Degraded,
}

public sealed record VpnTunnelDiagnostics(
    string? AdapterName,
    int? AdapterIndex,
    string? Endpoint,
    long RxBytes,
    long TxBytes,
    DateTimeOffset? LatestHandshakeAt,
    bool Ipv4RouteOk,
    bool Ipv6RouteOk,
    bool DnsConfigured,
    bool EndpointBypassOk,
    VpnLeakProtectionState LeakProtection,
    IReadOnlyList<string> DnsServers,
    IReadOnlyList<string> Findings)
{
    public static VpnTunnelDiagnostics Empty { get; } =
        new(
            AdapterName: null,
            AdapterIndex: null,
            Endpoint: null,
            RxBytes: 0,
            TxBytes: 0,
            LatestHandshakeAt: null,
            Ipv4RouteOk: false,
            Ipv6RouteOk: true,
            DnsConfigured: false,
            EndpointBypassOk: false,
            LeakProtection: VpnLeakProtectionState.Off,
            DnsServers: [],
            Findings: []);

    public bool IsUsable =>
        AdapterName is not null &&
        Ipv4RouteOk &&
        Ipv6RouteOk &&
        DnsConfigured &&
        EndpointBypassOk;
}
