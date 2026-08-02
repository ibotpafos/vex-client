using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Principal;
using Microsoft.Extensions.Logging;
using Vex.Windows.Core.Vpn;
using Vex.Windows.Core.Vpn.Ipc;
using Vex.Windows.Service.Security;

namespace Vex.Windows.Service.Ipc;

public sealed class NamedPipeVpnServer
{
    private const int ListenerCount = 4;
    private static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(45);

    private readonly VpnServiceCommandHandler _handler;
    private readonly VpnIpcAuthenticator _authenticator;
    private readonly ClientProcessAttestor _attestor;
    private readonly VpnSignedProfileVerifier _profileVerifier;
    private readonly ILogger<NamedPipeVpnServer> _logger;

    public NamedPipeVpnServer(
        VpnServiceCommandHandler handler,
        ProtectedAuthorizationStore authorizationStore,
        ClientProcessAttestor attestor,
        VpnSignedProfileVerifier profileVerifier,
        ILogger<NamedPipeVpnServer> logger)
    {
        _handler = handler;
        _authenticator = new VpnIpcAuthenticator(authorizationStore.Read());
        _attestor = attestor;
        _profileVerifier = profileVerifier;
        _logger = logger;
    }

    public Task RunAsync(CancellationToken stoppingToken) =>
        Task.WhenAll(
            Enumerable.Range(0, ListenerCount)
                .Select(_ => RunListenerAsync(stoppingToken)));

    private async Task RunListenerAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            await using var pipe = CreatePipe();
            try
            {
                await pipe.WaitForConnectionAsync(stoppingToken)
                    .ConfigureAwait(false);
                await HandleClientAsync(pipe, stoppingToken)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                return;
            }
            catch (Exception error)
            {
                _logger.LogWarning(
                    "VPN IPC request failed with {ErrorType}.",
                    error.GetType().Name);
            }
        }
    }

    private async Task HandleClientAsync(
        NamedPipeServerStream pipe,
        CancellationToken stoppingToken)
    {
        if (!_attestor.IsAllowed(pipe))
        {
            _logger.LogWarning("VPN IPC rejected an unattested client.");
            return;
        }

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(
            stoppingToken);
        timeout.CancelAfter(RequestTimeout);

        var envelope = await VpnIpcFrameCodec.ReadRequestAsync(
            pipe,
            timeout.Token).ConfigureAwait(false);
        if (!_authenticator.Verify(envelope.Authorization))
        {
            await WriteFailureAsync(
                pipe,
                envelope.Request.RequestId,
                "unauthorized",
                timeout.Token).ConfigureAwait(false);
            return;
        }

        var request = envelope.Request;
        if (!VpnServiceAccessPolicy.IsAuthorized(request))
        {
            await WriteFailureAsync(
                pipe,
                envelope.Request.RequestId,
                "trusted_profile_required",
                timeout.Token).ConfigureAwait(false);
            return;
        }

        if (request.Operation == VpnServiceOperation.Connect)
        {
            try
            {
                var profile = _profileVerifier.Authorize(
                    request.ProfileAuthorization!,
                    request.LocalPrivateKey!);
                request = VpnServiceRequest.Connect(
                    request.RequestId,
                    profile.LocationId,
                    profile.TunnelConfig,
                    profile.ExpiresAt,
                    request.AntiLeakEnabled ?? true);
            }
            catch (VpnTunnelException error)
            {
                var errorCode = VpnErrorCode.Sanitize(error.Code);
                _logger.LogWarning(
                    "VPN profile authorization failed with {ErrorCode}.",
                    errorCode);
                await WriteFailureAsync(
                    pipe,
                    request.RequestId,
                    errorCode,
                    timeout.Token).ConfigureAwait(false);
                return;
            }
        }

        var response = await _handler.HandleAsync(
            request,
            timeout.Token).ConfigureAwait(false);
        await VpnIpcFrameCodec.WriteResponseAsync(
            pipe,
            response,
            timeout.Token).ConfigureAwait(false);
    }

    private static NamedPipeServerStream CreatePipe()
    {
        var security = new PipeSecurity();
        security.AddAccessRule(new PipeAccessRule(
            new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
            PipeAccessRights.FullControl,
            AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(
            new SecurityIdentifier(
                WellKnownSidType.BuiltinAdministratorsSid,
                null),
            PipeAccessRights.FullControl,
            AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(
            new SecurityIdentifier(
                WellKnownSidType.AuthenticatedUserSid,
                null),
            PipeAccessRights.ReadWrite,
            AccessControlType.Allow));

        return NamedPipeServerStreamAcl.Create(
            VpnServiceProtocol.PipeName,
            PipeDirection.InOut,
            ListenerCount,
            PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous | PipeOptions.WriteThrough,
            VpnIpcFrameCodec.MaxFrameBytes,
            VpnIpcFrameCodec.MaxFrameBytes,
            security);
    }

    private static Task WriteFailureAsync(
        Stream pipe,
        string requestId,
        string errorCode,
        CancellationToken cancellationToken) =>
        VpnIpcFrameCodec.WriteResponseAsync(
            pipe,
            new VpnServiceResponse(
                requestId,
                success: false,
                VpnConnectionSnapshot.Disconnected(),
                errorCode),
            cancellationToken);
}
