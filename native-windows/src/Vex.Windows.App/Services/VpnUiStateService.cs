using Vex.Windows.Core.Vpn;
using Vex.Windows.Client.Api;

namespace Vex.Windows.App.Services;

public sealed class VpnUiStateService
{
    private readonly VpnServiceClient _vpnClient;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly NativeConnectionTelemetryTracker _connectionTelemetry =
        new();

    public VpnUiStateService(VpnServiceClient vpnClient)
    {
        ArgumentNullException.ThrowIfNull(vpnClient);
        _vpnClient = vpnClient;
    }

    public event EventHandler? Changed;

    public VpnConnectionSnapshot Snapshot { get; private set; } =
        VpnConnectionSnapshot.Disconnected();

    public ulong ReceivedBytes { get; private set; }

    public ulong SentBytes { get; private set; }

    public bool ConnectionDesired { get; private set; }

    public ClientConnectionTelemetrySnapshot ConnectionTelemetry =>
        _connectionTelemetry.Snapshot(DateTimeOffset.UtcNow);

    public async Task<VpnServiceResponse> RefreshAsync(
        CancellationToken cancellationToken) =>
        await RunAsync(
            token => _vpnClient.GetDiagnosticsAsync(token),
            cancellationToken).ConfigureAwait(false);

    public async Task<VpnServiceResponse> RunAsync(
        Func<CancellationToken, Task<VpnServiceResponse>> operation,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(operation);
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var response = await operation(cancellationToken)
                .ConfigureAwait(false);
            Apply(response);
            return response;
        }
        finally
        {
            _gate.Release();
        }
    }

    public void MarkConnectionDesired(bool desired)
    {
        _connectionTelemetry.SetConnectionDesired(
            desired,
            Snapshot.Phase,
            DateTimeOffset.UtcNow);
        ConnectionDesired = desired;
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public void Apply(VpnServiceResponse response)
    {
        ArgumentNullException.ThrowIfNull(response);
        var previousPhase = Snapshot.Phase;
        Snapshot = response.Snapshot;
        _connectionTelemetry.Observe(
            previousPhase,
            Snapshot,
            ConnectionDesired,
            DateTimeOffset.UtcNow,
            protocol: "amneziawg");
        ReceivedBytes = ToUnsigned(response.Diagnostics?.RxBytes);
        SentBytes = ToUnsigned(response.Diagnostics?.TxBytes);
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private static ulong ToUnsigned(long? value) =>
        value is > 0
            ? (ulong)value.Value
            : 0;
}
