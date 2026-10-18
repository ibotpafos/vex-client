using System.Security.Cryptography;
using System.Text.Json;

namespace Vex.Windows.Core.Vpn;

public sealed class VpnServiceCommandHandler : IDisposable
{
    private const int MaxCachedResponses = 128;

    private readonly IVpnTunnelRuntime _runtime;
    private readonly SemaphoreSlim _commandGate = new(1, 1);
    private readonly Dictionary<string, CachedResponse> _responses = [];
    private readonly Queue<string> _responseOrder = [];
    private readonly object _operationGate = new();
    private CancellationTokenSource? _connectCancellation;
    private VpnConnectionSnapshot _current = VpnConnectionSnapshot.Disconnected();
    private bool _disposed;

    public VpnServiceCommandHandler(IVpnTunnelRuntime runtime)
    {
        ArgumentNullException.ThrowIfNull(runtime);
        _runtime = runtime;
    }

    public async Task<VpnServiceResponse> HandleAsync(
        VpnServiceRequest request,
        CancellationToken cancellationToken,
        VpnAuthorizedProfile? authorizedProfile = null)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentNullException.ThrowIfNull(request);

        if (request.Operation is VpnServiceOperation.Disconnect or VpnServiceOperation.StopTransport)
        {
            lock (_operationGate)
            {
                _connectCancellation?.Cancel();
            }
        }

        await _commandGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var requestFingerprint = Fingerprint(request) + "|" + (authorizedProfile?.RoutingMode ?? "") + "|" + (authorizedProfile?.BypassRegion ?? "");
            if (_responses.TryGetValue(request.RequestId, out var cached))
            {
                return cached.RequestFingerprint == requestFingerprint
                    ? cached.Response
                    : Failure(request.RequestId, "request_id_conflict");
            }

            var response = await ExecuteAsync(request, cancellationToken, authorizedProfile)
                .ConfigureAwait(false);
            Cache(request, response, requestFingerprint);
            return response;
        }
        finally
        {
            _commandGate.Release();
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _commandGate.Dispose();
        lock (_operationGate)
        {
            _connectCancellation?.Cancel();
            _connectCancellation?.Dispose();
            _connectCancellation = null;
        }
        _disposed = true;
    }

    private async Task<VpnServiceResponse> ExecuteAsync(
        VpnServiceRequest request,
        CancellationToken cancellationToken,
        VpnAuthorizedProfile? authorizedProfile)
    {
        try
        {
            var status = request.Operation switch
            {
                VpnServiceOperation.Status =>
                    await _runtime.GetStatusAsync(cancellationToken).ConfigureAwait(false),
                VpnServiceOperation.Connect =>
                    await ConnectAsync(request, cancellationToken, authorizedProfile).ConfigureAwait(false),
                VpnServiceOperation.Disconnect =>
                    await DisconnectAsync(cancellationToken).ConfigureAwait(false),
                VpnServiceOperation.StopTransport => await _runtime.SuspendAsync(cancellationToken).ConfigureAwait(false),
                VpnServiceOperation.Diagnostics =>
                    await _runtime.GetDiagnosticsAsync(cancellationToken).ConfigureAwait(false),
                VpnServiceOperation.SetAntiLeak =>
                    await _runtime.SetAntiLeakAsync(
                        request.AntiLeakEnabled!.Value,
                        cancellationToken).ConfigureAwait(false),
                _ => throw new ArgumentOutOfRangeException(nameof(request)),
            };

            _current = ToSnapshot(status);
            return new VpnServiceResponse(
                request.RequestId,
                success: true,
                _current,
                errorCode: null);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (VpnTunnelException error)
        {
            return Failure(request.RequestId, VpnErrorCode.Sanitize(error.Code));
        }
        catch (Exception)
        {
            return Failure(request.RequestId, VpnErrorCode.RuntimeFailure);
        }
    }

    private async Task<VpnTunnelStatus> ConnectAsync(
        VpnServiceRequest request,
        CancellationToken cancellationToken,
        VpnAuthorizedProfile? authorizedProfile)
    {
        _current = new VpnConnectionSnapshot(
            VpnConnectionPhase.Connecting,
            request.LocationId,
            NextSequence(),
            ErrorCode: null);

        using var connectCancellation =
            CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        lock (_operationGate)
        {
            _connectCancellation = connectCancellation;
        }

        try
        {
            if (authorizedProfile is not null) {
                return await _runtime.ConnectAuthorizedAsync(authorizedProfile, request.AntiLeakEnabled ?? true, connectCancellation.Token).ConfigureAwait(false);
            }
            return await _runtime.ConnectAsync(
                request.LocationId!,
                request.TunnelConfig!,
                request.AuthorizationExpiresAt,
                request.AntiLeakEnabled ?? true,
                connectCancellation.Token).ConfigureAwait(false);
        }
        finally
        {
            lock (_operationGate)
            {
                if (ReferenceEquals(_connectCancellation, connectCancellation))
                {
                    _connectCancellation = null;
                }
            }
        }
    }

    private async Task<VpnTunnelStatus> DisconnectAsync(
        CancellationToken cancellationToken)
    {
        if (_current.Phase != VpnConnectionPhase.Disconnected)
        {
            _current = new VpnConnectionSnapshot(
                VpnConnectionPhase.Disconnecting,
                _current.LocationId,
                NextSequence(),
                ErrorCode: null);
        }

        return await _runtime.DisconnectAsync(cancellationToken).ConfigureAwait(false);
    }

    private VpnConnectionSnapshot ToSnapshot(VpnTunnelStatus status) =>
        new VpnConnectionSnapshot(
            status.Phase,
            status.LocationId,
            NextSequence(),
            status.ErrorCode)
        {
            Diagnostics = status.Diagnostics,
        };

    private VpnServiceResponse Failure(string requestId, string errorCode)
    {
        _current = new VpnConnectionSnapshot(
            VpnConnectionPhase.Error,
            _current.LocationId,
            NextSequence(),
            errorCode);
        return new VpnServiceResponse(
            requestId,
            success: false,
            _current,
            errorCode);
    }

    private long NextSequence() => checked(_current.Sequence + 1);

    private void Cache(VpnServiceRequest request, VpnServiceResponse response, string fingerprint)
    {
        _responses.Add(
            request.RequestId,
            new CachedResponse(fingerprint, response));
        _responseOrder.Enqueue(request.RequestId);

        while (_responseOrder.Count > MaxCachedResponses)
        {
            var expired = _responseOrder.Dequeue();
            _responses.Remove(expired);
        }
    }

    private static string Fingerprint(VpnServiceRequest request)
    {
        var serialized = JsonSerializer.SerializeToUtf8Bytes(request);
        try
        {
            return Convert.ToHexString(SHA256.HashData(serialized));
        }
        finally
        {
            CryptographicOperations.ZeroMemory(serialized);
        }
    }

    private sealed record CachedResponse(
        string RequestFingerprint,
        VpnServiceResponse Response);
}
