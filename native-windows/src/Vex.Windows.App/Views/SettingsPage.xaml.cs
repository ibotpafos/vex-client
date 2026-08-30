using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.Diagnostics;
using System.Text.Json;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;
using Vex.Windows.App.Services;
using Vex.Windows.Client.Api;
using Vex.Windows.Client.Session;
using Vex.Windows.Core.Presentation;
using Vex.Windows.Core.Vpn;
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
    private bool _renderingPreferences;

    public SettingsPage()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
        Render();
    }

    private async void OnLoaded(object sender, RoutedEventArgs args)
    {
        _services.Preferences.Changed += OnPreferencesChanged;
        _services.VpnUiState.Changed += OnVpnUiStateChanged;
        _services.UpdateService.Changed += OnUpdateSnapshotChanged;
        _services.CustomerRealtimeChanged += OnCustomerRealtimeChanged;
        await RefreshAsync();
    }

    private void OnUnloaded(object sender, RoutedEventArgs args)
    {
        _services.Preferences.Changed -= OnPreferencesChanged;
        _services.VpnUiState.Changed -= OnVpnUiStateChanged;
        _services.UpdateService.Changed -= OnUpdateSnapshotChanged;
        _services.CustomerRealtimeChanged -= OnCustomerRealtimeChanged;
    }

    private void OnCustomerRealtimeChanged(
        object? sender,
        CustomerRealtimeChangedEventArgs args) =>
        DispatcherQueue.TryEnqueue(async () => await RefreshAsync());

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
            error is InvalidOperationException
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

        var preferences = _services.Preferences.Update(current => current with
        {
            AutoServerEnabled = AutoServerToggle.IsOn,
            SmartRoutingEnabled = SmartRoutingToggle.IsOn,
            AntiLeakEnabled = AntiLeakToggle.IsOn,
            AutoRecoveryEnabled = AutoRecoveryToggle.IsOn,
        });
        if (_services.Coordinator.CurrentState is not null)
        {
            try
            {
                await _services.Coordinator.SetRoutingPreferencesAsync(
                    preferences.SmartRoutingEnabled
                        ? "split"
                        : "full",
                    bypassRegion: null,
                    CancellationToken.None);
            }
            catch (Exception error) when (
                error is NativeClientFlowException
                    or InvalidOperationException
                    or ArgumentException
                    or OperationCanceledException)
            {
                ShowNotice(
                    error.Message,
                    InfoBarSeverity.Warning);
                return;
            }
        }
        if (_services.VpnUiState.Snapshot.Phase ==
            VpnConnectionPhase.Connected)
        {
            try
            {
                await _services.VpnUiState.RunAsync(
                    token => _services.VpnClient.SetAntiLeakAsync(
                        preferences.AntiLeakEnabled,
                        token),
                    CancellationToken.None);
            }
            catch (Exception error) when (
                error is IOException
                    or UnauthorizedAccessException
                    or InvalidOperationException
                    or OperationCanceledException)
            {
                ShowNotice(
                    error.Message,
                    InfoBarSeverity.Warning);
                return;
            }
        }
        ShowNotice(
            _services.VpnUiState.Snapshot.Phase ==
                VpnConnectionPhase.Connected
                ? "Настройки VPN сохранены и применятся при следующем подключении."
                : "Настройки VPN сохранены.",
            InfoBarSeverity.Success);
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

        _services.Preferences.Update(current => current with
        {
            InterfaceLanguage = language,
        });
        ShowNotice(
            language == "en"
                ? "English will be applied as localized resources are loaded."
                : "Русский язык выбран.",
            InfoBarSeverity.Success);
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
            ShowNotice(
                "Windows Hello включен для локальной сессии VEX.",
                InfoBarSeverity.Success);
            await RefreshAsync();
        }
        catch (Exception error) when (
            error is InvalidOperationException or
            OperationCanceledException)
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
            ShowNotice(
                "Локальная сессия разблокирована через Windows Hello.",
                InfoBarSeverity.Success);
            await RefreshAsync();
        }
        catch (Exception error) when (
            error is InvalidOperationException or
            OperationCanceledException)
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
            ShowNotice(
                "Windows Hello отключен для локальной сессии VEX.",
                InfoBarSeverity.Success);
            await RefreshAsync();
        }
        catch (Exception error) when (
            error is InvalidOperationException or
            OperationCanceledException)
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
                    "Обновление доступно, но пакет не удалось открыть. Открою центр загрузок как rollback path.",
                    InfoBarSeverity.Warning);
                await Launcher.LaunchUriAsync(
                    new Uri(
                        _services.UpdateService.DownloadsFallbackUrl,
                        UriKind.Absolute));
            }
            else
            {
                await Launcher.LaunchUriAsync(
                    new Uri(
                        _services.UpdateService.DownloadsFallbackUrl,
                        UriKind.Absolute));
            }
        }
        catch (Exception error) when (
            error is InvalidOperationException or
            OperationCanceledException)
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
                _updateSnapshot.Required
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

        SetBusy(true);
        try
        {
            _updateSnapshot =
                await _services.BackgroundUpdates.CheckNowAsync(
                    CancellationToken.None);
            ShowNotice(
                _updateSnapshot.UpdateAvailable
                    ? $"Доступна версия {_updateSnapshot.Release?.Version ?? "—"}."
                    : "Автоматическая проверка включена. Установлена актуальная версия.",
                _updateSnapshot.Required
                    ? InfoBarSeverity.Warning
                    : InfoBarSeverity.Success);
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
        await Launcher.LaunchUriAsync(
            new Uri(
                _services.UpdateService.DownloadsFallbackUrl,
                UriKind.Absolute));

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
        Clipboard.SetContent(package);
        ShowNotice(
            "Redacted summary скопирован в буфер обмена.",
            InfoBarSeverity.Success);
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
            await RefreshVpnStateAsync();
            _windowsHelloStatus = await _stateStore.GetWindowsHelloStatusAsync(
                CancellationToken.None);
            _updateSnapshot = await _services.UpdateService.RefreshAsync(
                CancellationToken.None);
            SettingsNotice.IsOpen = false;
        }
        catch (Exception error) when (
            error is IOException
                or UnauthorizedAccessException
                or InvalidOperationException
                or OperationCanceledException)
        {
            _snapshot = new VpnConnectionSnapshot(
                VpnConnectionPhase.Error,
                _state?.LocationId,
                Sequence: _snapshot.Sequence,
                ErrorCode: "vpn_service_unavailable");
            _updateSnapshot = NativeUpdateSnapshot.Error(
                _updateSnapshot.CurrentVersion,
                _updateSnapshot.Channel,
                _updateSnapshot.Architecture,
                error.Message);
            ShowNotice(
                "Служба VEX VPN недоступна. Проверь установку и перезапусти shell.",
                InfoBarSeverity.Warning);
        }
        finally
        {
            SetBusy(false);
            Render();
        }
    }

    private async Task RefreshVpnStateAsync()
    {
        var response = await _services.VpnUiState.RefreshAsync(
            CancellationToken.None);
        _snapshot = response.Snapshot;
    }

    private void Render()
    {
        RenderPreferences();
        _snapshot = _services.VpnUiState.Snapshot;
        AppVersionText.Text =
            $"Версия приложения: {_services.AppVersion} · канал {_updateSnapshot.Channel} · updater {FormatUpdateStatus()}";
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
        ServiceStatusText.Text = $"Статус службы: {ServiceStatusTextValue()}";
        LeakProtectionText.Text =
            $"Anti-leak: {FormatLeakProtection()}";
        AppDataPathText.Text = $"Данные приложения: {_appDataPath}";
        ServiceDataPathText.Text = $"Данные службы: {_serviceDataPath}";
        UpdateStatusText.Text =
            $"Статус: {FormatUpdateStatus()}";
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
            ? "Установить обязательно"
            : "Установить";

        var helloAvailable = _windowsHelloStatus?.IsAvailable ?? false;
        var helloRequired = _windowsHelloStatus?.IsRequired ?? false;
        var helloLocked = _windowsHelloStatus?.AccessKind ==
            ClientStateAccessKind.Locked;
        EnableWindowsHelloButton.Visibility =
            helloAvailable && !helloRequired
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
            var startupEnabled = false;
            try
            {
                startupEnabled = _services.StartupService.IsEnabled();
            }
            catch (Exception error) when (
                error is UnauthorizedAccessException
                    or System.Security.SecurityException
                    or InvalidOperationException)
            {
                startupEnabled = preferences.AutoLaunchEnabled;
            }

            AutoLaunchToggle.IsOn = startupEnabled;
            AutoUpdatesToggle.IsOn = preferences.AutoUpdatesEnabled;
            AutoServerToggle.IsOn = preferences.AutoServerEnabled;
            SmartRoutingToggle.IsOn = preferences.SmartRoutingEnabled;
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
        DispatcherQueue.TryEnqueue(RenderPreferences);

    private void OnVpnUiStateChanged(object? sender, EventArgs args) =>
        DispatcherQueue.TryEnqueue(() =>
        {
            _snapshot = _services.VpnUiState.Snapshot;
            Render();
        });

    private void OnUpdateSnapshotChanged(object? sender, EventArgs args) =>
        DispatcherQueue.TryEnqueue(() =>
        {
            _updateSnapshot = _services.UpdateService.CurrentSnapshot;
            Render();
        });

    private string ServiceStatusTextValue() =>
        _snapshot.Phase switch
        {
            VpnConnectionPhase.Connected =>
                $"защищено{FormatLocation(_snapshot.LocationId)}",
            VpnConnectionPhase.Connecting =>
                $"подключение{FormatLocation(_snapshot.LocationId)}",
            VpnConnectionPhase.Disconnecting =>
                "отключение",
            VpnConnectionPhase.Error =>
                $"ошибка ({_snapshot.ErrorCode ?? "unknown"})",
            _ => "не подключено",
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
        BusyIndicator.IsActive = busy;
        RefreshSettingsButton.IsEnabled = !busy;
        OpenDownloadsButton.IsEnabled = !busy;
        CheckUpdatesButton.IsEnabled = !busy;
        InstallUpdateButton.IsEnabled = !busy;
        RepairServiceButton.IsEnabled = !busy;
        CopyDiagnosticsButton.IsEnabled = !busy;
        AutoLaunchToggle.IsEnabled = !busy;
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
        Directory.CreateDirectory(path);
        Process.Start(
            new ProcessStartInfo("explorer.exe", $"\"{path}\"")
            {
                UseShellExecute = true,
            });
    }

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
                "отключен fail-closed",
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
            return "Windows Hello: проверяем доступность…";
        }

        if (!_windowsHelloStatus.IsAvailable)
        {
            return "Windows Hello: недоступен, локальные секреты защищены DPAPI";
        }

        if (!_windowsHelloStatus.IsRequired)
        {
            return "Windows Hello: доступен, но не обязателен для открытия локальной сессии";
        }

        return _windowsHelloStatus.AccessKind == ClientStateAccessKind.Locked
            ? "Windows Hello: включен, локальная сессия сейчас заблокирована"
            : "Windows Hello: включен, локальная сессия разблокирована";
    }

    private nint CurrentWindowHandle()
    {
        var window = _services.MainWindow ??
            throw new InvalidOperationException(
                "Основное окно VEX недоступно.");
        return WindowNative.GetWindowHandle(window);
    }
}
