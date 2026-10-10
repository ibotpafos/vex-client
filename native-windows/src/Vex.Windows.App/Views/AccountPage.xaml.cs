using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using System.Globalization;
using Windows.System;
using Vex.Windows.App.Auth;
using Vex.Windows.App.Services;
using Vex.Windows.Client.Api;
using Vex.Windows.Client.Auth;
using Vex.Windows.Client.Session;
using Vex.Windows.Core.Presentation;

namespace Vex.Windows.App.Views;

public sealed partial class AccountPage : Page
{
    private static readonly TimeSpan FallbackRefreshInterval =
        TimeSpan.FromSeconds(60);
    private readonly AppServices _services =
        AppServices.Current;
    private NativeClientCoordinator Coordinator =>
        _services.Coordinator;
    private NativeAuthService Auth =>
        _services.Auth;

    private NativeAccountSnapshot? _account;
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _fallbackRefreshTimer;
    private bool _billingRefreshInFlight;
    private bool _billingRefreshPending;
    private int _busyOperations;
    private CancellationTokenSource? _pageLifetime;
    private int _pageGeneration;

    public AccountPage()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
        Render();
    }

    private async void OnLoaded(object sender, RoutedEventArgs args)
    {
        if (_pageLifetime is not null) return;
        _pageLifetime = new CancellationTokenSource();
        _pageGeneration++;
        Auth.StateChanged += OnAuthStateChanged;
        _services.CustomerRealtimeChanged += OnCustomerRealtimeChanged;
        StartFallbackRefreshTimer();
        if (Coordinator.CurrentState is not null)
        {
            await RefreshBillingAsync();
        }

        Render();
        ApplyAuthState();
    }

    private void OnUnloaded(object sender, RoutedEventArgs args)
    {
        _pageGeneration++;
        _pageLifetime?.Cancel();
        _pageLifetime?.Dispose();
        _pageLifetime = null;
        _billingRefreshPending = false;
        Auth.StateChanged -= OnAuthStateChanged;
        _services.CustomerRealtimeChanged -= OnCustomerRealtimeChanged;
        _fallbackRefreshTimer?.Stop();
        _fallbackRefreshTimer = null;
    }

    private void OnCustomerRealtimeChanged(
        object? sender,
        CustomerRealtimeChangedEventArgs args)
    {
        if (!CustomerRealtimeRefreshPolicy.ShouldRefreshAccount(args))
        {
            return;
        }
        DispatcherQueue.TryEnqueue(async () =>
        {
            if (_pageLifetime is not null && Coordinator.CurrentState is not null)
            {
                await RefreshBillingAsync();
            }
        });
    }

    private void OnAuthStateChanged(
        object? sender,
        EventArgs args)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            if (_pageLifetime is null) return;
            Render();
            ApplyAuthState();
            if (Coordinator.CurrentState is not null &&
                _account is null)
            {
                _ = RefreshBillingAsync();
            }
        });
    }

    private async void OnSignInClick(
        object sender,
        RoutedEventArgs args)
    {
        SetBusy(true);
        try
        {
            await Auth.SignInWithPasswordAsync(
                EmailInput.Text,
                PasswordInput.Password,
                CancellationToken.None);
            if (Coordinator.CurrentState is not null)
            {
                PasswordInput.Password = string.Empty;
                EmailOtpCodeInput.Text = string.Empty;
                _account = null;
                await RefreshBillingAsync();
            }
        }
        finally
        {
            SetBusy(false);
            Render();
            ApplyAuthState();
        }
    }

    private async void OnRequestOtpClick(
        object sender,
        RoutedEventArgs args)
    {
        SetBusy(true);
        try
        {
            await Auth.RequestEmailOtpAsync(
                EmailInput.Text,
                CancellationToken.None);
        }
        finally
        {
            SetBusy(false);
            Render();
            ApplyAuthState();
        }
    }

    private async void OnConfirmOtpClick(
        object sender,
        RoutedEventArgs args)
    {
        SetBusy(true);
        try
        {
            await Auth.ConfirmEmailOtpAsync(
                EmailInput.Text,
                EmailOtpCodeInput.Text,
                CancellationToken.None);
            if (Coordinator.CurrentState is not null)
            {
                PasswordInput.Password = string.Empty;
                EmailOtpCodeInput.Text = string.Empty;
                _account = null;
                await RefreshBillingAsync();
            }
        }
        finally
        {
            SetBusy(false);
            Render();
            ApplyAuthState();
        }
    }

    private async void OnGoogleSignInClick(
        object sender,
        RoutedEventArgs args) =>
        await BeginWebsiteAuthAsync(WebAuthMode.Login, WebAuthProvider.Google);

    private async void OnWebsiteSignInClick(
        object sender,
        RoutedEventArgs args) =>
        await BeginWebsiteAuthAsync(WebAuthMode.Login);

    private async void OnWebsiteRegisterClick(
        object sender,
        RoutedEventArgs args) =>
        await BeginWebsiteAuthAsync(WebAuthMode.Register);

    private async Task BeginWebsiteAuthAsync(
        WebAuthMode mode,
        WebAuthProvider? provider = null)
    {
        SetBusy(true);
        try
        {
            await Auth.StartBrowserAuthAsync(
                mode,
                CancellationToken.None,
                provider);
        }
        finally
        {
            SetBusy(false);
            Render();
            ApplyAuthState();
        }
    }

    private void OnCancelWebsiteAuthClick(
        object sender,
        RoutedEventArgs args)
    {
        try
        {
            Auth.CancelBrowserAuth();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or
            System.Security.Cryptography.CryptographicException)
        {
            AccountNotice.Message = "Не удалось отменить вход. Повторите позже.";
            AccountNotice.Severity = InfoBarSeverity.Warning;
            AccountNotice.IsOpen = true;
        }
        Render();
        ApplyAuthState();
    }

    private async void OnUnlockSessionClick(
        object sender,
        RoutedEventArgs args)
    {
        SetBusy(true);
        try
        {
            var app = (App)Application.Current;
            await _services.StateStore.UnlockAsync(
                app.ShellWindowHandle,
                CancellationToken.None);
            Auth.ClearStatus();
            AccountNotice.Message = "Сохраненная сессия открыта.";
            AccountNotice.Severity = InfoBarSeverity.Success;
            AccountNotice.IsOpen = true;
            if (Coordinator.CurrentState is not null)
            {
                await RefreshBillingAsync();
            }
        }
        catch (Exception error) when (error is InvalidOperationException or IOException or
            UnauthorizedAccessException or System.Security.Cryptography.CryptographicException or
            OperationCanceledException or System.Runtime.InteropServices.COMException)
        {
            AccountNotice.Message = error.Message;
            AccountNotice.Severity = InfoBarSeverity.Warning;
            AccountNotice.IsOpen = true;
        }
        finally
        {
            SetBusy(false);
            Render();
        }
    }

    private async void OnSignOutClick(
        object sender,
        RoutedEventArgs args)
    {
        SetBusy(true);
        try
        {
            _services.VpnUiState.MarkConnectionDesired(false);
            await _services.VpnUiState.RunAsync(async token =>
            {
                await Coordinator.SignOutAsync(token);
                return await _services.VpnClient.GetDiagnosticsAsync(token);
            }, CancellationToken.None);
        }
        catch (Exception error) when (
            error is IOException or
                UnauthorizedAccessException or
                System.Security.Cryptography.CryptographicException or
                InvalidOperationException or
                OperationCanceledException or
                Vex.Windows.Core.Vpn.Ipc.VpnIpcProtocolException)
        {
            AccountNotice.Message =
                Coordinator.CurrentState is null
                    ? "Сессия удалена, но VPN-служба не ответила."
                    : "Не удалось завершить выход. Повторите позже.";
            AccountNotice.Severity = InfoBarSeverity.Warning;
            AccountNotice.IsOpen = true;
        }
        finally
        {
            PasswordInput.Password = string.Empty;
            EmailOtpCodeInput.Text = string.Empty;
            _account = null;
            Auth.ClearStatus();
            SetBusy(false);
            Render();
        }
    }

    private void SetBusy(bool busy)
    {
        _busyOperations = Math.Max(0, _busyOperations + (busy ? 1 : -1));
        busy = _busyOperations > 0;
        BusyIndicator.IsActive = busy;
        BusyIndicator.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        SignInButton.IsEnabled = !busy;
        RequestOtpButton.IsEnabled = !busy;
        ConfirmOtpButton.IsEnabled = !busy;
        ResendOtpButton.IsEnabled = !busy;
        GoogleSignInButton.IsEnabled = !busy;
        WebsiteSignInButton.IsEnabled = !busy;
        WebsiteRegisterButton.IsEnabled = !busy;
        CancelWebsiteAuthButton.IsEnabled = !busy;
        UnlockSessionButton.IsEnabled = !busy;
        var authBusy = _busyOperations > (_billingRefreshInFlight ? 1 : 0);
        SignOutButton.IsEnabled = !authBusy;
        EmailInput.IsEnabled = !busy;
        PasswordInput.IsEnabled = !busy;
        EmailOtpCodeInput.IsEnabled = !busy;
        RefreshBillingButton.IsEnabled = !busy;
        CheckoutButton.IsEnabled = !authBusy;
        EmailLoginExpander.IsEnabled = !busy;
    }

    private void Render()
    {
        var state = Coordinator.CurrentState;
        var signedIn = state is not null;
        if (!signedIn || !string.Equals(
                _account?.UserId,
                state?.Session.User.Id,
                StringComparison.Ordinal))
        {
            _account = null;
        }
        var locked =
            Coordinator.CurrentStateAccess == ClientStateAccessKind.Locked;
        var waitingForBrowserAuth = Auth.IsWaitingForBrowserAuth;
        var otpChallenge = Auth.EmailOtpChallenge;

        AccountStatus.Text = signedIn ? state!.Session.User.Email : "Аккаунт VEX";
        AccountInitials.Text = AccountInitialsFor(state?.Session.User.Email);
        AuthHeadingText.Text = waitingForBrowserAuth ? "Подтвердите вход" : "Вход в VEX";
        AuthSubtitleText.Text = waitingForBrowserAuth
            ? "Окно VEX ожидает разрешение на сайте."
            : "Продолжите в браузере.";
        SignInStatusText.Text = locked
                ? _services.StateStore.StoredSessionError ??
                    "Сохраненная сессия заблокирована. Подтвердите Windows Hello или выполните новый вход."
                : waitingForBrowserAuth
                    ? "Подтвердите вход на сайте и вернитесь в VEX."
                    : _services.StateStore.StoredSessionError ??
                        (!signedIn ? Auth.Error ?? Auth.Notice : null) ?? string.Empty;
        SignInStatusText.Visibility = string.IsNullOrWhiteSpace(SignInStatusText.Text) || waitingForBrowserAuth
            ? Visibility.Collapsed : Visibility.Visible;
        LoginBrandPanel.Visibility = signedIn ? Visibility.Collapsed : Visibility.Visible;
        BrowserWaitingPanel.Visibility = waitingForBrowserAuth ? Visibility.Visible : Visibility.Collapsed;
        RegistrationPanel.Visibility = signedIn || waitingForBrowserAuth ? Visibility.Collapsed : Visibility.Visible;
        EmailLoginExpander.Visibility = signedIn || waitingForBrowserAuth ? Visibility.Collapsed : Visibility.Visible;
        if (!signedIn && otpChallenge is not null) EmailLoginExpander.IsExpanded = true;
        EmailOtpHintText.Text = otpChallenge is null
            ? string.Empty
            : BuildOtpHint(otpChallenge);
        EmailOtpHintText.Visibility = !signedIn && otpChallenge is not null && !waitingForBrowserAuth
            ? Visibility.Visible
            : Visibility.Collapsed;
        GoogleSignInButton.Visibility = signedIn || waitingForBrowserAuth
            ? Visibility.Collapsed
            : Visibility.Visible;
        AuthHintText.Text = signedIn
            ? _account?.Entitlement.RemainingText ??
                (_account is null ? "Данные обновятся автоматически" : _account.Entitlement.HasPaidAccess
                    ? "VPN-доступ активен"
                    : "Оформите подписку для VPN-доступа")
            : otpChallenge is null
                ? "Доступны вход через сайт, email OTP и локальная разблокировка сохраненной сессии."
                : BuildOtpHint(otpChallenge);
        UnlockSessionButton.Visibility = locked
            ? Visibility.Visible
            : Visibility.Collapsed;
        EmailInput.Visibility = signedIn || waitingForBrowserAuth
            ? Visibility.Collapsed
            : Visibility.Visible;
        PasswordInput.Visibility =
            signedIn || waitingForBrowserAuth
                ? Visibility.Collapsed
                : Visibility.Visible;
        EmailOtpCodeInput.Visibility =
            signedIn || otpChallenge is null || waitingForBrowserAuth
                ? Visibility.Collapsed
                : Visibility.Visible;
        SignInButton.Visibility =
            signedIn || waitingForBrowserAuth
                ? Visibility.Collapsed
                : Visibility.Visible;
        RequestOtpButton.Visibility =
            signedIn || otpChallenge is not null || waitingForBrowserAuth
                ? Visibility.Collapsed
                : Visibility.Visible;
        ConfirmOtpButton.Visibility =
            signedIn || otpChallenge is null || waitingForBrowserAuth
                ? Visibility.Collapsed
                : Visibility.Visible;
        ResendOtpButton.Visibility =
            signedIn || otpChallenge is null || waitingForBrowserAuth
                ? Visibility.Collapsed
                : Visibility.Visible;
        WebsiteSignInButton.Visibility =
            signedIn || waitingForBrowserAuth
                ? Visibility.Collapsed
                : Visibility.Visible;
        WebsiteRegisterButton.Visibility =
            signedIn || waitingForBrowserAuth
                ? Visibility.Collapsed
                : Visibility.Visible;
        CancelWebsiteAuthButton.Visibility =
            waitingForBrowserAuth
                ? Visibility.Visible
                : Visibility.Collapsed;
        SignOutButton.Visibility = signedIn
            ? Visibility.Visible
            : Visibility.Collapsed;
        AuthPanel.Visibility = signedIn
            ? Visibility.Collapsed
            : Visibility.Visible;
        AccountSummaryPanel.Visibility = signedIn
            ? Visibility.Visible
            : Visibility.Collapsed;
        BillingPanel.Visibility = signedIn
            ? Visibility.Visible
            : Visibility.Collapsed;
        DeviceUsagePanel.Visibility = signedIn
            ? Visibility.Visible
            : Visibility.Collapsed;
        PaymentHistoryPanel.Visibility = signedIn
            ? Visibility.Visible
            : Visibility.Collapsed;
        AccountAccessBadgeText.Text = signedIn
            ? _account?.Entitlement.HasPaidAccess == true
                ? "Активен"
                : _account is null
                    ? "Проверка"
                    : "Нет"
            : "Нет";
        var paidAccess = _account?.Entitlement.HasPaidAccess == true;
        AccountAccessBadge.Background = ColorBrush(paidAccess ? 0x2922D3EEu :
            _account is null ? 0x14FFFFFFu : 0x26FF9E2Eu);
        AccountAccessBadgeText.Foreground = ColorBrush(paidAccess ? 0xFFB9FBFFu :
            _account is null ? 0xFFA7B9BDu : 0xFFFFC25Cu);
        AccountPlanFact.Foreground = ColorBrush(paidAccess ? 0xFFB9FBFFu : 0xFFA7B9BDu);

        if (!signedIn || _account is null)
        {
            BillingTitle.Text = "Подписка";
            BillingSubtitle.Text = signedIn
                ? "Проверяем текущий тариф."
                : "Войдите, чтобы увидеть статус подписки.";
            BillingPlan.Text = "Тариф: —";
            BillingAccess.Text = "Доступ: —";
            BillingPeriod.Text = "Период: —";
            CheckoutButton.Visibility = signedIn
                ? Visibility.Visible
                : Visibility.Collapsed;
            DeviceUsageList.ItemsSource = null;
            PaymentHistoryList.ItemsSource = null;
            AccountPlanFact.Text = signedIn ? "Проверяем подписку" : "Требуется вход";
            AccountStatusFact.Text = signedIn ? "Статус: проверяем" : "Статус: нет доступа";
            PaymentHistoryList.Visibility = Visibility.Collapsed;
            PaymentHistoryEmpty.Visibility = Visibility.Visible;
            PaymentHistoryStatusText.Text = "История пока недоступна.";
            PaymentHistoryEmptyTitle.Text = "Ожидаем историю оплат";
            PaymentHistoryEmptyDescription.Text = "Обновите подписку, чтобы загрузить последние операции.";
            DeviceUsageSummary.Text = "Устройства пока недоступны. Обновите подписку, чтобы повторить загрузку.";
            DeviceSectionStatusText.Visibility = Visibility.Collapsed;
            return;
        }

        var summary = _account.BillingSummary;
        BillingTitle.Text = "Подписка";
        var currentSummary = _account.BillingSummaryStatus.IsCurrent;
        BillingSubtitle.Text = currentSummary ? "Оплата и управление подпиской — на сайте VEX"
            : _account.BillingSummaryStatus.HasData ? "Тарифы не обновлены; показаны сохранённые данные."
                : "Тарифы недоступны. Статус подписки подтверждён сервером; оплата доступна на сайте.";
        var planName = currentSummary ? summary.CurrentPlan?.Name
            : _account.Entitlement.DisplayName ?? _account.Entitlement.SubscriptionTitle ?? _account.Entitlement.PlanId;
        BillingPlan.Text = $"Тариф: {planName ?? "Не выбран"}" + (!currentSummary && _account.BillingSummaryStatus.HasData ? " (сохранённый каталог)" : string.Empty);
        BillingAccess.Text = $"Доступ: {AccessText(_account.Entitlement)}";
        BillingPeriod.Text = $"Период: {(currentSummary ? summary.RemainingText ?? summary.CurrentPeriodEnd ?? summary.EffectiveExpiresAt
            : _account.Entitlement.RemainingText ?? _account.Entitlement.CurrentPeriodEnd ?? _account.Entitlement.EffectiveExpiresAt) ?? "Уточняется"}";
        CheckoutButton.Visibility = Visibility.Visible;
        AccountPlanFact.Text =
            planName ?? AccessText(_account.Entitlement);
        AccountStatusFact.Text = "Статус: " + (_account.Entitlement.HasPaidAccess
            ? LocalizeSubscriptionStatus(currentSummary ? summary.Status : _account.Entitlement.Status, true)
            : "Нет VPN-доступа");
        RenderDevices(_account);
        RenderPayments(_account);
    }

    private void RenderDevices(NativeAccountSnapshot account)
    {
        var statuses = new List<string>();
        if (Coordinator.CurrentState?.VpnProvisioningPending == true)
            statuses.Add("Это устройство будет зарегистрировано для VPN при первом подключении.");
        if (!account.DevicesStatus.IsCurrent)
            statuses.Add(account.DevicesStatus.HasData ? "Устройства не обновлены; показаны сохранённые данные." : "Список устройств недоступен.");
        if (!account.DeviceUsageStatus.IsCurrent)
            statuses.Add(account.DeviceUsageStatus.HasData ? "Трафик не обновлён; показаны сохранённые данные." : "Трафик недоступен.");
        DeviceSectionStatusText.Text = string.Join(" ", statuses);
        DeviceSectionStatusText.Visibility = statuses.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        var usageByDevice = account.DeviceUsage
            .GroupBy(usage => usage.DeviceId)
            .ToDictionary(
                group => group.Key,
                group => group.First(),
                StringComparer.Ordinal);
        var rows = account.Devices
            .Select(device =>
            {
                usageByDevice.TryGetValue(device.Id, out var usage);
                return new DeviceUsageView(
                    device.Name,
                    account.DevicesStatus.IsCurrent && account.DeviceUsageStatus.IsCurrent
                        ? LocalizeDeviceStatus(device.Status, usage) : "Не обновлено",
                    string.Join(
                        " · ",
                        new[]
                        {
                            device.Platform,
                            device.ProtocolLabel ?? device.Protocol,
                            device.AppVersion,
                        }.Where(value =>
                            !string.IsNullOrWhiteSpace(value))),
                    !account.DeviceUsageStatus.HasData ? "Трафик недоступен"
                        : usage is null ? "Трафик: нет данных"
                        : (account.DeviceUsageStatus.IsCurrent ? string.Empty : "Сохранено: ") +
                            $"↓ {FormatBytes(usage.RxBytes)}  ↑ {FormatBytes(usage.TxBytes)}  Всего {FormatBytes(usage.TotalBytes)}");
            })
            .ToList();
        DeviceUsageList.ItemsSource = rows;
        DeviceUsageSummary.Text = !account.DevicesStatus.HasData ? "Список устройств не удалось загрузить. Повторите обновление." : rows.Count == 0
            ? "Зарегистрированных устройств пока нет."
            : Coordinator.CurrentState?.VpnProvisioningPending == true
                ? $"Устройств в аккаунте: {rows.Count}."
            : $"Устройств: {rows.Count}. Текущее расположение: " +
                $"{NativeLocationLabel.Russian(account.LocationId)}.";
    }

    private void RenderPayments(NativeAccountSnapshot account)
    {
        PaymentHistoryStatusText.Text = account.PaymentsStatus.IsCurrent ? "Последние операции по подписке"
            : account.PaymentsStatus.HasData ? "История не обновлена; показаны сохранённые оплаты." : "История оплат недоступна. Повторите обновление.";
        PaymentHistoryEmptyTitle.Text = !account.PaymentsStatus.HasData ? "История оплат недоступна"
            : account.PaymentsStatus.IsCurrent ? "Оплат пока нет" : "В сохранённой истории оплат нет";
        PaymentHistoryEmptyDescription.Text = account.PaymentsStatus.IsCurrent
            ? "Покупки и продления появятся здесь." : "Обновите подписку, чтобы повторить загрузку истории.";
        var rows = account.Payments
            .OrderByDescending(payment =>
                ParseTimestamp(
                    payment.PaidAt ?? payment.CreatedAt))
            .Take(6)
            .Select(payment => new PaymentHistoryView(
                payment.Id,
                PaymentPlanName(payment.PlanId),
                FormatMoney(
                    payment.AmountMinor,
                    payment.Currency),
                LocalizePaymentStatus(payment.Status),
                FormatTimestamp(
                    payment.PaidAt ?? payment.CreatedAt),
                PaymentGlyph(payment.Status),
                ColorBrush(PaymentIsPaid(payment.Status) ? 0xFFB9FBFFu :
                    PaymentIsWarning(payment.Status) ? 0xFFFFC25Cu : 0xFFA7B9BDu),
                ColorBrush(PaymentIsPaid(payment.Status) ? 0x2922D3EEu :
                    PaymentIsWarning(payment.Status) ? 0x26FF9E2Eu : 0x14FFFFFFu)))
            .ToList();
        PaymentHistoryList.ItemsSource = rows;
        PaymentHistoryList.Visibility = rows.Count == 0
            ? Visibility.Collapsed
            : Visibility.Visible;
        PaymentHistoryEmpty.Visibility = rows.Count == 0
            ? Visibility.Visible
            : Visibility.Collapsed;
    }

    private async Task RefreshBillingAsync()
    {
        if (_pageLifetime is null || Coordinator.CurrentState is null) return;
        if (_billingRefreshInFlight)
        {
            _billingRefreshPending = true;
            return;
        }
        _billingRefreshInFlight = true;
        SetBusy(true);
        var requestGeneration = _pageGeneration;
        string? requestUserId = null;
        var pageToken = _pageLifetime.Token;
        try
        {
            do
            {
                _billingRefreshPending = false;
                requestUserId = Coordinator.CurrentState?.Session.User.Id;
                if (requestUserId is null || pageToken.IsCancellationRequested) break;
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(pageToken);
                timeout.CancelAfter(TimeSpan.FromSeconds(45));
                var account = await Coordinator.GetAccountSnapshotAsync(timeout.Token);
                if (IsCurrentBillingRequest(requestGeneration, requestUserId, pageToken))
                {
                    _account = account;
                    if (string.IsNullOrWhiteSpace(Auth.Error)) AccountNotice.IsOpen = false;
                }
                if (requestGeneration != _pageGeneration) break;
            }
            while (_billingRefreshPending);
        }
        catch (Exception error) when (
            error is HttpRequestException or
                OperationCanceledException or
                VexApiException or
                NativeClientFlowException or IOException or UnauthorizedAccessException or
                System.Security.Cryptography.CryptographicException or InvalidOperationException)
        {
            if (!IsCurrentBillingRequest(requestGeneration, requestUserId, pageToken))
            {
                if (error is NativeClientFlowException { Code: "sign_in_required" } &&
                    !pageToken.IsCancellationRequested && _pageLifetime is not null &&
                    requestGeneration == _pageGeneration && Coordinator.CurrentState is null)
                {
                    AccountNotice.Message = "Сессия истекла. Войдите снова, чтобы продолжить работу с VEX.";
                    AccountNotice.Severity = InfoBarSeverity.Warning;
                    AccountNotice.IsOpen = true;
                }
                return;
            }
            if (_account is not null && Coordinator.CurrentState?.CachedEntitlement is { } entitlement)
                _account = _account with { Entitlement = entitlement,
                    BillingSummaryStatus = new(NativeAccountSectionAvailability.Cached, "request_failed") };
            AccountNotice.Message = error switch
            {
                NativeClientFlowException flow when
                    flow.Code == "windows_hello_required" =>
                    "Сначала разблокируйте сохраненную сессию через Windows Hello.",
                _ => "Не удалось обновить подписку. Повторите позже.",
            };
            AccountNotice.Severity = InfoBarSeverity.Warning;
            AccountNotice.IsOpen = true;
        }
        finally
        {
            _billingRefreshInFlight = false;
            SetBusy(false);
            Render();
            if (_billingRefreshPending && _pageLifetime is not null && Coordinator.CurrentState is not null)
            {
                _billingRefreshPending = false;
                _ = RefreshBillingAsync();
            }
        }
    }

    private bool IsCurrentBillingRequest(int generation, string? userId, CancellationToken token) =>
        !token.IsCancellationRequested && _pageLifetime is not null && generation == _pageGeneration &&
        userId is not null && Coordinator.CurrentState?.Session.User.Id == userId;

    private void StartFallbackRefreshTimer()
    {
        _fallbackRefreshTimer ??= DispatcherQueue.CreateTimer();
        _fallbackRefreshTimer.Interval = FallbackRefreshInterval;
        _fallbackRefreshTimer.IsRepeating = true;
        _fallbackRefreshTimer.Tick -= OnFallbackRefreshTimerTick;
        _fallbackRefreshTimer.Tick += OnFallbackRefreshTimerTick;
        _fallbackRefreshTimer.Start();
    }

    private async void OnFallbackRefreshTimerTick(
        Microsoft.UI.Dispatching.DispatcherQueueTimer sender,
        object args)
    {
        if (!_services.Realtime.IsConnected &&
            Coordinator.CurrentState is not null)
        {
            await RefreshBillingAsync();
        }
    }

    private async void OnRefreshBillingClick(
        object sender,
        RoutedEventArgs args) =>
        await RefreshBillingAsync();

    private async void OnOpenBillingWebsiteClick(
        object sender,
        RoutedEventArgs args)
    {
        try
        {
            await LaunchUrlAsync("https://vexguard.app/dashboard");
        }
        catch (Exception error) when (
            error is InvalidOperationException or
                System.Runtime.InteropServices.COMException)
        {
            AccountNotice.Message = "Не удалось открыть сайт оплаты.";
            AccountNotice.Severity = InfoBarSeverity.Error;
            AccountNotice.IsOpen = true;
        }
    }

    private async void OnPaymentHistoryItemClick(object sender, ItemClickEventArgs args)
    {
        if (args.ClickedItem is not PaymentHistoryView payment) return;
        try
        {
            await LaunchUrlAsync($"https://vexguard.app/dashboard/payments/{Uri.EscapeDataString(payment.Id)}/receipt");
        }
        catch (Exception error) when (error is InvalidOperationException or
            System.Runtime.InteropServices.COMException)
        {
            AccountNotice.Message = "Не удалось открыть оплату в кабинете VEX.";
            AccountNotice.Severity = InfoBarSeverity.Warning;
            AccountNotice.IsOpen = true;
        }
    }

    private void ApplyAuthState()
    {
        if (!string.IsNullOrWhiteSpace(Auth.Error))
        {
            AccountNotice.Message = Auth.Error;
            AccountNotice.Severity = InfoBarSeverity.Error;
            AccountNotice.IsOpen = true;
            return;
        }

        if (!string.IsNullOrWhiteSpace(Auth.Notice))
        {
            AccountNotice.Message = Auth.Notice;
            AccountNotice.Severity = InfoBarSeverity.Success;
            AccountNotice.IsOpen = true;
        }
    }

    private static string BuildOtpHint(
        NativeEmailOtpChallenge challenge)
    {
        if (challenge.ExpiresAt is null)
        {
            return $"Код отправлен на {challenge.Email}.";
        }

        return $"Код отправлен на {challenge.Email}. Действует до {challenge.ExpiresAt.Value.LocalDateTime:HH:mm}.";
    }

    private static async Task LaunchUrlAsync(string? url)
    {
        if (UiPreviewContext.IsEnabled) return;
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri))
        {
            throw new InvalidOperationException("billing_url_invalid");
        }

        var launched = await Launcher.LaunchUriAsync(uri);
        if (!launched)
        {
            throw new InvalidOperationException("billing_launch_failed");
        }
    }

    private static string AccessText(VexEntitlement entitlement)
    {
        if (entitlement.HasPaidAccess)
        {
            return entitlement.DisplayName ??
                entitlement.SubscriptionTitle ??
                "Активен";
        }

        return "Нет активной подписки";
    }

    private static string LocalizeSubscriptionStatus(
        string? status,
        bool hasAccess) =>
        (status ?? string.Empty).Trim().ToLowerInvariant() switch
        {
            "active" or "trialing" => "Активна",
            "canceled" => "Отменена",
            "past_due" or "unpaid" => "Нужна оплата",
            "expired" => "Истекла",
            _ => hasAccess ? "Активна" : "Не активна",
        };

    private static string LocalizeDeviceStatus(
        string status,
        VpnDeviceUsage? usage)
    {
        if (usage?.Connected == true)
        {
            return "Подключено";
        }

        return (usage?.ConnectionStatus ?? status)
            .Trim()
            .ToLowerInvariant() switch
        {
            "active" => "Активно",
            "connected" => "Подключено",
            "stale" => "Нет свежего handshake",
            "revoked" => "Отозвано",
            "disabled" => "Отключено",
            _ => "Не подключено",
        };
    }

    private static string LocalizePaymentStatus(string status) =>
        status.Trim().ToLowerInvariant() switch
        {
            "paid" or "succeeded" or "success" or "completed" or "manual" => "Оплачено",
            "pending" or "processing" or "open" => "Ожидает оплаты",
            "failed" or "declined" => "Ошибка",
            "refunded" => "Возврат",
            "canceled" => "Отменено",
            _ => string.IsNullOrWhiteSpace(status)
                ? "Статус не указан"
                : status,
        };

    private static bool PaymentIsPaid(string status) => status.Trim().ToLowerInvariant() is
        "paid" or "succeeded" or "success" or "completed" or "manual";

    private static bool PaymentIsWarning(string status) => status.Trim().ToLowerInvariant() is
        "pending" or "processing" or "open" or "failed" or "declined";

    private static string PaymentGlyph(string status) => status.Trim().ToLowerInvariant() switch
    {
        "paid" or "succeeded" or "success" or "completed" or "manual" => "\uE73E",
        "pending" or "processing" or "open" => "\uE823",
        "refunded" => "\uE7A7",
        "failed" or "declined" => "\uE711",
        _ => "\uE8C7",
    };

    private static string PaymentPlanName(string? planId)
    {
        if (string.IsNullOrWhiteSpace(planId)) return "Подписка VEX";
        var normalized = planId.ToLowerInvariant();
        var tier = normalized.Contains("business") ? "Бизнес" :
            normalized.Contains("family") || normalized.Contains("team") ? "Team" :
            normalized.Contains("pro") ? "Pro" : normalized.Contains("basic") ? "Базовый" :
            CultureInfo.GetCultureInfo("ru-RU").TextInfo.ToTitleCase(planId.Replace('_', ' ').Replace('-', ' '));
        var period = normalized.Contains("semiannual") ? "6 месяцев" :
            normalized.Contains("quarter") ? "3 месяца" :
            normalized.Contains("annual") || normalized.Contains("year") ? "год" :
            normalized.Contains("month") ? "месяц" : null;
        return period is null ? tier : $"{tier} · {period}";
    }

    private static string AccountInitialsFor(string? email)
    {
        var name = email?.Split('@')[0] ?? string.Empty;
        var pieces = name.Split(['.', '_', '-', ' '], StringSplitOptions.RemoveEmptyEntries);
        return pieces.Length == 0 ? "V" :
            string.Concat(pieces.Take(2).Select(piece => piece[..1])).ToUpperInvariant();
    }

    private static SolidColorBrush ColorBrush(uint argb) => new(global::Windows.UI.Color.FromArgb(
        (byte)(argb >> 24), (byte)(argb >> 16), (byte)(argb >> 8), (byte)argb));

    private static string FormatBytes(long? value)
    {
        if (value is null)
        {
            return "—";
        }

        var bytes = Math.Max(0, value.Value);
        string[] units = ["Б", "КБ", "МБ", "ГБ", "ТБ"];
        var amount = (double)bytes;
        var unit = 0;
        while (amount >= 1024 && unit < units.Length - 1)
        {
            amount /= 1024;
            unit++;
        }

        return $"{amount:0.#} {units[unit]}";
    }

    private static string FormatMoney(
        int amountMinor,
        string currency)
    {
        var amount = amountMinor / 100m;
        try
        {
            var format = (NumberFormatInfo)
                CultureInfo.GetCultureInfo("ru-RU")
                    .NumberFormat.Clone();
            format.CurrencySymbol = currency.ToUpperInvariant() switch
            {
                "RUB" => "₽",
                "USD" => "$",
                "EUR" => "€",
                _ => currency.ToUpperInvariant(),
            };
            format.CurrencyDecimalDigits = amountMinor % 100 == 0 ? 0 : 2;
            return amount.ToString("C", format);
        }
        catch (ArgumentException)
        {
            return $"{amount:0.##} {currency.ToUpperInvariant()}";
        }
    }

    private static DateTimeOffset ParseTimestamp(string value) =>
        DateTimeOffset.TryParse(value, out var timestamp)
            ? timestamp
            : DateTimeOffset.MinValue;

    private static string FormatTimestamp(string value)
    {
        var timestamp = ParseTimestamp(value);
        return timestamp == DateTimeOffset.MinValue
            ? value
            : timestamp.ToLocalTime().ToString("dd.MM.yyyy HH:mm");
    }

    private sealed record DeviceUsageView(
        string Name,
        string Status,
        string Meta,
        string Usage);

    private sealed record PaymentHistoryView(
        string Id,
        string Title,
        string Amount,
        string Status,
        string Date,
        string Glyph,
        Brush StatusForeground,
        Brush StatusBackground);
}
