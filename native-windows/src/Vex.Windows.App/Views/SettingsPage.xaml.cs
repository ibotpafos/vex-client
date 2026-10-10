using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;
using Vex.Windows.App.Services;
using Vex.Windows.Client.Api;
using Vex.Windows.Client.Session;
using Vex.Windows.Core.Presentation;
using Vex.Windows.Core.Vpn;
using Vex.Windows.Core.Vpn.Ipc;
using WinRT.Interop;

namespace Vex.Windows.App.Views;

public sealed partial class SettingsPage : Page
{
    private readonly AppServices _services = AppServices.Current;
    private readonly ProtectedClientStateStore _stateStore =
        AppServices.Current.StateStore;
    private readonly string _appDataPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "VEX",
        "VPN");
    private readonly string _serviceDataPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
        "VEX",
        "VPN");

    private NativeClientState? _state;
    private VpnConnectionSnapshot _snapshot =
        VpnConnectionSnapshot.Disconnected();
    private NativeUpdateSnapshot _updateSnapshot =
        AppServices.Current.UpdateService.CurrentSnapshot;
    private WindowsHelloStatus? _windowsHelloStatus;
    private AppRemoteConfig? _remoteConfig;
    private bool _renderingPreferences;
    private bool _realtimeRefreshInFlight;
    private bool _realtimeRefreshPending;
    private bool _isLoaded;
    private int _busyCount;
    private bool? _serviceAvailable;

    public SettingsPage()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
        Render();
    }

    private async void OnLoaded(object sender, RoutedEventArgs args)
    {
        if (_isLoaded)
        {
            return;
        }
        _isLoaded = true;
        _services.Preferences.Changed += OnPreferencesChanged;
        _services.VpnUiState.Changed += OnVpnUiStateChanged;
        _services.UpdateService.Changed += OnUpdateSnapshotChanged;
        _services.CustomerRealtimeChanged += OnCustomerRealtimeChanged;
        _services.Coordinator.SessionChanged += OnSessionChanged;
        await RefreshAsync();
    }

    private void OnUnloaded(object sender, RoutedEventArgs args)
    {
        _isLoaded = false;
        _realtimeRefreshPending = false;
        _services.Preferences.Changed -= OnPreferencesChanged;
        _services.VpnUiState.Changed -= OnVpnUiStateChanged;
        _services.UpdateService.Changed -= OnUpdateSnapshotChanged;
        _services.CustomerRealtimeChanged -= OnCustomerRealtimeChanged;
        _services.Coordinator.SessionChanged -= OnSessionChanged;
    }

    private void OnSettingsContentSizeChanged(
        object sender,
        SizeChangedEventArgs args)
    {
        if (ProtectionCard is null || ProtectionColumn is null)
        {
            return;
        }
        var twoColumns = args.NewSize.Width >= 600;
        FeatureCardsGrid.ColumnSpacing = twoColumns ? 12 : 0;
        ProtectionColumn.Width = twoColumns
            ? new GridLength(1, GridUnitType.Star)
            : new GridLength(0);
        Grid.SetColumn(ProtectionCard, twoColumns ? 1 : 0);
        Grid.SetRow(ProtectionCard, twoColumns ? 0 : 1);
    }

    private void OnSessionChanged(object? sender, EventArgs args) =>
        DispatcherQueue.TryEnqueue(() =>
        {
            if (_isLoaded)
            {
                _state = _services.Coordinator.CurrentState;
                Render();
            }
        });

    private void OnCustomerRealtimeChanged(
        object? sender,
        CustomerRealtimeChangedEventArgs args)
    {
        if (!_isLoaded || !CustomerRealtimeRefreshPolicy.ShouldRefreshSettings(args))
        {
            return;
        }
        DispatcherQueue.TryEnqueue(RefreshFromRealtimeAsync);
    }

    private async void RefreshFromRealtimeAsync()
    {
        if (!_isLoaded)
        {
            return;
        }
        if (_realtimeRefreshInFlight)
        {
            _realtimeRefreshPending = true;
            return;
        }

        _realtimeRefreshInFlight = true;
        try
        {
            do
            {
                _realtimeRefreshPending = false;
                await RefreshAsync();
            }
            while (_isLoaded && _realtimeRefreshPending);
        }
        finally
        {
            _realtimeRefreshInFlight = false;
        }
    }

    private async void OnRefreshClick(
        object sender,
        RoutedEventArgs args) =>
        await RefreshAsync();

    private void OnAutoLaunchToggled(
        object sender,
        RoutedEventArgs args)
    {
        if (_renderingPreferences)
        {
            return;
        }

        try
        {
            _services.StartupService.SetEnabled(
                AutoLaunchToggle.IsOn);
            _services.Preferences.Update(current => current with
            {
                AutoLaunchEnabled = AutoLaunchToggle.IsOn,
            });
            ShowNotice(
                AutoLaunchToggle.IsOn
                    ? "Автозапуск VEX включен."
                    : "Автозапуск VEX выключен.",
                InfoBarSeverity.Success);
        }
        catch (Exception error) when (
            error is IOException
                or CryptographicException
                or InvalidOperationException
                or UnauthorizedAccessException
                or System.Security.SecurityException)
        {
            ShowNotice(error.Message, InfoBarSeverity.Warning);
            RenderPreferences();
        }
    }

    private async void OnPreferenceToggled(
        object sender,
        RoutedEventArgs args)
    {
        if (_renderingPreferences)
        {
            return;
        }

        SetBusy(true);
        var saved = false;
        try
        {
            // Save only the control the user changed. Other controls may have
            // a queued render from a preference change on another page.
            var preferences = _services.Preferences.Update(current => sender switch
            {
                ToggleSwitch toggle when toggle == AutoServerToggle => current with
                {
                    AutoServerEnabled = toggle.IsOn,
                },
                ToggleSwitch toggle when toggle == SmartRoutingToggle => current with
                {
                    SmartRoutingEnabled = toggle.IsOn,
                },
                ToggleSwitch toggle when toggle == AntiLeakToggle => current with
                {
                    AntiLeakEnabled = toggle.IsOn,
                },
                ToggleSwitch toggle when toggle == AutoRecoveryToggle => current with
                {
                    AutoRecoveryEnabled = toggle.IsOn,
                },
                _ => current,
            });
            saved = true;
            if (ReferenceEquals(sender, SmartRoutingToggle) &&
                _services.Coordinator.CurrentState is not null)
            {
                await _services.Coordinator.SetRoutingPreferencesAsync(
                    preferences.SmartRoutingEnabled
                        ? "split"
                        : "full",
                    bypassRegion: null,
                    CancellationToken.None);
            }
            var protectionApplied = false;
            if (ReferenceEquals(sender, AntiLeakToggle) &&
                _services.VpnUiState.Snapshot.Phase == VpnConnectionPhase.Connected)
            {
                var response = await _services.VpnUiState.RunAsync(
                    token => _services.VpnClient.SetAntiLeakAsync(
                        preferences.AntiLeakEnabled,
                        token),
                    CancellationToken.None);
                if (!response.Success)
                {
                    ShowNotice(
                        "Настройка сохранена, но служба не смогла применить защиту. Повторите подключение.",
                        InfoBarSeverity.Warning);
                    return;
                }
                protectionApplied = true;
            }
            ShowNotice(
                protectionApplied
                    ? "Настройка защиты сохранена и применена к текущему подключению."
                    : ReferenceEquals(sender, SmartRoutingToggle) &&
                        _services.VpnUiState.Snapshot.Phase == VpnConnectionPhase.Connected
                        ? "Настройка маршрута сохранена и применится при следующем подключении."
                        : "Настройки VPN сохранены.",
                InfoBarSeverity.Success);
        }
        catch (Exception error) when (IsSettingsOperationFailure(error))
        {
            ShowNotice(
                saved
                    ? "Настройка сохранена, но сейчас не удалось применить её к VPN. Повторите подключение."
                    : "Не удалось сохранить настройку. Повторите позже.",
                InfoBarSeverity.Warning);
        }
        finally
        {
            SetBusy(false);
            RenderPreferences();
        }
    }

    private void OnLanguageSelectionChanged(
        object sender,
        SelectionChangedEventArgs args)
    {
        if (_renderingPreferences ||
            LanguagePicker.SelectedItem is not ComboBoxItem item ||
            item.Tag is not string language)
        {
            return;
        }

        try
        {
            _services.Preferences.Update(current => current with
            {
                InterfaceLanguage = language,
            });
            ShowNotice(
                language == "en"
                    ? "Language preference saved."
                    : "Русский язык выбран.",
                InfoBarSeverity.Success);
        }
        catch (Exception error) when (IsSettingsOperationFailure(error))
        {
            ShowNotice("Не удалось сохранить язык интерфейса.", InfoBarSeverity.Warning);
            RenderPreferences();
        }
    }

    private async void OnEnableWindowsHelloClick(
        object sender,
        RoutedEventArgs args)
    {
        SetBusy(true);
        try
        {
            await _stateStore.EnableWindowsHelloAsync(
                CurrentWindowHandle(),
                CancellationToken.None);
            _services.Auth.ClearStatus();
            ShowNotice(
                "Windows Hello включен для локальной сессии VEX.",
                InfoBarSeverity.Success);
            await RefreshAsync();
        }
        catch (Exception error) when (
            IsSettingsOperationFailure(error))
        {
            ShowNotice(
                error.Message,
                InfoBarSeverity.Warning);
        }
        finally
        {
            SetBusy(false);
            Render();
        }
    }

    private async void OnUnlockWindowsHelloClick(
        object sender,
        RoutedEventArgs args)
    {
        SetBusy(true);
        try
        {
            await _stateStore.UnlockAsync(
                CurrentWindowHandle(),
                CancellationToken.None);
            _services.Auth.ClearStatus();
            ShowNotice(
                "Локальная сессия разблокирована через Windows Hello.",
                InfoBarSeverity.Success);
            await RefreshAsync();
        }
        catch (Exception error) when (
            IsSettingsOperationFailure(error))
        {
            ShowNotice(
                error.Message,
                InfoBarSeverity.Warning);
        }
        finally
        {
            SetBusy(false);
            Render();
        }
    }

    private async void OnDisableWindowsHelloClick(
        object sender,
        RoutedEventArgs args)
    {
        SetBusy(true);
        try
        {
            await _stateStore.DisableWindowsHelloAsync(
                CurrentWindowHandle(),
                CancellationToken.None);
            _services.Auth.ClearStatus();
            ShowNotice(
                "Windows Hello отключен для локальной сессии VEX.",
                InfoBarSeverity.Success);
            await RefreshAsync();
        }
        catch (Exception error) when (
            IsSettingsOperationFailure(error))
        {
            ShowNotice(
                error.Message,
                InfoBarSeverity.Warning);
        }
        finally
        {
            SetBusy(false);
            Render();
        }
    }

    private async void OnOpenDownloadsClick(
        object sender,
        RoutedEventArgs args)
    {
        SetBusy(true);
        try
        {
            _updateSnapshot = await _services.UpdateService.PrepareAndLaunchAsync(
                CancellationToken.None);
            if (_updateSnapshot.State == "installer_launched")
            {
                ShowNotice(
                    _updateSnapshot.Message ??
                    "Проверенный пакет обновления открыт в системном установщике.",
                    InfoBarSeverity.Success);
            }
            else if (_updateSnapshot.UpdateAvailable)
            {
                ShowNotice(
                    "Не удалось открыть установщик обновления. Открываем центр загрузок.",
                    InfoBarSeverity.Warning);
                await OpenDownloadsWebsiteAsync();
            }
            else
            {
                await OpenDownloadsWebsiteAsync();
            }
        }
        catch (Exception error) when (IsSettingsOperationFailure(error))
        {
            ShowNotice(
                error.Message,
                InfoBarSeverity.Warning);
        }
        finally
        {
            SetBusy(false);
            Render();
        }
    }

    private async void OnCheckUpdatesClick(
        object sender,
        RoutedEventArgs args)
    {
        SetBusy(true);
        try
        {
            _updateSnapshot =
                await _services.UpdateService.RefreshAsync(
                    CancellationToken.None);
            ShowNotice(
                _updateSnapshot.UpdateAvailable
                    ? $"Доступна версия {_updateSnapshot.Release?.Version ?? "—"}."
                    : _updateSnapshot.Message ?? "Установлена актуальная версия.",
                _updateSnapshot.Required || _updateSnapshot.State is "error" or "disabled"
                    ? InfoBarSeverity.Warning
                    : InfoBarSeverity.Success);
        }
        catch (Exception error) when (
            error is InvalidOperationException
                or HttpRequestException
                or OperationCanceledException)
        {
            ShowNotice(error.Message, InfoBarSeverity.Warning);
        }
        finally
        {
            SetBusy(false);
            Render();
        }
    }

    private async void OnAutoUpdatesToggled(
        object sender,
        RoutedEventArgs args)
    {
        if (_renderingPreferences)
        {
            return;
        }

        SetBusy(true);
        try
        {
            var enabled = AutoUpdatesToggle.IsOn;
            _services.Preferences.Update(current => current with
            {
                AutoUpdatesEnabled = enabled,
            });
            if (!enabled)
            {
                ShowNotice(
                    "Автоматическая проверка обновлений выключена.",
                    InfoBarSeverity.Success);
                return;
            }
            _updateSnapshot =
                await _services.BackgroundUpdates.CheckNowAsync(
                    CancellationToken.None);
            ShowNotice(
                _updateSnapshot.UpdateAvailable
                    ? $"Доступна версия {_updateSnapshot.Release?.Version ?? "—"}."
                    : _updateSnapshot.State is "error" or "disabled"
                        ? _updateSnapshot.Message ?? "Не удалось проверить обновления. Повторите позже."
                        : "Автоматическая проверка включена. Установлена актуальная версия.",
                _updateSnapshot.Required || _updateSnapshot.State is "error" or "disabled"
                    ? InfoBarSeverity.Warning
                    : InfoBarSeverity.Success);
        }
        catch (Exception error) when (IsSettingsOperationFailure(error))
        {
            ShowNotice("Не удалось сохранить или проверить настройку обновлений.", InfoBarSeverity.Warning);
        }
        finally
        {
            SetBusy(false);
            Render();
        }
    }

    private async void OnOpenManualDownloadsClick(
        object sender,
        RoutedEventArgs args) =>
        await OpenDownloadsWebsiteAsync();

    private async Task OpenDownloadsWebsiteAsync()
    {
        if (UiPreviewContext.IsEnabled) return;
        try
        {
            if (!await Launcher.LaunchUriAsync(
                new Uri(_services.UpdateService.DownloadsFallbackUrl, UriKind.Absolute)))
            {
                ShowNotice("Не удалось открыть центр загрузок.", InfoBarSeverity.Warning);
            }
        }
        catch (Exception error) when (IsSettingsOperationFailure(error))
        {
            ShowNotice("Не удалось открыть центр загрузок.", InfoBarSeverity.Warning);
        }
    }

    private async void OnRepairServiceClick(
        object sender,
        RoutedEventArgs args)
    {
        SetBusy(true);
        try
        {
            var result =
                await _services.ServiceMaintenance.RepairAsync(
                    CancellationToken.None);
            ShowNotice(
                result.Message,
                result.Success
                    ? InfoBarSeverity.Success
                    : InfoBarSeverity.Warning);
            if (result.Success)
            {
                await Task.Delay(500);
                await RefreshVpnStateAsync();
            }
        }
        catch (Exception error) when (
            error is IOException
                or UnauthorizedAccessException
                or InvalidOperationException
                or OperationCanceledException)
        {
            ShowNotice(error.Message, InfoBarSeverity.Warning);
        }
        finally
        {
            SetBusy(false);
            Render();
        }
    }

    private void OnCopySummaryClick(
        object sender,
        RoutedEventArgs args)
    {
        var summary = JsonSerializer.Serialize(
            new
            {
                generated_at = DateTimeOffset.UtcNow,
                app_version = _services.AppVersion,
                shell = new
                {
                    single_instance = true,
                    tray_mode = "resident",
                    close_behavior = "close_hides_to_tray",
                    windows_hello = new
                    {
                        available = _windowsHelloStatus?.IsAvailable ?? false,
                        required = _windowsHelloStatus?.IsRequired ?? false,
                        access = _windowsHelloStatus?.AccessKind.ToString() ??
                            "unknown",
                    },
                    update_center = "https://vexguard.app/downloads",
                    preferences = new
                    {
                        auto_launch =
                            _services.Preferences.Current.AutoLaunchEnabled,
                        auto_server =
                            _services.Preferences.Current.AutoServerEnabled,
                        smart_routing =
                            _services.Preferences.Current.SmartRoutingEnabled,
                        anti_leak =
                            _services.Preferences.Current.AntiLeakEnabled,
                        auto_recovery =
                            _services.Preferences.Current.AutoRecoveryEnabled,
                        language =
                            _services.Preferences.Current.InterfaceLanguage,
                    },
                },
                session = new
                {
                    signed_in = _state is not null,
                    email = _state?.Session.User.Email,
                    installation_id = _state?.InstallationId,
                    device_id = _state?.DeviceId,
                    location_id = _state?.LocationId,
                    identity_epoch = _state?.Identity.KeyEpoch,
                    cached_profile_version = _state?.CachedProfileVersion,
                    has_cached_authorization =
                        _state?.CachedAuthorization is not null,
                },
                service = new
                {
                    phase = _snapshot.Phase.ToString(),
                    location_id = _snapshot.LocationId,
                    error_code = _snapshot.ErrorCode,
                    received_bytes =
                        _services.VpnUiState.ReceivedBytes,
                    sent_bytes =
                        _services.VpnUiState.SentBytes,
                    leak_protection =
                        _snapshot.Diagnostics?.LeakProtection.ToString(),
                },
                updates = new
                {
                    state = _updateSnapshot.State,
                    current_version = _updateSnapshot.CurrentVersion,
                    channel = _updateSnapshot.Channel,
                    architecture = _updateSnapshot.Architecture,
                    available_version = _updateSnapshot.Release?.Version,
                    required = _updateSnapshot.Required,
                    message = _updateSnapshot.Message,
                },
                paths = new
                {
                    app_data = _appDataPath,
                    service_data = _serviceDataPath,
                },
            },
            new JsonSerializerOptions
            {
                WriteIndented = true,
            });

        var package = new DataPackage();
        package.SetText(summary);
        try
        {
            Clipboard.SetContent(package);
            ShowNotice("Отчёт скопирован в буфер обмена.", InfoBarSeverity.Success);
        }
        catch (Exception error) when (IsSettingsOperationFailure(error))
        {
            ShowNotice("Не удалось скопировать отчёт. Повторите позже.", InfoBarSeverity.Warning);
        }
    }

    private void OnOpenAppDataClick(
        object sender,
        RoutedEventArgs args) =>
        OpenPath(_appDataPath);

    private void OnOpenServiceDataClick(
        object sender,
        RoutedEventArgs args) =>
        OpenPath(_serviceDataPath);

    private async Task RefreshAsync()
    {
        SetBusy(true);
        try
        {
            _state = _services.Coordinator.CurrentState;
            // Control-plane notices and local session security remain available
            // while the privileged VPN service is being repaired.
            try
            {
                await RefreshVpnStateAsync();
            }
            catch (Exception error) when (IsSettingsOperationFailure(error))
            {
                _serviceAvailable = false;
                ShowNotice(
                    "Служба VEX VPN недоступна. Нажмите «Запустить службу» для восстановления.",
                    InfoBarSeverity.Warning);
            }

            _windowsHelloStatus = await _stateStore.GetWindowsHelloStatusAsync(
                CancellationToken.None);
            _updateSnapshot = await _services.UpdateService.RefreshAsync(
                CancellationToken.None);
            await RefreshRemoteConfigAsync();
        }
        catch (Exception error) when (IsSettingsOperationFailure(error))
        {
            ShowNotice(
                "Не удалось обновить настройки. Повторите позже.",
                InfoBarSeverity.Warning);
        }
        finally
        {
            SetBusy(false);
            Render();
        }
    }

    private async Task RefreshRemoteConfigAsync()
    {
        var version = typeof(App).Assembly.GetName().Version;
        var metadata = new ClientAppMetadata(
            "windows",
            _services.AppVersion,
            Math.Max(0, version is { Revision: > 0 }
                ? version.Revision
                : version?.Build ?? 0),
            _updateSnapshot.Channel,
            typeof(VpnConnectionSnapshot).Assembly.GetName().Version?.ToString() ?? "1.0.0",
            Environment.OSVersion.VersionString,
            System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture
                .ToString().ToLowerInvariant(),
            "native-windows-1",
            1);
        try
        {
            _remoteConfig = await _services.Coordinator.GetRemoteConfigAsync(
                metadata,
                CancellationToken.None);
        }
        catch (Exception error) when (
            error is HttpRequestException or OperationCanceledException or VexApiException)
        {
            // Preserve the most recent service notice when temporarily offline.
        }
    }

    private async void OnOpenSupportWebsiteClick(
        object sender,
        RoutedEventArgs args)
    {
        if (UiPreviewContext.IsEnabled) return;
        try
        {
            if (!await Launcher.LaunchUriAsync(new Uri("https://vexguard.app/support")))
            {
                ShowNotice("Не удалось открыть сайт поддержки.", InfoBarSeverity.Warning);
            }
        }
        catch (System.Runtime.InteropServices.COMException)
        {
            ShowNotice("Не удалось открыть сайт поддержки.", InfoBarSeverity.Warning);
        }
    }

    private async Task RefreshVpnStateAsync()
    {
        var response = await _services.VpnUiState.RefreshAsync(
            CancellationToken.None);
        _snapshot = response.Snapshot;
        _serviceAvailable = response.ErrorCode != "vpn_service_unavailable";
    }

    private void Render()
    {
        RenderPreferences();
        IncidentNotice.Message = _remoteConfig?.IncidentBanner?.Trim() ?? string.Empty;
        IncidentNotice.IsOpen = !string.IsNullOrWhiteSpace(IncidentNotice.Message);
        _snapshot = _services.VpnUiState.Snapshot;
        AppVersionText.Text = _services.AppVersion;
        SingleInstanceText.Text = "Один экземпляр приложения: включён";
        TrayModeText.Text = "Работа в области уведомлений: приложение остаётся активным, окно можно скрыть и открыть снова";
        QuitBehaviorText.Text = "Поведение при закрытии: окно скрывается в область уведомлений; полный выход — через пункт «Выход»";
        WindowsHelloText.Text = FormatWindowsHelloText();

        SessionText.Text = _state is null
            ? _windowsHelloStatus?.AccessKind ==
                ClientStateAccessKind.Locked
                ? "Сессия: локально заблокирована Windows Hello"
                : "Сессия: не выполнен вход"
            : $"Сессия: {_state.Session.User.Email}";
        InstallationIdText.Text =
            $"Installation ID: {_state?.InstallationId ?? "—"}";
        DeviceIdText.Text =
            $"Device ID: {_state?.DeviceId ?? "—"}";
        LocationIdText.Text =
            $"Локация: {_state?.LocationId ?? "—"}";
        IdentityEpochText.Text =
            $"Epoch ключа: {_state?.Identity.KeyEpoch.ToString() ?? "—"}";
        ProfileCacheText.Text = _state switch
        {
            null => "Кэш профиля: недоступен без входа",
            { CachedAuthorization: not null } state =>
                $"Кэш профиля: version={state.CachedProfileVersion?.ToString() ?? "—"}, signed authorization сохранен",
            _ => "Кэш профиля: пустой",
        };
        ServiceStatusText.Text = ServiceStatusTextValue();
        ToolTipService.SetToolTip(ServiceStatusBadge,
            _snapshot.ErrorCode ?? "Состояние VPN-службы VEX");
        var serviceWarning = _serviceAvailable == false ||
            _snapshot.Phase == VpnConnectionPhase.Error;
        ServiceStatusBadge.Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(
            serviceWarning
                ? global::Windows.UI.Color.FromArgb(31, 255, 194, 92)
                : global::Windows.UI.Color.FromArgb(18, 34, 211, 238));
        ServiceStatusText.Foreground = serviceWarning
            ? new Microsoft.UI.Xaml.Media.SolidColorBrush(global::Windows.UI.Color.FromArgb(255, 255, 194, 92))
            : (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["VexCyanLightBrush"];
        LeakProtectionText.Text = FormatLeakProtection();
        AppDataPathText.Text = $"Данные приложения: {_appDataPath}";
        ServiceDataPathText.Text = $"Данные службы: {_serviceDataPath}";
        UpdateStatusText.Text = FormatUpdateStatus();
        UpdateVersionText.Text =
            $"Доступная версия: {_updateSnapshot.Release?.Version ?? "—"}";
        UpdateDetailsText.Text =
            _updateSnapshot.Message ??
            $"Канал {_updateSnapshot.Channel}, архитектура {_updateSnapshot.Architecture}.";
        InstallUpdateButton.Visibility =
            _updateSnapshot.UpdateAvailable
                ? Visibility.Visible
                : Visibility.Collapsed;
        InstallUpdateButton.Content = _updateSnapshot.Required
            ? "Установить обязательное обновление"
            : "Установить обновление";

        var helloAvailable = _windowsHelloStatus?.IsAvailable ?? false;
        var helloRequired = _windowsHelloStatus?.IsRequired ?? false;
        var helloLocked = _windowsHelloStatus?.AccessKind ==
            ClientStateAccessKind.Locked;
        EnableWindowsHelloButton.Visibility =
            helloAvailable && !helloRequired && _state is not null
                ? Visibility.Visible
                : Visibility.Collapsed;
        DisableWindowsHelloButton.Visibility = helloRequired
            ? Visibility.Visible
            : Visibility.Collapsed;
        UnlockWindowsHelloButton.Visibility = helloLocked
            ? Visibility.Visible
            : Visibility.Collapsed;
    }

    private void RenderPreferences()
    {
        if (AutoLaunchToggle is null ||
            AutoUpdatesToggle is null ||
            AutoServerToggle is null ||
            SmartRoutingToggle is null ||
            AntiLeakToggle is null ||
            AutoRecoveryToggle is null ||
            LanguagePicker is null)
        {
            return;
        }

        _renderingPreferences = true;
        try
        {
            var preferences = _services.Preferences.Current;
            var startupStatus = preferences.AutoLaunchEnabled
                ? StartupRegistrationState.Enabled
                : StartupRegistrationState.Disabled;
            try
            {
                startupStatus = _services.StartupService.GetStatus();
            }
            catch (Exception error) when (
                error is UnauthorizedAccessException
                    or System.Security.SecurityException
                    or InvalidOperationException)
            {
                // Keep the saved preference when Windows cannot be queried.
            }

            var startupEnabled = startupStatus == StartupRegistrationState.Enabled;
            AutoLaunchToggle.IsOn = startupEnabled;
            AutoLaunchDescription.Text = startupStatus switch
            {
                StartupRegistrationState.Enabled => "Приложение откроется после входа.",
                StartupRegistrationState.DisabledByUser => "Отключён в настройках автозагрузки Windows.",
                StartupRegistrationState.DisabledByPolicy => "Запрещён политикой Windows.",
                StartupRegistrationState.ForeignRegistration => "Запись автозапуска занята другой программой.",
                _ => "Автозапуск выключен.",
            };
            AutoUpdatesToggle.IsOn = preferences.AutoUpdatesEnabled;
            AutoUpdatesDescription.Text = preferences.AutoUpdatesEnabled
                ? "Проверять при запуске и каждые 6 часов."
                : "Автоматическая проверка выключена.";
            AutoServerToggle.IsOn = preferences.AutoServerEnabled;
            SmartRoutingToggle.IsOn = preferences.SmartRoutingEnabled;
            SmartRoutingDescription.Text = preferences.SmartRoutingEnabled
                ? "Локальные сервисы идут без VPN."
                : "Весь трафик идёт через VPN.";
            AntiLeakToggle.IsOn = preferences.AntiLeakEnabled;
            AutoRecoveryToggle.IsOn = preferences.AutoRecoveryEnabled;
            LanguagePicker.SelectedIndex =
                preferences.InterfaceLanguage == "en"
                    ? 1
                    : 0;
        }
        finally
        {
            _renderingPreferences = false;
        }
    }

    private void OnPreferencesChanged(object? sender, EventArgs args) =>
        DispatcherQueue.TryEnqueue(() =>
        {
            if (_isLoaded)
            {
                RenderPreferences();
            }
        });

    private void OnVpnUiStateChanged(object? sender, EventArgs args) =>
        DispatcherQueue.TryEnqueue(() =>
        {
            if (!_isLoaded)
            {
                return;
            }
            _snapshot = _services.VpnUiState.Snapshot;
            if (_snapshot.ErrorCode == "vpn_service_unavailable")
            {
                _serviceAvailable = false;
            }
            else if (_snapshot.Phase != VpnConnectionPhase.Error)
            {
                _serviceAvailable = true;
            }
            Render();
        });

    private void OnUpdateSnapshotChanged(object? sender, EventArgs args) =>
        DispatcherQueue.TryEnqueue(() =>
        {
            if (!_isLoaded)
            {
                return;
            }
            _updateSnapshot = _services.UpdateService.CurrentSnapshot;
            Render();
        });

    private string ServiceStatusTextValue() =>
        _serviceAvailable switch
        {
            false => "Служба недоступна",
            null => "Проверяем",
            _ => _snapshot.Phase switch
            {
                VpnConnectionPhase.Connected =>
                    $"Защищено{FormatLocation(_snapshot.LocationId)}",
                VpnConnectionPhase.Connecting =>
                    $"Подключение{FormatLocation(_snapshot.LocationId)}",
                VpnConnectionPhase.Disconnecting =>
                    "Отключение",
                VpnConnectionPhase.Error =>
                    "Требуется проверка",
                _ => "Готов к подключению",
            },
        };

    private string FormatLeakProtection() =>
        _snapshot.Diagnostics?.LeakProtection switch
        {
            VpnLeakProtectionState.Armed =>
                "готов, блокировка включится при сбое",
            VpnLeakProtectionState.Blocking =>
                "трафик заблокирован до восстановления туннеля",
            VpnLeakProtectionState.Degraded =>
                "требуется проверка системной службы",
            VpnLeakProtectionState.Off =>
                "выключен",
            _ =>
                "проверяем",
        };

    private void SetBusy(bool busy)
    {
        // Nested and realtime refreshes must not enable controls while another
        // page operation still owns them.
        _busyCount = Math.Max(0, _busyCount + (busy ? 1 : -1));
        busy = _busyCount > 0;
        BusyIndicator.IsActive = busy;
        RefreshSettingsButton.IsEnabled = !busy;
        OpenDownloadsButton.IsEnabled = !busy;
        CheckUpdatesButton.IsEnabled = !busy;
        InstallUpdateButton.IsEnabled = !busy;
        RepairServiceButton.IsEnabled = !busy;
        CopyDiagnosticsButton.IsEnabled = !busy;
        AutoLaunchToggle.IsEnabled = !busy;
        AutoUpdatesToggle.IsEnabled = !busy;
        AutoServerToggle.IsEnabled = !busy;
        SmartRoutingToggle.IsEnabled = !busy;
        AntiLeakToggle.IsEnabled = !busy;
        AutoRecoveryToggle.IsEnabled = !busy;
        LanguagePicker.IsEnabled = !busy;
        EnableWindowsHelloButton.IsEnabled = !busy;
        DisableWindowsHelloButton.IsEnabled = !busy;
        UnlockWindowsHelloButton.IsEnabled = !busy;
    }

    private void ShowNotice(
        string message,
        InfoBarSeverity severity)
    {
        SettingsNotice.Message = message;
        SettingsNotice.Severity = severity;
        SettingsNotice.IsOpen = true;
    }

    private void OpenPath(string path)
    {
        if (UiPreviewContext.IsEnabled) return;
        try
        {
            Directory.CreateDirectory(path);
            Process.Start(
                new ProcessStartInfo("explorer.exe", $"\"{path}\"")
                {
                    UseShellExecute = true,
                });
        }
        catch (Exception error) when (IsSettingsOperationFailure(error))
        {
            ShowNotice("Не удалось открыть папку данных VEX.", InfoBarSeverity.Warning);
        }
    }

    private static bool IsSettingsOperationFailure(Exception error) =>
        error is IOException or UnauthorizedAccessException or InvalidOperationException or
            ArgumentException or OperationCanceledException or CryptographicException or
            HttpRequestException or NativeClientFlowException or VexApiException or
            VpnIpcProtocolException or System.ComponentModel.Win32Exception or
            System.Runtime.InteropServices.COMException;

    private static string FormatLocation(string? locationId) =>
        string.IsNullOrWhiteSpace(locationId)
            ? string.Empty
            : $" · {NativeLocationLabel.Russian(locationId)}";

    private string FormatUpdateStatus()
    {
        return _updateSnapshot.State switch
        {
            "available" =>
                $"доступно {_updateSnapshot.Release?.Version ?? "—"}",
            "installer_launched" =>
                $"установщик открыт для {_updateSnapshot.Release?.Version ?? "—"}",
            "current" =>
                "актуально",
            "disabled" =>
                "автообновление недоступно",
            "error" =>
                $"ошибка ({_updateSnapshot.Message ?? "unknown"})",
            _ =>
                _updateSnapshot.State,
        };
    }

    private string FormatWindowsHelloText()
    {
        if (_windowsHelloStatus is null)
        {
            return "Проверяем доступность…";
        }

        if (!_windowsHelloStatus.IsAvailable)
        {
            return _windowsHelloStatus.IsRequired
                ? "Сессия защищена Hello. Настройте Windows Hello на этом устройстве."
                : "Недоступен на этом устройстве. Сессия защищена Windows.";
        }

        if (!_windowsHelloStatus.IsRequired)
        {
            return _state is null
                ? "Выполните вход, чтобы включить защиту сессии."
                : "Подтверждать открытие локальной сессии.";
        }

        return _windowsHelloStatus.AccessKind == ClientStateAccessKind.Locked
            ? "Включен. Сессия сейчас заблокирована."
            : "Включен. Сессия разблокирована.";
    }

    private nint CurrentWindowHandle()
    {
        var window = _services.MainWindow ??
            throw new InvalidOperationException(
                "Основное окно VEX недоступно.");
        return WindowNative.GetWindowHandle(window);
    }
}
