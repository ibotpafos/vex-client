using Vex.Windows.Core.Vpn;

namespace Vex.Windows.App.Services;

public sealed class VpnUiStateService
{
    private readonly VpnServiceClient _vpnClient;
    private readonly SemaphoreSlim _gate = new(1, 1);

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
        ConnectionDesired = desired;
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public void Apply(VpnServiceResponse response)
    {
        ArgumentNullException.ThrowIfNull(response);
        Snapshot = response.Snapshot;
        ReceivedBytes = ToUnsigned(response.Diagnostics?.RxBytes);
        SentBytes = ToUnsigned(response.Diagnostics?.TxBytes);
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private static ulong ToUnsigned(long? value) =>
        value is > 0
            ? (ulong)value.Value
            : 0;
}
