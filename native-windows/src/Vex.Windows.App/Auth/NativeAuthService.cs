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
    private readonly IClientStateStore _stateStore;
    private readonly IPkceStateStore _pkceStateStore;
    private readonly Uri _apiBaseUri;
    private readonly Func<Uri, Task<bool>> _launchBrowser;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly object _browserSync = new();
    private BrowserAttempt? _browserAttempt;
    private bool _browserAuthInvalidated;

    public NativeAuthService(
        INativeClientApi api,
        NativeClientCoordinator coordinator,
        IClientStateStore stateStore,
        IPkceStateStore pkceStateStore,
        Uri apiBaseUri,
        Func<Uri, Task<bool>> launchBrowser)
    {
        _api = api;
        _coordinator = coordinator;
        _stateStore = stateStore;
        _pkceStateStore = pkceStateStore;
        _apiBaseUri = apiBaseUri;
        _launchBrowser = launchBrowser;
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
        lock (_browserSync)
        {
            Notice = null;
            Error = null;
        }
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
                InvalidOperationException or
                IOException or
                UnauthorizedAccessException or
                System.Security.Cryptography.CryptographicException or
                System.Text.Json.JsonException or
                HttpRequestException or
                TaskCanceledException or
                VexApiException or
                NativeClientFlowException)
        {
            Notice = null;
            Error = error switch
            {
                IOException or UnauthorizedAccessException or
                    System.Security.Cryptography.CryptographicException or
                    System.Text.Json.JsonException =>
                    "Не удалось прочитать сохраненные данные VEX. Проверьте доступ к папке приложения и повторите.",
                VexApiException api when api.Code.Contains("mfa", StringComparison.OrdinalIgnoreCase) =>
                    "Для двухфакторной проверки войдите через сайт.",
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

            if (!string.Equals(
                    email.Trim(),
                    EmailOtpChallenge.Email,
                    StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException(
                    "Email изменился. Запросите код для нового адреса.");
            }

            var session = await _api.ConfirmEmailOtpAsync(
                EmailOtpChallenge.Email,
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
                IOException or
                UnauthorizedAccessException or
                System.Security.Cryptography.CryptographicException or
                System.Text.Json.JsonException or
                HttpRequestException or
                TaskCanceledException or
                VexApiException or
                NativeClientFlowException)
        {
            Notice = null;
            Error = error switch
            {
                IOException or UnauthorizedAccessException or
                    System.Security.Cryptography.CryptographicException or
                    System.Text.Json.JsonException =>
                    "Не удалось прочитать сохраненные данные VEX. Проверьте доступ к папке приложения и повторите.",
                VexApiException api when api.Code.Contains("mfa", StringComparison.OrdinalIgnoreCase) =>
                    "Для двухфакторной проверки войдите через сайт.",
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
        CancellationToken cancellationToken,
        WebAuthProvider? provider = null)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        BrowserAttempt? attempt = null;
        BrowserAttempt? previous = null;
        try
        {
            lock (_browserSync)
            {
                previous = _browserAttempt;
                attempt = new BrowserAttempt(string.Empty);
                _browserAttempt = attempt;
                _browserAuthInvalidated = false;
            }
            previous?.Cancel();
            var request = PkceAuthFlow.CreateRequest(
                _apiBaseUri,
                _stateStore.GetOrCreateInstallationId(),
                "Windows",
                "windows",
                mode,
                provider: provider);
            lock (_browserSync)
            {
                if (!IsCurrentBrowserAttempt(attempt)) return;
                attempt.State = request.PendingChallenge.State;
                _pkceStateStore.Save(request.PendingChallenge);
                EmailOtpChallenge = null;
                IsWaitingForBrowserAuth = true;
                Notice = mode == WebAuthMode.Register
                    ? "Завершите регистрацию в браузере и вернитесь в VEX."
                    : "Подтвердите вход в браузере и вернитесь в VEX.";
                Error = null;
            }
            NotifyChanged();
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, attempt.Token);
            linked.Token.ThrowIfCancellationRequested();
            var launched = await _launchBrowser(request.Url).WaitAsync(linked.Token).ConfigureAwait(false);
            if (!launched)
            {
                FailBrowserAttempt(attempt, "Не удалось открыть браузер для входа через сайт.");
            }
        }
        catch (Exception error) when (IsAuthStorageError(error) || error is ArgumentException or
            System.Runtime.InteropServices.COMException or InvalidOperationException or OperationCanceledException)
        {
            FailBrowserAttempt(attempt, error is OperationCanceledException
                ? "Вход через сайт отменен."
                : "Не удалось начать вход через сайт.");
        }
        finally
        {
            previous?.Cancel();
            _gate.Release();
            NotifyChanged();
        }
    }

    public async Task HandleProtocolActivationAsync(
        Uri callbackUri,
        CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        BrowserAttempt? attempt = null;
        try
        {
            AppAuthCodeExchange exchange;
            lock (_browserSync)
            {
                if (_browserAuthInvalidated) return;
                attempt = _browserAttempt;
                var pending = _pkceStateStore.Load() ??
                    throw new InvalidOperationException(
                        "Сессия входа через сайт устарела. Запустите вход заново.");
                try
                {
                    exchange = PkceAuthFlow.ResolveCallback(callbackUri, pending.State, pending.Verifier);
                }
                catch (InvalidOperationException) when (IsWaitingForBrowserAuth)
                {
                    // An older or malformed callback cannot replace an active challenge.
                    return;
                }
                attempt = _browserAttempt ??= new BrowserAttempt(pending.State);
                if (attempt.State != pending.State) return;
                IsWaitingForBrowserAuth = true;
            }
            NotifyChanged();
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, attempt.Token);
            linked.Token.ThrowIfCancellationRequested();
            var session = await _api.ExchangeAppAuthCodeAsync(
                exchange.Code,
                exchange.CodeVerifier,
                linked.Token).WaitAsync(linked.Token).ConfigureAwait(false);
            linked.Token.ThrowIfCancellationRequested();
            await _coordinator.ProvisionAuthenticatedSessionAsync(
                session,
                linked.Token).WaitAsync(linked.Token).ConfigureAwait(false);
            lock (_browserSync)
            {
                if (!IsCurrentBrowserAttempt(attempt)) return;
                linked.Token.ThrowIfCancellationRequested();
                IsWaitingForBrowserAuth = false;
                EmailOtpChallenge = null;
                _browserAuthInvalidated = true;
                _browserAttempt = null;
                var cleared = TryClearPkceState();
                Notice = "Вход через сайт завершен.";
                Error = cleared ? null : "Вход выполнен, но временные данные входа не удалось удалить.";
            }
            attempt.Cancel();
        }
        catch (Exception error) when (IsAuthStorageError(error) || error is InvalidOperationException or
            HttpRequestException or OperationCanceledException or VexApiException or NativeClientFlowException)
        {
            FailBrowserAttempt(attempt, error switch
            {
                NativeClientFlowException flow when flow.Code == "vpn_location_unavailable" =>
                    "Сейчас нет доступных VPN-серверов.",
                OperationCanceledException => "Вход через сайт отменен.",
                InvalidOperationException invalid => invalid.Message,
                _ => "Не удалось завершить вход через сайт.",
            });
        }
        finally
        {
            _gate.Release();
            NotifyChanged();
        }
    }

    public void CancelBrowserAuth()
    {
        BrowserAttempt? attempt;
        lock (_browserSync)
        {
            attempt = _browserAttempt;
            _browserAttempt = null;
            _browserAuthInvalidated = true;
            IsWaitingForBrowserAuth = false;
            EmailOtpChallenge = null;
            attempt?.Cancel();
            var cleared = TryClearPkceState();
            Notice = "Вход через сайт отменен.";
            Error = cleared ? null :
                "Вход отменен, но временные данные не удалось удалить. Проверьте доступ к папке VEX.";
        }
        NotifyChanged();
    }

    private bool IsCurrentBrowserAttempt(BrowserAttempt attempt) =>
        ReferenceEquals(attempt, _browserAttempt) && !_browserAuthInvalidated && !attempt.Token.IsCancellationRequested;

    private void FailBrowserAttempt(BrowserAttempt? attempt, string message)
    {
        lock (_browserSync)
        {
            if (attempt is not null && !IsCurrentBrowserAttempt(attempt)) return;
            if (attempt is null && _browserAuthInvalidated) return;
            _browserAuthInvalidated = true;
            _browserAttempt = null;
            IsWaitingForBrowserAuth = false;
            Notice = null;
            Error = TryClearPkceState() ? message :
                message + " Не удалось удалить временные данные. Проверьте доступ к папке VEX.";
        }
        attempt?.Cancel();
    }

    private bool TryClearPkceState()
    {
        try
        {
            _pkceStateStore.Clear();
            return true;
        }
        catch (Exception error) when (IsAuthStorageError(error))
        {
            return false;
        }
    }

    private void ClearAuthArtifacts()
    {
        BrowserAttempt? attempt = null;
        try
        {
            lock (_browserSync)
            {
                attempt = _browserAttempt;
                _browserAttempt = null;
                _browserAuthInvalidated = true;
                EmailOtpChallenge = null;
                IsWaitingForBrowserAuth = false;
                attempt?.Cancel();
                _pkceStateStore.Clear();
            }
        }
        finally
        {
            attempt?.Cancel();
        }
    }

    private static bool IsAuthStorageError(Exception error) => error is IOException or
        UnauthorizedAccessException or System.Security.Cryptography.CryptographicException or
        System.Text.Json.JsonException;

    private sealed class BrowserAttempt
    {
        private readonly CancellationTokenSource _cancellation = new();
        private int _canceled;
        public BrowserAttempt(string state)
        {
            State = state;
            Token = _cancellation.Token;
        }
        public string State { get; set; }
        public CancellationToken Token { get; }

        public void Cancel()
        {
            if (Interlocked.Exchange(ref _canceled, 1) != 0) return;
            _cancellation.Cancel();
            _cancellation.Dispose();
        }
    }

    private void NotifyChanged() =>
        StateChanged?.Invoke(this, EventArgs.Empty);
}
