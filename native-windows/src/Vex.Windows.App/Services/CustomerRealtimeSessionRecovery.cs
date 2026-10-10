using System.Net;
using Vex.Windows.Client.Api;
using Vex.Windows.Client.Session;

namespace Vex.Windows.App.Services;

/// <summary>Recovers rejected stream credentials without treating outages as revocation.</summary>
public sealed class CustomerRealtimeSessionRecovery
{
    public const int MaximumRefreshAttempts = 3;
    private readonly NativeClientCoordinator _coordinator;
    private readonly Func<string, CancellationToken, Task> _restartRealtime;
    private readonly Func<Task> _stopRealtime;
    private readonly Func<string, CancellationToken, Task> _signOut;
    private readonly Func<int, CancellationToken, Task> _delay;
    private readonly SemaphoreSlim _gate = new(1, 1);

    public CustomerRealtimeSessionRecovery(NativeClientCoordinator coordinator,
        Func<string, CancellationToken, Task> restartRealtime, Func<Task> stopRealtime,
        Func<string, CancellationToken, Task> signOut,
        Func<int, CancellationToken, Task>? delay = null)
    {
        _coordinator = coordinator;
        _restartRealtime = restartRealtime;
        _stopRealtime = stopRealtime;
        _signOut = signOut;
        _delay = delay ?? ((attempt, token) => Task.Delay(CustomerRealtimeClient.ReconnectDelay(attempt), token));
    }

    public async Task HandleAsync(CustomerRealtimeChangedEventArgs args, CancellationToken cancellationToken = default)
    {
        if (args.Event.Type is not ("customer.session.revoked" or "customer.session.refresh_required")) return;
        // The backend emits session_invalid for every failed heartbeat lookup,
        // including database outages. Both stream signals require a bounded
        // refresh probe; only rejected refresh credentials prove revocation.
        if (!await _gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return;

        try
        {
            var state = _coordinator.CurrentState;
            if (state is null || args.SourceTokenFingerprint is { } fingerprint &&
                CustomerRealtimeClient.TokenFingerprint(state.Session.AccessToken) != fingerprint) return;
            var expectedToken = state.Session.AccessToken;
            await _stopRealtime().ConfigureAwait(false);

            using var refresh = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            for (var attempt = 0; attempt < MaximumRefreshAttempts; attempt++)
            {
                if (_coordinator.CurrentState?.Session.AccessToken != expectedToken) return;
                refresh.Token.ThrowIfCancellationRequested();
                try
                {
                    using var request = CancellationTokenSource.CreateLinkedTokenSource(refresh.Token);
                    request.CancelAfter(TimeSpan.FromSeconds(15));
                    var renewed = await _coordinator.ForceRefreshSessionAsync(request.Token, expectedToken)
                        .WaitAsync(request.Token).ConfigureAwait(false);
                    if (_coordinator.CurrentState?.Session.AccessToken == renewed.Session.AccessToken)
                        await _restartRealtime(renewed.Session.AccessToken, refresh.Token).ConfigureAwait(false);
                    return;
                }
                catch (Exception error) when (IsAuthenticationRejection(error))
                {
                    await _signOut(expectedToken, cancellationToken).ConfigureAwait(false);
                    return;
                }
                catch (Exception error) when (IsTransient(error) && !refresh.IsCancellationRequested)
                {
                    if (attempt + 1 < MaximumRefreshAttempts)
                        await _delay(attempt, refresh.Token).ConfigureAwait(false);
                }
            }
            // Keep the still-refreshable session. A successful refresh from
            // another product flow emits SessionChanged and resumes realtime.
        }
        catch (Exception error) when (error is OperationCanceledException or NativeClientFlowException or
            IOException or UnauthorizedAccessException or System.Security.Cryptography.CryptographicException or
            InvalidOperationException or HttpRequestException or VexApiException or System.Text.Json.JsonException)
        {
            // A newer login, lock or local storage failure can interrupt
            // recovery without invalidating another session.
        }
        finally { _gate.Release(); }
    }

    private static bool IsAuthenticationRejection(Exception error) => error is
        VexApiException { StatusCode: HttpStatusCode.Unauthorized } or
        HttpRequestException { StatusCode: HttpStatusCode.Unauthorized };

    private static bool IsTransient(Exception error) => error switch
    {
        OperationCanceledException => true,
        HttpRequestException { StatusCode: null } => true,
        HttpRequestException transport => IsTransientStatus(transport.StatusCode!.Value),
        VexApiException api => IsTransientStatus(api.StatusCode),
        IOException => true,
        _ => false,
    };

    private static bool IsTransientStatus(HttpStatusCode status) =>
        status is HttpStatusCode.RequestTimeout or HttpStatusCode.TooManyRequests || (int)status >= 500;
}
