using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
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
    private readonly AppServices _services =
        AppServices.Current;
    private NativeClientCoordinator Coordinator =>
        _services.Coordinator;
    private NativeAuthService Auth =>
        _services.Auth;

    private NativeAccountSnapshot? _account;
    private string? _selectedPlanId;

    public AccountPage()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
        Render();
    }

    private async void OnLoaded(object sender, RoutedEventArgs args)
    {
        Auth.StateChanged += OnAuthStateChanged;
        _services.CustomerRealtimeChanged += OnCustomerRealtimeChanged;
        if (Coordinator.CurrentState is not null)
        {
            await RefreshBillingAsync();
        }

        Render();
        ApplyAuthState();
    }

    private void OnUnloaded(object sender, RoutedEventArgs args)
    {
        Auth.StateChanged -= OnAuthStateChanged;
        _services.CustomerRealtimeChanged -= OnCustomerRealtimeChanged;
    }

    private void OnCustomerRealtimeChanged(
        object? sender,
        CustomerRealtimeChangedEventArgs args)
    {
        if (args.Event.Type != "customer.resync" &&
            !args.Metadata.Domains.Any(domain => domain is
                "account" or
                "entitlement" or
                "billing" or
                "devices" or
                "family"))
        {
            return;
        }
        DispatcherQueue.TryEnqueue(async () =>
        {
            if (Coordinator.CurrentState is not null)
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

    private async void OnWebsiteSignInClick(
        object sender,
        RoutedEventArgs args) =>
        await BeginWebsiteAuthAsync(WebAuthMode.Login);

    private async void OnWebsiteRegisterClick(
        object sender,
        RoutedEventArgs args) =>
        await BeginWebsiteAuthAsync(WebAuthMode.Register);

    private async Task BeginWebsiteAuthAsync(
        WebAuthMode mode)
    {
        SetBusy(true);
        try
        {
            await Auth.StartBrowserAuthAsync(
                mode,
                CancellationToken.None);
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
        Auth.CancelBrowserAuth();
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
        catch (InvalidOperationException error)
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
            await Coordinator.SignOutAsync(CancellationToken.None);
            PasswordInput.Password = string.Empty;
            EmailOtpCodeInput.Text = string.Empty;
            _account = null;
            Auth.ClearStatus();
        }
        catch (Exception error) when (
            error is IOException or
                UnauthorizedAccessException or
                System.Security.Cryptography.CryptographicException or
                InvalidOperationException)
        {
            AccountNotice.Message =
                "Сессия удалена, но VPN-служба не ответила.";
            AccountNotice.Severity = InfoBarSeverity.Warning;
            AccountNotice.IsOpen = true;
        }
        finally
        {
            SetBusy(false);
            Render();
        }
    }

    private void SetBusy(bool busy)
    {
        BusyIndicator.IsActive = busy;
        SignInButton.IsEnabled = !busy;
        RequestOtpButton.IsEnabled = !busy;
        ConfirmOtpButton.IsEnabled = !busy;
        ResendOtpButton.IsEnabled = !busy;
        WebsiteSignInButton.IsEnabled = !busy;
        WebsiteRegisterButton.IsEnabled = !busy;
        CancelWebsiteAuthButton.IsEnabled = !busy;
        UnlockSessionButton.IsEnabled = !busy;
        SignOutButton.IsEnabled = !busy;
        EmailInput.IsEnabled = !busy;
        PasswordInput.IsEnabled = !busy;
        EmailOtpCodeInput.IsEnabled = !busy;
        RefreshBillingButton.IsEnabled = !busy;
        CheckoutButton.IsEnabled = !busy &&
            (PlanSelector.SelectedItem as PlanOptionView)?.Disabled != true;
        PortalButton.IsEnabled = !busy;
        CancelSubscriptionButton.IsEnabled = !busy;
        PlanSelector.IsEnabled = !busy;
    }

    private void Render()
    {
        var state = Coordinator.CurrentState;
        var signedIn = state is not null;
        var locked =
            Coordinator.CurrentStateAccess == ClientStateAccessKind.Locked;
        var waitingForBrowserAuth = Auth.IsWaitingForBrowserAuth;
        var otpChallenge = Auth.EmailOtpChallenge;

        AccountStatus.Text = signedIn
            ? $"{state!.Session.User.Email} · " +
                NativeLocationLabel.Russian(state.LocationId)
            : locked
                ? "Сохраненная сессия заблокирована. Подтвердите Windows Hello или выполните новый вход."
                : waitingForBrowserAuth
                    ? "Подтвердите вход на сайте и вернитесь в VEX."
                    : "Войдите, чтобы зарегистрировать этот компьютер.";
        AuthHintText.Text = otpChallenge is null
            ? "Доступны вход через сайт, email OTP и локальная разблокировка сохраненной сессии."
            : BuildOtpHint(otpChallenge);
        UnlockSessionButton.Visibility = locked
            ? Visibility.Visible
            : Visibility.Collapsed;
        EmailInput.Visibility = signedIn
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
                ? "АКТИВЕН"
                : _account is null
                    ? "ПРОВЕРКА"
                    : "НЕТ"
            : "НЕТ";

        if (!signedIn || _account is null)
        {
            BillingTitle.Text = "Подписка";
            BillingSubtitle.Text = signedIn
                ? "Проверяем текущий тариф."
                : "Войдите, чтобы увидеть статус подписки.";
            BillingPlan.Text = "Тариф: —";
            BillingAccess.Text = "Доступ: —";
            BillingPeriod.Text = "Период: —";
            CheckoutButton.Content = "Открыть оплату";
            CheckoutButton.Visibility = signedIn
                ? Visibility.Visible
                : Visibility.Collapsed;
            PortalButton.Visibility = signedIn
                ? Visibility.Visible
                : Visibility.Collapsed;
            CancelSubscriptionButton.Visibility =
                Visibility.Collapsed;
            PlanSelector.ItemsSource = null;
            DeviceUsageList.ItemsSource = null;
            PaymentHistoryList.ItemsSource = null;
            AccountPlanFact.Text = "—";
            AccountStatusFact.Text = signedIn ? "Проверка" : "Нет";
            return;
        }

        var summary = _account.BillingSummary;
        BillingTitle.Text = summary.Title;
        BillingSubtitle.Text = summary.Subtitle;
        BillingPlan.Text = $"Тариф: {summary.CurrentPlan?.Name ?? "Не выбран"}";
        BillingAccess.Text = $"Доступ: {AccessText(_account.Entitlement)}";
        BillingPeriod.Text = $"Период: {summary.RemainingText ?? summary.CurrentPeriodEnd ?? summary.EffectiveExpiresAt ?? "Уточняется"}";
        CheckoutButton.Content = summary.CurrentPlan is null
            ? "Открыть оплату"
            : summary.CurrentPlan.Action;
        CheckoutButton.Visibility = summary.Plans.Count > 0
            ? Visibility.Visible
            : Visibility.Collapsed;
        PortalButton.Visibility = Visibility.Visible;
        CancelSubscriptionButton.Visibility =
            summary.EntitlementStatus == "active" &&
            !string.Equals(summary.Status, "canceled", StringComparison.OrdinalIgnoreCase)
                ? Visibility.Visible
                : Visibility.Collapsed;
        AccountPlanFact.Text =
            summary.CurrentPlan?.Name ?? "Не выбран";
        AccountStatusFact.Text =
            LocalizeSubscriptionStatus(
                summary.Status,
                _account.Entitlement.HasPaidAccess);
        RenderPlans(summary);
        RenderDevices(_account);
        RenderPayments(_account.Payments);
    }

    private void RenderPlans(BillingSummary summary)
    {
        var options = summary.Plans
            .Select(plan => new PlanOptionView(
                plan.Id,
                plan.Name,
                $"{plan.Name} · {plan.Meta}",
                plan.Action,
                plan.Disabled))
            .ToList();
        PlanSelector.ItemsSource = options;

        var desiredPlanId = _selectedPlanId ??
            summary.CurrentPlan?.Id;
        var selected = options.FirstOrDefault(option =>
                option.Id == desiredPlanId) ??
            options.FirstOrDefault(option => !option.Disabled);
        if (selected is not null)
        {
            _selectedPlanId = selected.Id;
            PlanSelector.SelectedItem = selected;
            SelectedPlanHint.Text =
                $"{selected.Action}: {selected.Name}";
        }
        else
        {
            _selectedPlanId = null;
            SelectedPlanHint.Text =
                summary.EmptyMessage;
        }
    }

    private void RenderDevices(NativeAccountSnapshot account)
    {
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
                    LocalizeDeviceStatus(device.Status, usage),
                    string.Join(
                        " · ",
                        new[]
                        {
                            device.Platform,
                            device.ProtocolLabel ?? device.Protocol,
                            device.AppVersion,
                        }.Where(value =>
                            !string.IsNullOrWhiteSpace(value))),
                    usage is null
                        ? "Трафик: нет данных"
                        : $"↓ {FormatBytes(usage.RxBytes)}  ↑ {FormatBytes(usage.TxBytes)}  Всего {FormatBytes(usage.TotalBytes)}");
            })
            .ToList();
        DeviceUsageList.ItemsSource = rows;
        DeviceUsageSummary.Text = rows.Count == 0
            ? "Зарегистрированных устройств пока нет."
            : $"Устройств: {rows.Count}. Текущее расположение: " +
                $"{NativeLocationLabel.Russian(account.LocationId)}.";
    }

    private void RenderPayments(
        IReadOnlyList<BillingPayment> payments)
    {
        var rows = payments
            .OrderByDescending(payment =>
                ParseTimestamp(
                    payment.PaidAt ?? payment.CreatedAt))
            .Select(payment => new PaymentHistoryView(
                string.IsNullOrWhiteSpace(payment.PlanId)
                    ? "Подписка"
                    : payment.PlanId.Replace('_', ' '),
                FormatMoney(
                    payment.AmountMinor,
                    payment.Currency),
                LocalizePaymentStatus(payment.Status),
                FormatTimestamp(
                    payment.PaidAt ?? payment.CreatedAt)))
            .ToList();
        PaymentHistoryList.ItemsSource = rows;
        PaymentHistoryList.Visibility = rows.Count == 0
            ? Visibility.Collapsed
            : Visibility.Visible;
        PaymentHistoryEmpty.Visibility = rows.Count == 0
            ? Visibility.Visible
            : Visibility.Collapsed;
    }

    private void OnPlanSelectionChanged(
        object sender,
        SelectionChangedEventArgs args)
    {
        if (PlanSelector.SelectedItem is not PlanOptionView selected)
        {
            return;
        }

        _selectedPlanId = selected.Id;
        SelectedPlanHint.Text = selected.Disabled
            ? $"{selected.Name}: сейчас недоступен."
            : $"{selected.Action}: {selected.Name}";
        CheckoutButton.IsEnabled =
            !BusyIndicator.IsActive && !selected.Disabled;
        CheckoutButton.Content = selected.Action;
    }

    private async Task RefreshBillingAsync()
    {
        SetBusy(true);
        try
        {
            _account = await Coordinator.GetAccountSnapshotAsync(
                CancellationToken.None);
            AccountNotice.IsOpen = false;
        }
        catch (Exception error) when (
            error is HttpRequestException or
                TaskCanceledException or
                VexApiException or
                NativeClientFlowException)
        {
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
            SetBusy(false);
            Render();
        }
    }

    private async void OnRefreshBillingClick(
        object sender,
        RoutedEventArgs args) =>
        await RefreshBillingAsync();

    private async void OnCheckoutClick(
        object sender,
        RoutedEventArgs args)
    {
        var selected = PlanSelector.SelectedItem as PlanOptionView;
        var planId = selected?.Disabled == false
            ? selected.Id
            : null;
        if (string.IsNullOrWhiteSpace(planId))
        {
            AccountNotice.Message =
                "Выберите доступный тариф перед оплатой.";
            AccountNotice.Severity = InfoBarSeverity.Warning;
            AccountNotice.IsOpen = true;
            return;
        }

        SetBusy(true);
        try
        {
            var session = await Coordinator.StartCheckoutAsync(
                planId,
                CancellationToken.None);
            await LaunchUrlAsync(session.Url);
            await RefreshBillingAsync();
        }
        catch (Exception error) when (
            error is HttpRequestException or
                TaskCanceledException or
                VexApiException or
                NativeClientFlowException or
                InvalidOperationException)
        {
            AccountNotice.Message =
                "Не удалось открыть оплату.";
            AccountNotice.Severity = InfoBarSeverity.Error;
            AccountNotice.IsOpen = true;
        }
        finally
        {
            SetBusy(false);
            Render();
        }
    }

    private async void OnPortalClick(
        object sender,
        RoutedEventArgs args)
    {
        SetBusy(true);
        try
        {
            var session = await Coordinator.GetBillingPortalSessionAsync(
                CancellationToken.None);
            await LaunchUrlAsync(session.Url);
        }
        catch (Exception error) when (
            error is HttpRequestException or
                TaskCanceledException or
                VexApiException or
                NativeClientFlowException or
                InvalidOperationException)
        {
            AccountNotice.Message =
                "Не удалось открыть портал подписки.";
            AccountNotice.Severity = InfoBarSeverity.Error;
            AccountNotice.IsOpen = true;
        }
        finally
        {
            SetBusy(false);
            Render();
        }
    }

    private async void OnCancelSubscriptionClick(
        object sender,
        RoutedEventArgs args)
    {
        SetBusy(true);
        try
        {
            _account = await Coordinator.CancelSubscriptionAsync(
                CancellationToken.None);
            AccountNotice.Message =
                "Автопродление отключено.";
            AccountNotice.Severity = InfoBarSeverity.Success;
            AccountNotice.IsOpen = true;
        }
        catch (Exception error) when (
            error is HttpRequestException or
                TaskCanceledException or
                VexApiException or
                NativeClientFlowException)
        {
            AccountNotice.Message =
                "Не удалось отменить подписку.";
            AccountNotice.Severity = InfoBarSeverity.Error;
            AccountNotice.IsOpen = true;
        }
        finally
        {
            SetBusy(false);
            Render();
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
            "paid" or "succeeded" => "Оплачено",
            "pending" or "processing" => "Обрабатывается",
            "failed" => "Ошибка",
            "refunded" => "Возврат",
            "canceled" => "Отменено",
            _ => string.IsNullOrWhiteSpace(status)
                ? "Статус не указан"
                : status,
        };

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
            var region = new RegionInfo(
                new CultureInfo("ru-RU").Name);
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
            _ = region;
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

    private sealed record PlanOptionView(
        string Id,
        string Name,
        string Display,
        string Action,
        bool Disabled);

    private sealed record DeviceUsageView(
        string Name,
        string Status,
        string Meta,
        string Usage);

    private sealed record PaymentHistoryView(
        string Title,
        string Amount,
        string Status,
        string Date);
}
