using Windows.System;
using Vex.Windows.App.Services;
using Vex.Windows.Client.Api;
using Vex.Windows.Client.Auth;
using Vex.Windows.Client.Session;

namespace Vex.Windows.App.Auth;

public sealed record NativeEmailOtpChallenge(
    string Email,
    string ChallengeId,
    DateTimeOffset? ExpiresAt);

public sealed class NativeAuthService
{
    private readonly INativeClientApi _api;
    private readonly NativeClientCoordinator _coordinator;
    private readonly ProtectedClientStateStore _stateStore;
    private readonly ProtectedPkceStateStore _pkceStateStore;
    private readonly Uri _apiBaseUri;
    private readonly SemaphoreSlim _gate = new(1, 1);

    public NativeAuthService(
        INativeClientApi api,
        NativeClientCoordinator coordinator,
        ProtectedClientStateStore stateStore,
        ProtectedPkceStateStore pkceStateStore,
        Uri apiBaseUri)
    {
        _api = api;
        _coordinator = coordinator;
        _stateStore = stateStore;
        _pkceStateStore = pkceStateStore;
        _apiBaseUri = apiBaseUri;
    }

    public event EventHandler? StateChanged;

    public NativeEmailOtpChallenge? EmailOtpChallenge { get; private set; }

    public string? Notice { get; private set; }

    public string? Error { get; private set; }

    public bool IsWaitingForBrowserAuth { get; private set; }

    public bool HasLockedStoredSession =>
        _coordinator.CurrentStateAccess == ClientStateAccessKind.Locked;

    public void ClearStatus()
    {
        Notice = null;
        Error = null;
        NotifyChanged();
    }

    public async Task SignInWithPasswordAsync(
        string email,
        string password,
        CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ClearAuthArtifacts();
            await _coordinator.SignInAndProvisionAsync(
                email,
                password,
                cancellationToken).ConfigureAwait(false);
            Notice = "Вход выполнен.";
            Error = null;
        }
        catch (Exception error) when (
            error is ArgumentException or
                HttpRequestException or
                TaskCanceledException or
                VexApiException or
                NativeClientFlowException)
        {
            Notice = null;
            Error = error switch
            {
                VexApiException api when
                    api.StatusCode == System.Net.HttpStatusCode.Unauthorized =>
                    "Неверный email или пароль.",
                NativeClientFlowException flow when
                    flow.Code == "vpn_location_unavailable" =>
                    "Сейчас нет доступных VPN-серверов.",
                _ => "Не удалось войти. Проверьте подключение и повторите.",
            };
        }
        finally
        {
            _gate.Release();
            NotifyChanged();
        }
    }

    public async Task RequestEmailOtpAsync(
        string email,
        CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var challenge = await _api.RequestEmailOtpAsync(
                email,
                cancellationToken).ConfigureAwait(false);
            EmailOtpChallenge = new NativeEmailOtpChallenge(
                email.Trim(),
                challenge.ChallengeId,
                challenge.ExpiresAt);
            Notice = "Код отправлен на email.";
            Error = null;
        }
        catch (Exception error) when (
            error is ArgumentException or
                HttpRequestException or
                TaskCanceledException or
                VexApiException)
        {
            Notice = null;
            Error = "Не удалось отправить код. Повторите позже.";
        }
        finally
        {
            _gate.Release();
            NotifyChanged();
        }
    }

    public async Task ConfirmEmailOtpAsync(
        string email,
        string code,
        CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (EmailOtpChallenge is null)
            {
                throw new InvalidOperationException(
                    "Сначала запросите код входа.");
            }

            var session = await _api.ConfirmEmailOtpAsync(
                email,
                EmailOtpChallenge.ChallengeId,
                code,
                cancellationToken).ConfigureAwait(false);
            await _coordinator.ProvisionAuthenticatedSessionAsync(
                session,
                cancellationToken).ConfigureAwait(false);
            ClearAuthArtifacts();
            Notice = "Вход по коду выполнен.";
            Error = null;
        }
        catch (Exception error) when (
            error is InvalidOperationException or
                ArgumentException or
                HttpRequestException or
                TaskCanceledException or
                VexApiException or
                NativeClientFlowException)
        {
            Notice = null;
            Error = error switch
            {
                VexApiException api when
                    api.StatusCode == System.Net.HttpStatusCode.Unauthorized =>
                    "Код недействителен или истек. Запросите новый.",
                NativeClientFlowException flow when
                    flow.Code == "vpn_location_unavailable" =>
                    "Сейчас нет доступных VPN-серверов.",
                InvalidOperationException invalid =>
                    invalid.Message,
                _ => "Не удалось завершить вход по коду.",
            };
        }
        finally
        {
            _gate.Release();
            NotifyChanged();
        }
    }

    public async Task StartBrowserAuthAsync(
        WebAuthMode mode,
        CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var request = PkceAuthFlow.CreateRequest(
                _apiBaseUri,
                _stateStore.GetOrCreateInstallationId(),
                "Windows",
                "windows",
                mode);
            _pkceStateStore.Save(request.PendingChallenge);
            EmailOtpChallenge = null;
            IsWaitingForBrowserAuth = true;
            Notice = mode == WebAuthMode.Register
                ? "Завершите регистрацию в браузере и вернитесь в VEX."
                : "Подтвердите вход в браузере и вернитесь в VEX.";
            Error = null;

            var launched = await Launcher.LaunchUriAsync(request.Url);
            if (!launched)
            {
                _pkceStateStore.Clear();
                IsWaitingForBrowserAuth = false;
                Notice = null;
                Error = "Не удалось открыть браузер для входа через сайт.";
            }
        }
        catch (Exception error) when (
            error is ArgumentException or
                IOException or
                UnauthorizedAccessException or
                System.Security.Cryptography.CryptographicException or
                System.Runtime.InteropServices.COMException or
                InvalidOperationException)
        {
            _pkceStateStore.Clear();
            IsWaitingForBrowserAuth = false;
            Notice = null;
            Error = "Не удалось начать вход через сайт.";
        }
        finally
        {
            _gate.Release();
            NotifyChanged();
        }
    }

    public async Task HandleProtocolActivationAsync(
        Uri callbackUri,
        CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var pending = _pkceStateStore.Load() ??
                throw new InvalidOperationException(
                    "Сессия входа через сайт устарела. Запустите вход заново.");
            var exchange = PkceAuthFlow.ResolveCallback(
                callbackUri,
                pending.State,
                pending.Verifier);
            var session = await _api.ExchangeAppAuthCodeAsync(
                exchange.Code,
                exchange.CodeVerifier,
                cancellationToken).ConfigureAwait(false);
            await _coordinator.ProvisionAuthenticatedSessionAsync(
                session,
                cancellationToken).ConfigureAwait(false);
            ClearAuthArtifacts();
            Notice = "Вход через сайт завершен.";
            Error = null;
        }
        catch (Exception error) when (
            error is InvalidOperationException or
                HttpRequestException or
                TaskCanceledException or
                VexApiException or
                NativeClientFlowException)
        {
            IsWaitingForBrowserAuth = false;
            Notice = null;
            Error = error switch
            {
                NativeClientFlowException flow when
                    flow.Code == "vpn_location_unavailable" =>
                    "Сейчас нет доступных VPN-серверов.",
                InvalidOperationException invalid =>
                    invalid.Message,
                _ => "Не удалось завершить вход через сайт.",
            };
        }
        finally
        {
            _gate.Release();
            NotifyChanged();
        }
    }

    public void CancelBrowserAuth()
    {
        ClearAuthArtifacts();
        Notice = "Вход через сайт отменен.";
        Error = null;
        NotifyChanged();
    }

    private void ClearAuthArtifacts()
    {
        EmailOtpChallenge = null;
        IsWaitingForBrowserAuth = false;
        _pkceStateStore.Clear();
    }

    private void NotifyChanged() =>
        StateChanged?.Invoke(this, EventArgs.Empty);
}
