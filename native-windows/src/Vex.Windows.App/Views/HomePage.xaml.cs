using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using System.Security.Cryptography;
using Vex.Windows.App.Services;
using Vex.Windows.Client.Api;
using Vex.Windows.Client.Session;
using Vex.Windows.Core.Navigation;
using Vex.Windows.Core.Vpn;
using Vex.Windows.Core.Presentation;
using Vex.Windows.Core.Vpn.Ipc;

namespace Vex.Windows.App.Views;

public sealed partial class HomePage : Page
{
    private static readonly TimeSpan RefreshInterval =
        TimeSpan.FromSeconds(10);
    private readonly AppServices _services = AppServices.Current;
    private readonly List<VpnLocation> _locations = [];
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _refreshTimer;
    private DateTimeOffset _lastRecoveryAttempt = DateTimeOffset.MinValue;
    private bool _serverDialogOpen;

#if DEBUG
    private static bool IsPreviewMode =>
        string.Equals(
            Environment.GetEnvironmentVariable("VEX_WINDOWS_PREVIEW"),
            "1",
            StringComparison.Ordinal);
#else
    private static bool IsPreviewMode => false;
#endif

    public HomePage()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
        Render();
    }

    private async void OnLoaded(object sender, RoutedEventArgs args)
    {
        _services.VpnUiState.Changed += OnVpnUiStateChanged;
        _services.Preferences.Changed += OnPreferencesChanged;
        _services.CustomerRealtimeChanged += OnCustomerRealtimeChanged;
        if (IsPreviewMode)
        {
            LoadPreviewLocations();
            return;
        }

        StartRefreshTimer();
        await LoadLocationsAsync();
        await RefreshStatusAsync();
    }

    private void OnUnloaded(object sender, RoutedEventArgs args)
    {
        _services.VpnUiState.Changed -= OnVpnUiStateChanged;
        _services.Preferences.Changed -= OnPreferencesChanged;
        _services.CustomerRealtimeChanged -= OnCustomerRealtimeChanged;
        _refreshTimer?.Stop();
        _refreshTimer = null;
    }

    private void OnCustomerRealtimeChanged(
        object? sender,
        CustomerRealtimeChangedEventArgs args)
    {
        var domains = args.Metadata.Domains;
        if (args.Event.Type != "customer.resync" &&
            !domains.Any(domain => domain is
                "devices" or
                "provisioning" or
                "connection" or
                "status"))
        {
            return;
        }
        DispatcherQueue.TryEnqueue(async () =>
        {
            if (CoordinatorStateAvailable())
            {
                await LoadLocationsAsync();
            }
        });
    }

    private bool CoordinatorStateAvailable() =>
        _services.Coordinator.CurrentState is not null;

    private async void OnPowerButtonClick(
        object sender,
        RoutedEventArgs args)
    {
        var snapshot = _services.VpnUiState.Snapshot;
        if (!VpnConnectionActionPolicy.ShouldDisconnect(snapshot))
        {
            // Startup and periodic background checks keep this snapshot fresh.
            // Connecting must never wait on the updater's network timeout.
            var update = _services.UpdateService.CurrentSnapshot;
            if (update.UpdateAvailable &&
                update.Required &&
                !global::Windows.ApplicationModel.Package.Current.Id.Name.EndsWith(
                    ".Dev",
                    StringComparison.Ordinal))
            {
                ShowNotice(
                    ErrorMessage("required_update"),
                    InfoBarSeverity.Warning);
                _services.MainWindow?.NavigateToSection(
                    AppSection.Settings,
                    forceReload: true);
                return;
            }

            await RunRequestAsync(
                ConnectWithPreferencesAsync);
            if (_services.VpnUiState.Snapshot.Phase ==
                VpnConnectionPhase.Connected)
            {
                _services.VpnUiState.MarkConnectionDesired(true);
            }
            return;
        }

        _services.VpnUiState.MarkConnectionDesired(false);
        await RunRequestAsync(
            token => _services.VpnClient.DisconnectAsync(token));
    }

    private async Task RefreshStatusAsync()
    {
        await RunRequestAsync(
            token => _services.VpnClient.GetStatusAsync(token));
    }

    private async Task LoadLocationsAsync()
    {
        try
        {
            var locations = await _services.ProductParity.GetLocationsAsync(
                _services.Coordinator,
                CancellationToken.None);
            _locations.Clear();
            _locations.AddRange(locations);
            LocationPicker.ItemsSource = _locations;
            SelectPreferredLocation();
            RefreshLocationCards();
            LocationCapabilityText.Text = _locations.Count <= 1
                ? "Сейчас доступен один сервер."
                : $"{_locations.Count} доступных серверов.";
        }
        catch (Exception error) when (
            error is HttpRequestException
                or InvalidOperationException
                or NativeClientFlowException
                or OperationCanceledException)
        {
            LocationCapabilityText.Text =
                "Список серверов временно недоступен.";
            ShowNotice(
                error.InnerException?.Message ?? error.Message,
                InfoBarSeverity.Warning);
        }
        finally
        {
            Render();
        }
    }

    private void LoadPreviewLocations()
    {
        _locations.Clear();
        _locations.AddRange(
        [
            new VpnLocation(
                "de-1",
                "Frankfurt",
                "available",
                1,
                "DE",
                "🇩🇪",
                "healthy",
                12),
            new VpnLocation(
                "fi-1",
                "Helsinki",
                "available",
                1,
                "FI",
                "🇫🇮",
                "healthy",
                8),
            new VpnLocation(
                "nl-1",
                "Amsterdam",
                "available",
                2,
                "NL",
                "🇳🇱",
                "healthy",
                17),
        ]);
        LocationPicker.ItemsSource = _locations;
        SelectPreferredLocation();
        RefreshLocationCards();
        FooterMessage.Text = string.Empty;
        Render();
    }

    private async Task RunRequestAsync(
        Func<CancellationToken, Task<VpnServiceResponse>> operation)
    {
        PowerButton.IsEnabled = false;
        try
        {
            var response = await _services.VpnUiState.RunAsync(
                operation,
                CancellationToken.None);
            if (response.Success)
            {
                HideNotice();
            }
            else
            {
                var errorCode = response.ErrorCode ?? "unknown";
                LogUiFailure(
                    new InvalidOperationException(
                        $"vpn_service_response:{errorCode}"));
                if (errorCode == "vpn_service_unavailable")
                {
                    HideNotice();
                }
                else
                {
                    ShowNotice(
                        $"{ErrorMessage(errorCode)} Код: {errorCode}.",
                        InfoBarSeverity.Error);
                }
            }
        }
        catch (Exception error) when (
            error is IOException
                or UnauthorizedAccessException
                or CryptographicException
                or HttpRequestException
                or InvalidOperationException
                or NativeClientFlowException
                or VexApiException
                or VpnIpcProtocolException
                or OperationCanceledException)
        {
            LogUiFailure(error);
            var errorCode = error is NativeClientFlowException flow
                ? flow.Code
                : "vpn_service_unavailable";
            var failure = VpnConnectionSnapshot.ClientFailure(
                _services.VpnUiState.Snapshot,
                errorCode);
            _services.VpnUiState.Apply(new VpnServiceResponse(
                requestId: $"ui-{Guid.NewGuid():N}",
                success: false,
                snapshot: failure,
                errorCode: errorCode));
            if (errorCode == "vpn_service_unavailable")
            {
                HideNotice();
            }
            else
            {
                ShowNotice(
                    $"{ErrorMessage(errorCode)} Код: {errorCode}.",
                    InfoBarSeverity.Error);
            }
        }
        finally
        {
            Render();
        }
    }

    private static void LogUiFailure(Exception error)
    {
        try
        {
            var directory = Path.Combine(
                Environment.GetFolderPath(
                    Environment.SpecialFolder.LocalApplicationData),
                "VEX",
                "VPN");
            Directory.CreateDirectory(directory);
            File.AppendAllText(
                Path.Combine(directory, "app-errors.log"),
                $"{DateTimeOffset.UtcNow:O} {error.GetType().Name}: {error.Message}{Environment.NewLine}");
        }
        catch
        {
            // Diagnostics must not replace the original VPN failure.
        }
    }

    private async void OnServerPickerClick(
        object sender,
        RoutedEventArgs args)
    {
        if (_serverDialogOpen)
        {
            return;
        }

        SelectPreferredLocation();
        _serverDialogOpen = true;
        try
        {
            await ServerPickerDialog.ShowAsync();
        }
        finally
        {
            _serverDialogOpen = false;
        }
    }

    private void OnCloseServerPickerClick(
        object sender,
        RoutedEventArgs args) =>
        ServerPickerDialog.Hide();

    private void OnAutoServerClick(
        object sender,
        RoutedEventArgs args)
    {
        AutoServerRadio.IsChecked = true;
        ManualServerRadio.IsChecked = false;
        OnApplyLocationClick(sender, args);
    }

    private void OnLocationItemClick(
        object sender,
        ItemClickEventArgs args)
    {
        LocationPicker.SelectedItem = args.ClickedItem;
        AutoServerRadio.IsChecked = false;
        ManualServerRadio.IsChecked = true;
        OnApplyLocationClick(sender, args);
    }

    private void OnLocationCarouselItemClick(
        object sender,
        ItemClickEventArgs args)
    {
        if (args.ClickedItem is LocationCardPresentation card)
        {
            SelectLocationCard(card.Location);
        }
    }

    private void OnLocationCardClick(
        object sender,
        RoutedEventArgs args)
    {
        if (sender is Button { Tag: VpnLocation location })
        {
            SelectLocationCard(location);
        }
    }

    private void SelectLocationCard(VpnLocation location)
    {
        LocationPicker.SelectedItem = location;
        AutoServerRadio.IsChecked = false;
        ManualServerRadio.IsChecked = true;
        OnApplyLocationClick(LocationCarousel, new RoutedEventArgs());
    }

    private void OnLocationCardPointerEntered(
        object sender,
        Microsoft.UI.Xaml.Input.PointerRoutedEventArgs args) =>
        SetCountryArtworkHover(sender as DependencyObject, true);

    private void OnLocationCardPointerExited(
        object sender,
        Microsoft.UI.Xaml.Input.PointerRoutedEventArgs args) =>
        SetCountryArtworkHover(sender as DependencyObject, false);

    private void OnServerModeChecked(
        object sender,
        RoutedEventArgs args)
    {
        if (LocationPicker is null ||
            ApplyLocationButton is null ||
            AutoServerRadio is null)
        {
            return;
        }

        var auto = AutoServerRadio.IsChecked == true;
        LocationPicker.IsEnabled = !auto;
        ApplyLocationButton.Content = auto
            ? "Использовать автовыбор"
            : "Применить сервер";
    }

    private async void OnApplyLocationClick(
        object sender,
        RoutedEventArgs args)
    {
        var auto = AutoServerRadio.IsChecked == true;
        var selected = LocationPicker.SelectedItem as VpnLocation;
        if (!auto && selected is null)
        {
            ShowNotice(
                "Выберите сервер из списка.",
                InfoBarSeverity.Warning);
            return;
        }

        var selectedLocationId = auto ? null : selected!.Id;
        _services.Preferences.Update(current => current with
        {
            AutoServerEnabled = auto,
            SelectedLocationId = selectedLocationId,
        });
        if (auto)
        {
            if (_services.VpnUiState.Snapshot.Phase ==
                VpnConnectionPhase.Connected)
            {
                await RunRequestAsync(
                    token => _services.VpnClient.DisconnectAsync(token));
                await RunRequestAsync(ConnectWithPreferencesAsync);
            }
            ServerPickerDialog.Hide();
            ShowNotice(
                "Автоматический выбор сервера включен.",
                InfoBarSeverity.Success);
            Render();
            return;
        }

        SetLocationBusy(true);
        try
        {
            var result = await _services.ProductParity.SelectLocationAsync(
                _services.Coordinator,
                selectedLocationId!,
                reconnectIfConnected:
                    _services.VpnUiState.Snapshot.Phase ==
                    VpnConnectionPhase.Connected,
                CancellationToken.None);
            ShowNotice(
                result.Message,
                result.Applied
                    ? InfoBarSeverity.Success
                    : InfoBarSeverity.Informational);
            if (result.Applied)
            {
                await RefreshStatusAsync();
            }
            ServerPickerDialog.Hide();
        }
        catch (Exception error) when (
            error is InvalidOperationException
                or NativeClientFlowException
                or HttpRequestException)
        {
            ShowNotice(
                error.Message,
                InfoBarSeverity.Error);
        }
        finally
        {
            SetLocationBusy(false);
            Render();
        }
    }

    private void StartRefreshTimer()
    {
        _refreshTimer ??= DispatcherQueue.CreateTimer();
        _refreshTimer.Interval = RefreshInterval;
        _refreshTimer.IsRepeating = true;
        _refreshTimer.Tick -= OnRefreshTimerTick;
        _refreshTimer.Tick += OnRefreshTimerTick;
        _refreshTimer.Start();
    }

    private async void OnRefreshTimerTick(
        Microsoft.UI.Dispatching.DispatcherQueueTimer sender,
        object args)
    {
        if (!PowerButton.IsEnabled)
        {
            return;
        }

        await RefreshStatusAsync();
        var preferences = _services.Preferences.Current;
        var snapshot = _services.VpnUiState.Snapshot;
        if (!preferences.AutoRecoveryEnabled ||
            !_services.VpnUiState.ConnectionDesired ||
            snapshot.Phase is not (
                VpnConnectionPhase.Disconnected or
                VpnConnectionPhase.Error) ||
            DateTimeOffset.UtcNow - _lastRecoveryAttempt <
                TimeSpan.FromSeconds(30))
        {
            return;
        }

        _lastRecoveryAttempt = DateTimeOffset.UtcNow;
        await RunRequestAsync(
            ConnectWithPreferencesAsync);
    }

    private async Task<VpnServiceResponse> ConnectWithPreferencesAsync(
        CancellationToken cancellationToken)
    {
        var preferences = _services.Preferences.Current;
        return await _services.ProductParity.ConnectAsync(
            _services.Coordinator,
            preferences,
            cancellationToken);
    }

    private void OnVpnUiStateChanged(object? sender, EventArgs args) =>
        DispatcherQueue.TryEnqueue(Render);

    private void OnPreferencesChanged(object? sender, EventArgs args) =>
        DispatcherQueue.TryEnqueue(() =>
        {
            SelectPreferredLocation();
            Render();
        });

    private void SelectPreferredLocation()
    {
        if (AutoServerRadio is null ||
            ManualServerRadio is null ||
            LocationPicker is null)
        {
            return;
        }

        var preferences = _services.Preferences.Current;
        AutoServerRadio.IsChecked = preferences.AutoServerEnabled;
        ManualServerRadio.IsChecked = !preferences.AutoServerEnabled;
        LocationPicker.SelectedItem = _locations.FirstOrDefault(location =>
                string.Equals(
                    location.Id,
                    preferences.SelectedLocationId,
                    StringComparison.OrdinalIgnoreCase)) ??
            _locations.FirstOrDefault(location =>
                string.Equals(
                    location.Id,
                    _services.Coordinator.CurrentState?.LocationId,
                    StringComparison.OrdinalIgnoreCase)) ??
            _locations.FirstOrDefault();
        LocationPicker.IsEnabled = !preferences.AutoServerEnabled;
        RefreshLocationCards();
    }

    private void SetLocationBusy(bool busy)
    {
        ApplyLocationButton.IsEnabled = !busy;
        LocationPicker.IsEnabled =
            !busy && AutoServerRadio.IsChecked != true;
        AutoServerRadio.IsEnabled = !busy;
        ManualServerRadio.IsEnabled = !busy;
    }

    private void Render()
    {
        var snapshot = _services.VpnUiState.Snapshot;
        (PowerButtonText.Text, StatusText.Text, PowerButton.IsEnabled) = snapshot.Phase switch
        {
            VpnConnectionPhase.Disconnected =>
                ("Не подключено", "Нажмите, чтобы подключить VPN", true),
            VpnConnectionPhase.Connecting =>
                ("Подключение…", "Ждём подтверждение сервера", false),
            VpnConnectionPhase.Connected =>
                ("Подключено", "VPN защищает ваше соединение", true),
            VpnConnectionPhase.Disconnecting =>
                ("Отключение…", "Завершаем защищённую сессию", false),
            VpnConnectionPhase.Error
                when VpnConnectionActionPolicy.ShouldDisconnect(snapshot) =>
                ("Нужна очистка VPN", "Нажмите, чтобы отключить", true),
            VpnConnectionPhase.Error =>
                ("Нужна проверка", "Нажмите, чтобы повторить", true),
            _ => ("Неизвестное состояние", "Нажмите, чтобы повторить", true),
        };
        var busy = snapshot.Phase is
            VpnConnectionPhase.Connecting or
            VpnConnectionPhase.Disconnecting;
        PowerBusyIndicator.IsActive = busy;
        PowerBusyIndicator.Visibility = busy
            ? Visibility.Visible
            : Visibility.Collapsed;
        FooterMessage.Text = snapshot.ErrorCode is null
            ? string.Empty
            : ErrorMessage(snapshot.ErrorCode);

        var preferences = _services.Preferences.Current;
        var locationId = preferences.AutoServerEnabled
            ? snapshot.LocationId ??
                _services.Coordinator.CurrentState?.LocationId
            : preferences.SelectedLocationId ??
                snapshot.LocationId;
        var location = _locations.FirstOrDefault(candidate =>
            string.Equals(
                candidate.Id,
                locationId,
                StringComparison.OrdinalIgnoreCase));
        ReceivedText.Text = FormatBytes(
            _services.VpnUiState.ReceivedBytes);
        SentText.Text = FormatBytes(
            _services.VpnUiState.SentBytes);
        RefreshLocationCards();
    }

    private void RefreshLocationCards()
    {
        if (LocationCarousel is null)
        {
            return;
        }

        var preferences = _services.Preferences.Current;
        var selectedId = IsPreviewMode
            ? _locations.FirstOrDefault()?.Id
            : preferences.AutoServerEnabled
                ? _services.VpnUiState.Snapshot.LocationId ??
                    _services.Coordinator.CurrentState?.LocationId ??
                    _locations.FirstOrDefault()?.Id
                : preferences.SelectedLocationId ??
                    _services.VpnUiState.Snapshot.LocationId;
        LocationCarousel.ItemsSource = _locations
            .Select(location => LocationCardPresentation.Create(
                location,
                string.Equals(
                    location.Id,
                    selectedId,
                    StringComparison.OrdinalIgnoreCase)))
            .ToArray();
    }

    private static void SetCountryArtworkHover(
        DependencyObject? root,
        bool hovered)
    {
        var artwork = FindDescendant<Microsoft.UI.Xaml.Shapes.Path>(
            root,
            "CountryArtwork");
        if (artwork is null)
        {
            return;
        }

        if (artwork.RenderTransform is ScaleTransform scale)
        {
            scale.ScaleX = hovered ? 1.22 : 1;
            scale.ScaleY = hovered ? 1.22 : 1;
        }
        artwork.Opacity = hovered
            ? Math.Max(artwork.Opacity, 0.25)
            : artwork.DataContext is LocationCardPresentation card
                ? card.CountryOpacity
                : 0.08;
    }

    private static T? FindDescendant<T>(
        DependencyObject? root,
        string name)
        where T : FrameworkElement
    {
        if (root is null)
        {
            return null;
        }

        for (var index = 0;
             index < VisualTreeHelper.GetChildrenCount(root);
             index++)
        {
            var child = VisualTreeHelper.GetChild(root, index);
            if (child is T candidate &&
                string.Equals(
                    candidate.Name,
                    name,
                    StringComparison.Ordinal))
            {
                return candidate;
            }

            var nested = FindDescendant<T>(child, name);
            if (nested is not null)
            {
                return nested;
            }
        }

        return null;
    }

    private static string FormatBytes(ulong bytes)
    {
        string[] units = ["Б", "КБ", "МБ", "ГБ", "ТБ"];
        var value = (double)bytes;
        var unit = 0;
        while (value >= 1024 && unit < units.Length - 1)
        {
            value /= 1024;
            unit++;
        }

        return unit == 0
            ? $"{bytes} {units[unit]}"
            : $"{value:0.#} {units[unit]}";
    }

    private void ShowNotice(string message, InfoBarSeverity severity)
    {
        FoundationNotice.Message = message;
        FoundationNotice.Severity = severity;
        FoundationNotice.IsOpen = true;
    }

    private void HideNotice()
    {
        FoundationNotice.IsOpen = false;
        FoundationNotice.Message = string.Empty;
    }

    private static string ErrorMessage(string? errorCode) => errorCode switch
    {
        "unauthorized" => "Требуется восстановить безопасную установку VEX.",
        "tunnel_runtime_missing" => "Компоненты VPN повреждены или отсутствуют.",
        "tunnel_adapter_timeout" => "Сетевой адаптер VPN не запустился вовремя.",
        "sign_in_required" => "Сначала войдите в аккаунт на вкладке «Аккаунт».",
        "windows_hello_required" => "Сначала разблокируйте сохраненную сессию через Windows Hello.",
        "vpn_profile_unsigned" => "Сервер вернул неподписанный VPN-профиль.",
        "vpn_profile_revoked" => "Это устройство отозвано. Войдите снова.",
        "vpn_key_rotation_required" => "Требуется безопасное обновление ключа устройства.",
        "required_update" => "Перед подключением установите обязательное обновление VEX.",
        "vpn_service_unavailable" => "Системный компонент VEX недоступен. Откройте настройки для восстановления.",
        _ => "Не удалось выполнить операцию VPN.",
    };

    private sealed record LocationCardPresentation(
        VpnLocation Location,
        string FlagEmoji,
        string? FlagAsset,
        string DisplayName,
        string AvailabilityText,
        string LatencyText,
        Geometry CountryGeometry,
        Brush CardBackground,
        Brush CardBorder,
        Brush CountryFill,
        Brush CountryStroke,
        double CountryOpacity,
        Brush SelectionFill,
        Brush SelectionStroke,
        string SelectionGlyph)
    {
        public static LocationCardPresentation Create(
            VpnLocation location,
            bool selected)
        {
            var countryCode = !string.IsNullOrWhiteSpace(
                location.CountryCode)
                ? location.CountryCode
                : location.Id.Split(
                    '-',
                    StringSplitOptions.RemoveEmptyEntries)
                    .FirstOrDefault();
            return new LocationCardPresentation(
                Location: location,
                FlagEmoji: countryCode?.ToUpperInvariant() ?? "◇",
                FlagAsset: CountryFlagAsset(countryCode),
                DisplayName: NativeLocationLabel.Russian(location.Id),
                AvailabilityText:
                    $"{location.HealthyNodes} узлов · доступен",
                LatencyText: location.LatencyMs is null
                    ? "—"
                    : $"{Math.Round(location.LatencyMs.Value):0} мс",
                CountryGeometry:
                    CountrySilhouetteGeometry.Create(countryCode),
                CardBackground: Brush(
                    selected ? (byte)0xD9 : (byte)0xC4,
                    0x07,
                    0x11,
                    0x13),
                CardBorder: Brush(
                    selected ? (byte)0xFF : (byte)0x18,
                    selected ? (byte)0x22 : (byte)0xFF,
                    selected ? (byte)0xD3 : (byte)0xFF,
                    selected ? (byte)0xEE : (byte)0xFF),
                CountryFill: Brush(0xFF, 0x22, 0xD3, 0xEE),
                CountryStroke: Brush(0xFF, 0xB9, 0xFB, 0xFF),
                CountryOpacity: selected ? 0.12 : 0.055,
                SelectionFill: Brush(
                    selected ? (byte)0xFF : (byte)0x00,
                    0x22,
                    0xD3,
                    0xEE),
                SelectionStroke: Brush(
                    0xFF,
                    selected ? (byte)0x22 : (byte)0x8F,
                    selected ? (byte)0xD3 : (byte)0xBE,
                    selected ? (byte)0xEE : (byte)0xC6),
                SelectionGlyph: selected ? "\uE73E" : string.Empty);
        }

        private static string? CountryFlagAsset(string? countryCode) =>
            countryCode?.ToUpperInvariant() switch
            {
                "DE" => "ms-appx:///Assets/flags/de.svg",
                "FI" => "ms-appx:///Assets/flags/fi.svg",
                "NL" => "ms-appx:///Assets/flags/nl.svg",
                _ => null,
            };

        private static SolidColorBrush Brush(
            byte alpha,
            byte red,
            byte green,
            byte blue) =>
            new(global::Windows.UI.Color.FromArgb(
                alpha,
                red,
                green,
                blue));
    }
}
