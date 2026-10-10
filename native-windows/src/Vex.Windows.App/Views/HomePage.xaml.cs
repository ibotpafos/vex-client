using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Composition;
using System.Numerics;
using System.Security.Cryptography;
using Windows.Foundation;
using Windows.UI.ViewManagement;
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
    private readonly AppServices _services = AppServices.Current;
    private readonly List<VpnLocation> _locations = [];
    private bool _serverDialogOpen;
    private int _busyRequestCount;
    private bool _requestBusy => _busyRequestCount > 0;
    private CancellationTokenSource? _pageLifetime;
    private int _locationLoadGeneration;
    private bool _catalogLoading;
    private bool _selectionBusy;
    private bool _synchronizingFilter;
    private string? _catalogError;
    private IReadOnlyList<VpnLocation> _filteredLocations = [];
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _catalogTimer;
    private Flyout? _countryFlyout;
    private VpnLocation? _pendingLocation;
    private readonly UISettings _uiSettings = new();
    private readonly List<double> _receivedHistory = [];
    private readonly List<double> _sentHistory = [];
    private ulong? _previousReceivedBytes;
    private ulong? _previousSentBytes;
    private DateTimeOffset _lastTrafficSampleAt;
    private bool _heroAnimationsStarted;
    private bool _heroWasConnected;
    private string? _locationCardsSignature;

    private CollectionViewSource CatalogSource => (CollectionViewSource)Resources["ServerCatalogSource"];

    private static bool IsPreviewMode => UiPreviewContext.IsAuthenticated;

    public HomePage()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
        SynchronizeCatalogFilter();
        Render();
    }

    private async void OnLoaded(object sender, RoutedEventArgs args)
    {
        if (_pageLifetime is not null) return;
        _pageLifetime = new CancellationTokenSource();
        var lifetime = _pageLifetime;
        _uiSettings.AnimationsEnabledChanged += OnAnimationsEnabledChanged;
        UpdateResponsiveLayout();
        StartHeroAnimations();
        _services.VpnUiState.Changed += OnVpnUiStateChanged;
        _services.Preferences.Changed += OnPreferencesChanged;
        _services.CustomerRealtimeChanged += OnCustomerRealtimeChanged;
        if (IsPreviewMode)
        {
            LoadPreviewLocations();
            return;
        }

        await LoadLocationsAsync();
        if (!lifetime.IsCancellationRequested) await RefreshStatusAsync();
    }

    private void OnUnloaded(object sender, RoutedEventArgs args)
    {
        _pageLifetime?.Cancel();
        _pageLifetime?.Dispose();
        _pageLifetime = null;
        _uiSettings.AnimationsEnabledChanged -= OnAnimationsEnabledChanged;
        StopHeroAnimations();
        _locationLoadGeneration++;
        _catalogTimer?.Stop();
        _catalogTimer = null;
        _countryFlyout?.Hide();
        _countryFlyout = null;
        if (_serverDialogOpen) ServerPickerDialog.Hide();
        _services.VpnUiState.Changed -= OnVpnUiStateChanged;
        _services.Preferences.Changed -= OnPreferencesChanged;
        _services.CustomerRealtimeChanged -= OnCustomerRealtimeChanged;
    }

    private void OnHomeSizeChanged(object sender, SizeChangedEventArgs args) => UpdateResponsiveLayout();

    private void UpdateResponsiveLayout()
    {
        if (HomeRoot is null || ReceivedCard is null) return;
        var compact = HomeRoot.ActualWidth < 620;
        HomeContent.Margin = new Thickness(compact ? 20 : 30, 38, compact ? 20 : 30, 12);
        ReceivedCard.Width = SentCard.Width = compact ? 110 : 136;
        PowerControlColumn.Width = new GridLength(compact ? 216 : 244);
        RefreshLocationCards();
        if (_serverDialogOpen) UpdateServerPickerSize();
    }

    private void UpdateServerPickerSize()
    {
        if (XamlRoot is not { } root) return;
        ServerPickerContent.Width = Math.Clamp(root.Size.Width - 88, 260, 440);
        ServerPickerContent.MaxHeight = Math.Max(280, root.Size.Height - 96);
    }

    private IEnumerable<Microsoft.UI.Xaml.Shapes.Ellipse> OrbitRings =>
        [Orbit0, Orbit1, Orbit2, Orbit3, Orbit4, Orbit5];

    private void OnAnimationsEnabledChanged(UISettings sender, object args) =>
        DispatcherQueue.TryEnqueue(() =>
        {
            StartHeroAnimations();
            if (!_uiSettings.AnimationsEnabled) SetPowerHover(false);
        });

    private void StartHeroAnimations()
    {
        if (_heroAnimationsStarted) StopHeroAnimations();
        if (_pageLifetime is null || !_uiSettings.AnimationsEnabled) return;
        var index = 0;
        foreach (var ring in OrbitRings)
        {
            var visual = ElementCompositionPreview.GetElementVisual(ring);
            visual.CenterPoint = new Vector3((float)ring.Width / 2, (float)ring.Height / 2, 0);
            var animation = visual.Compositor.CreateVector3KeyFrameAnimation();
            animation.InsertKeyFrame(0, Vector3.One);
            animation.InsertKeyFrame(0.48f, new Vector3(_heroWasConnected ? 1.065f : 1.035f, _heroWasConnected ? 1.065f : 1.035f, 1));
            animation.InsertKeyFrame(1, Vector3.One);
            animation.Duration = TimeSpan.FromSeconds(_heroWasConnected ? 3.6 : 4.4);
            animation.DelayTime = TimeSpan.FromMilliseconds(index++ * 90);
            animation.IterationBehavior = AnimationIterationBehavior.Forever;
            visual.StartAnimation("Scale", animation);
        }
        _heroAnimationsStarted = true;
    }

    private void StopHeroAnimations()
    {
        foreach (var ring in OrbitRings)
        {
            var visual = ElementCompositionPreview.GetElementVisual(ring);
            visual.StopAnimation("Scale");
            visual.Scale = Vector3.One;
        }
        _heroAnimationsStarted = false;
    }

    private void RenderOrbitColors(bool connected)
    {
        var index = 0;
        foreach (var ring in OrbitRings)
        {
            var opacity = Math.Max(0.028, (connected ? 0.21 : 0.14) - index++ * 0.026);
            ring.Stroke = HomeBrush((byte)Math.Round(opacity * 255), connected ? (byte)0xB9 : (byte)0x22,
                connected ? (byte)0xFB : (byte)0xD3, connected ? (byte)0xFF : (byte)0xEE);
        }
        PowerGlow.Fill = HomeBrush(connected ? (byte)0x10 : (byte)0x09, 0x22, 0xD3, 0xEE);
    }

    private void OnPowerPointerEntered(object sender, PointerRoutedEventArgs args) => SetPowerHover(true);

    private void OnPowerPointerExited(object sender, PointerRoutedEventArgs args) => SetPowerHover(false);

    private void SetPowerHover(bool hovered)
    {
        var scale = hovered && _uiSettings.AnimationsEnabled && PowerButton.IsEnabled ? 1.035 : 1;
        PowerButton.RenderTransformOrigin = new Point(0.5, 0.5);
        PowerButton.RenderTransform = new ScaleTransform { ScaleX = scale, ScaleY = scale };
    }

    private void RecordTrafficSample()
    {
        var received = _services.VpnUiState.ReceivedBytes;
        var sent = _services.VpnUiState.SentBytes;
        var now = DateTimeOffset.UtcNow;
        if (_previousReceivedBytes is null || _previousSentBytes is null ||
            received < _previousReceivedBytes || sent < _previousSentBytes)
        {
            _previousReceivedBytes = received;
            _previousSentBytes = sent;
            _lastTrafficSampleAt = now;
            _receivedHistory.Clear();
            _sentHistory.Clear();
        }
        var elapsed = (now - _lastTrafficSampleAt).TotalSeconds;
        if (elapsed >= 0.8)
        {
            AppendTrafficSample(_receivedHistory, (received - _previousReceivedBytes!.Value) / elapsed);
            AppendTrafficSample(_sentHistory, (sent - _previousSentBytes!.Value) / elapsed);
            _previousReceivedBytes = received;
            _previousSentBytes = sent;
            _lastTrafficSampleAt = now;
        }
        ReceivedSparkline.Points = TrafficPoints(_receivedHistory);
        SentSparkline.Points = TrafficPoints(_sentHistory);
    }

    private static void AppendTrafficSample(List<double> history, double bytesPerSecond)
    {
        var target = Math.Clamp(0.1 + Math.Log10(bytesPerSecond + 1) / 7 * 0.9, 0.1, 1);
        history.Add(history.Count == 0 ? target : history[^1] * 0.72 + target * 0.28);
        if (history.Count > 12) history.RemoveAt(0);
    }

    private static PointCollection TrafficPoints(List<double> history)
    {
        var points = new PointCollection();
        for (var index = 0; index < 12; index++)
        {
            var sampleIndex = index - (12 - history.Count);
            var level = sampleIndex < 0 ? 0.1 : history[sampleIndex];
            points.Add(new Point(index * 120.0 / 11, 18 * (1 - level)));
        }
        return points;
    }

    private static SolidColorBrush HomeBrush(byte alpha, byte red, byte green, byte blue) =>
        new(global::Windows.UI.Color.FromArgb(alpha, red, green, blue));

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
            if (_pageLifetime is not null && CoordinatorStateAvailable())
            {
                await LoadLocationsAsync();
            }
        });
    }

    private bool CoordinatorStateAvailable() =>
        _services.Coordinator.CurrentStateAccess == ClientStateAccessKind.Available;

    private async void OnPowerButtonClick(
        object sender,
        RoutedEventArgs args)
    {
        if (_services.VpnUiState.IsConnectionInFlight && _services.VpnUiState.ConnectionDesired)
        {
            await RunRequestAsync(token => _services.VpnUiState.CancelConnectionAsync(
                _services.VpnClient.DisconnectAsync, token), alreadySerialized: true);
            return;
        }
        if (_requestBusy || _selectionBusy) return;
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

            _services.VpnUiState.MarkConnectionDesired(true);
            await RunRequestAsync(
                ConnectWithPreferencesAsync, connectionOperation: true);
            return;
        }

        _services.VpnUiState.MarkConnectionDesired(false);
        await RunRequestAsync(
            token => _services.VpnClient.DisconnectAsync(token));
    }

    private async Task RefreshStatusAsync()
    {
        await RunRequestAsync(
            token => _services.VpnClient.GetStatusAsync(token), showBusy: false);
    }

    private async Task LoadLocationsAsync()
    {
        var generation = ++_locationLoadGeneration;
        var cancellationToken = _pageLifetime?.Token ?? CancellationToken.None;
        _catalogLoading = true;
        RenderCatalogStatus();
        try
        {
            var locations = await _services.ProductParity.GetLocationsAsync(
                _services.Coordinator,
                cancellationToken);
            if (cancellationToken.IsCancellationRequested || generation != _locationLoadGeneration) return;
            _locations.Clear();
            _locations.AddRange(locations);
            _catalogError = null;
            SelectPreferredLocation();
            RefreshLocationCards();
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
        catch (Exception error) when (
            error is HttpRequestException
                or InvalidOperationException
                or NativeClientFlowException
                or OperationCanceledException
                or VexApiException
                or IOException
                or UnauthorizedAccessException
                or CryptographicException)
        {
            if (generation != _locationLoadGeneration) return;
            _catalogError = "Не удалось обновить серверы. Сохранённый список остаётся доступен.";
            ShowNotice(
                error.InnerException?.Message ?? error.Message,
                InfoBarSeverity.Warning);
        }
        finally
        {
            if (generation == _locationLoadGeneration)
            {
                _catalogLoading = false;
                RenderCatalogStatus();
                Render();
            }
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
        SelectPreferredLocation();
        RefreshLocationCards();
        FooterMessage.Text = string.Empty;
        Render();
    }

    private async Task RunRequestAsync(
        Func<CancellationToken, Task<VpnServiceResponse>> operation,
        bool showBusy = true,
        bool connectionOperation = false,
        bool alreadySerialized = false)
    {
        if (showBusy) _busyRequestCount++;
        Render();
        try
        {
            var response = alreadySerialized
                ? await operation(CancellationToken.None)
                : connectionOperation
                    ? await _services.VpnUiState.RunConnectionAsync(operation, CancellationToken.None)
                    : await _services.VpnUiState.RunAsync(operation, CancellationToken.None);
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
        catch (OperationCanceledException) when (connectionOperation)
        {
            // Explicit cancellation is followed by confirmed service cleanup.
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
            if (showBusy) _busyRequestCount--;
            Render();
        }
    }

    private static void LogUiFailure(Exception error)
    {
        try
        {
            var directory = UiPreviewContext.StateDirectory ?? Path.Combine(
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
        if (_serverDialogOpen || XamlRoot is null)
        {
            return;
        }

        SelectPreferredLocation();
        ServerPickerDialog.XamlRoot = XamlRoot;
        UpdateServerPickerSize();
        _serverDialogOpen = true;
        StartCatalogTimer();
        try
        {
            if (!IsPreviewMode && !_catalogLoading) _ = LoadLocationsAsync();
            await ServerPickerDialog.ShowAsync();
        }
        catch (InvalidOperationException error)
        {
            LogUiFailure(error);
            ShowNotice("Не удалось открыть список серверов. Повторите попытку.", InfoBarSeverity.Warning);
        }
        finally
        {
            _serverDialogOpen = false;
            _catalogTimer?.Stop();
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
        _pendingLocation = null;
        AutoServerRadio.IsChecked = true;
        ManualServerRadio.IsChecked = false;
        OnApplyLocationClick(sender, args);
    }

    private void OnLocationItemClick(object sender, ItemClickEventArgs args)
    {
        if (args.ClickedItem is ServerRowPresentation row) SelectLocationCard(row.Location);
    }

    private void OnLocationCardClick(object sender, RoutedEventArgs args)
    {
        if (sender is not Button { Tag: ServerCountryGroup group } button || _selectionBusy) return;
        ShowCountryNodes(button, group);
    }

    private void ShowCountryNodes(Button anchor, ServerCountryGroup group)
    {
        _countryFlyout?.Hide();
        var panel = new StackPanel { Width = 360, Spacing = 8 };
        panel.Children.Add(new TextBlock
        {
            Text = group.Title,
            FontSize = 19,
            FontWeight = Microsoft.UI.Text.FontWeights.Bold,
        });
        panel.Children.Add(new TextBlock { Text = $"Доступно узлов: {group.AvailableNodeCount}", FontSize = 12 });
        var list = new ListView
        {
            ItemsSource = group.Locations.Select(CreateServerRow).ToArray(),
            ItemTemplate = (DataTemplate)Resources["ServerRowTemplate"],
            SelectionMode = ListViewSelectionMode.Single,
            IsItemClickEnabled = true,
            MaxHeight = 320,
            MinHeight = Math.Min(group.Locations.Count * 82, 320),
        };
        list.ItemClick += OnLocationItemClick;
        list.KeyDown += OnLocationPickerKeyDown;
        panel.Children.Add(list);
        _countryFlyout = new Flyout { Content = panel, Placement = FlyoutPlacementMode.Top };
        _countryFlyout.ShowAt(anchor);
    }

    private void SelectLocationCard(VpnLocation location)
    {
        if (_selectionBusy) return;
        if (!ServerCatalog.IsAvailable(location))
        {
            ShowNotice("Этот сервер сейчас недоступен. Выберите другой узел.", InfoBarSeverity.Warning);
            return;
        }
        _countryFlyout?.Hide();
        // Country cards contain presentation groups. VPN commands always use
        // the original selected node ID, including when the search hides it.
        var row = (CatalogSource.Source as IReadOnlyList<ServerCountryPresentation>)?
            .SelectMany(group => group.Rows).FirstOrDefault(item => item.Location.Id == location.Id);
        if (row is not null) LocationPicker.SelectedItem = row;
        _pendingLocation = location;
        AutoServerRadio.IsChecked = false;
        ManualServerRadio.IsChecked = true;
        OnApplyLocationClick(LocationCarousel, new RoutedEventArgs());
    }

    private void OnLocationCardPointerEntered(
        object sender,
        Microsoft.UI.Xaml.Input.PointerRoutedEventArgs args) =>
        SetCountryArtworkHover(sender as DependencyObject, true, _uiSettings.AnimationsEnabled);

    private void OnLocationCardPointerExited(
        object sender,
        Microsoft.UI.Xaml.Input.PointerRoutedEventArgs args) =>
        SetCountryArtworkHover(sender as DependencyObject, false, _uiSettings.AnimationsEnabled);

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
        LocationPicker.IsEnabled = !_selectionBusy;
        ApplyLocationButton.Content = auto
            ? "Использовать автовыбор"
            : "Применить сервер";
    }

    private async void OnApplyLocationClick(
        object sender,
        RoutedEventArgs args)
    {
        var auto = AutoServerRadio.IsChecked == true;
        if (_selectionBusy) return;
        var selected = _pendingLocation ?? (LocationPicker.SelectedItem as ServerRowPresentation)?.Location;
        _pendingLocation = null;
        if (!auto && selected is null)
        {
            ShowNotice(
                "Выберите сервер из списка.",
                InfoBarSeverity.Warning);
            return;
        }

        if (!auto && !ServerCatalog.IsAvailable(selected!))
        {
            ShowNotice("Этот сервер сейчас недоступен. Выберите другой узел.", InfoBarSeverity.Warning);
            return;
        }
        var selectedLocationId = auto ? null : selected!.Id;
        var previousPreferences = _services.Preferences.Current;
        if (auto)
        {
            await ApplyAutomaticSelectionAsync(previousPreferences);
            return;
        }
        try
        {
            _services.Preferences.Update(current => current with
            {
                AutoServerEnabled = auto,
                SelectedLocationId = selectedLocationId,
            });
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or CryptographicException)
        {
            ShowNotice(error.Message, InfoBarSeverity.Error);
            return;
        }
        SetLocationBusy(true);
        var selectionApplied = false;
        try
        {
            LocationSelectionResult? result = null;
            var reconnect = _services.VpnUiState.Snapshot.Phase == VpnConnectionPhase.Connected &&
                _services.VpnUiState.ConnectionDesired;
            async Task<VpnServiceResponse> ApplySelectionAsync(CancellationToken token)
            {
                result = await _services.ProductParity.SelectLocationAsync(
                    _services.Coordinator,
                    selectedLocationId!,
                    reconnectIfConnected:
                        _services.VpnUiState.Snapshot.Phase ==
                        VpnConnectionPhase.Connected && _services.VpnUiState.ConnectionDesired,
                    token,
                    _services.Preferences.Current.AntiLeakEnabled);
                selectionApplied = result.Applied;
                return await _services.VpnClient.GetDiagnosticsAsync(token);
            }
            var response = reconnect
                ? await _services.VpnUiState.RunConnectionAsync(ApplySelectionAsync, CancellationToken.None)
                : await _services.VpnUiState.RunAsync(ApplySelectionAsync, CancellationToken.None);
            ShowNotice(
                response.Success ? result!.Message : ErrorMessage(response.ErrorCode),
                response.Success && result!.Applied
                    ? InfoBarSeverity.Success
                    : InfoBarSeverity.Warning);
            ServerPickerDialog.Hide();
        }
        catch (Exception error) when (
            error is InvalidOperationException
                or NativeClientFlowException
                or HttpRequestException
                or VexApiException
                or IOException
                or UnauthorizedAccessException
                or CryptographicException
                or VpnIpcProtocolException
                or OperationCanceledException)
        {
            if (!selectionApplied)
            {
                try
                {
                    _services.Preferences.Update(current =>
                        current.AutoServerEnabled == auto && current.SelectedLocationId == selectedLocationId
                            ? current with
                            {
                                AutoServerEnabled = previousPreferences.AutoServerEnabled,
                                SelectedLocationId = previousPreferences.SelectedLocationId,
                            }
                            : current);
                }
                catch (Exception restoreError) when (restoreError is IOException or UnauthorizedAccessException or CryptographicException)
                {
                    LogUiFailure(restoreError);
                }
                SelectPreferredLocation();
            }
            if (error is not OperationCanceledException)
                ShowNotice(error.Message, InfoBarSeverity.Error);
        }
        finally
        {
            SetLocationBusy(false);
            Render();
        }
    }

    private async Task ApplyAutomaticSelectionAsync(NativeClientPreferences previousPreferences)
    {
        var restorationFailed = false;
        SetLocationBusy(true);
        _busyRequestCount++;
        Render();
        try
        {
            var reconnect = _services.VpnUiState.Snapshot.Phase == VpnConnectionPhase.Connected &&
                _services.VpnUiState.ConnectionDesired && !previousPreferences.AutoServerEnabled;
            async Task<VpnServiceResponse> ApplySelectionAsync(CancellationToken token)
            {
                _services.Preferences.Update(current => current with
                {
                    AutoServerEnabled = true,
                    SelectedLocationId = null,
                });
                try
                {
                    var snapshot = _services.VpnUiState.Snapshot;
                    if (snapshot.Phase != VpnConnectionPhase.Connected ||
                        !_services.VpnUiState.ConnectionDesired || previousPreferences.AutoServerEnabled)
                        return new VpnServiceResponse(Guid.NewGuid().ToString("N"), true, snapshot, null);

                    // The service admits the replacement signed profile before
                    // replacing the healthy tunnel. A failed switch keeps the
                    // coordinator's previous authorization and manual pin.
                    var switched = await ConnectWithPreferencesAsync(token);
                    if (!switched.Success) restorationFailed = !RestoreSelectionPreferences(previousPreferences, true, null);
                    return switched;
                }
                catch
                {
                    restorationFailed = !RestoreSelectionPreferences(previousPreferences, true, null);
                    throw;
                }
            }
            var response = reconnect
                ? await _services.VpnUiState.RunConnectionAsync(ApplySelectionAsync, CancellationToken.None)
                : await _services.VpnUiState.RunAsync(ApplySelectionAsync, CancellationToken.None);
            if (response.Success)
            {
                ServerPickerDialog.Hide();
                ShowNotice("Автоматический выбор сервера включен.", InfoBarSeverity.Success);
            }
            else
            {
                ShowNotice(ErrorMessage(response.ErrorCode) + (restorationFailed
                    ? " Не удалось сохранить прежние настройки сервера. Проверьте доступ к папке VEX."
                    : string.Empty), InfoBarSeverity.Error);
            }
        }
        catch (Exception error) when (error is InvalidOperationException or NativeClientFlowException or
            HttpRequestException or VexApiException or IOException or UnauthorizedAccessException or
            CryptographicException or VpnIpcProtocolException or OperationCanceledException)
        {
            LogUiFailure(error);
            var message = error is NativeClientFlowException flow ? ErrorMessage(flow.Code)
                : "Не удалось включить автовыбор. Повторите попытку.";
            if (error is not OperationCanceledException) ShowNotice(message + (restorationFailed
                ? " Не удалось сохранить прежние настройки сервера. Проверьте доступ к папке VEX."
                : string.Empty), InfoBarSeverity.Error);
        }
        finally
        {
            _busyRequestCount--;
            SetLocationBusy(false);
            SelectPreferredLocation();
            Render();
        }
    }

    private bool RestoreSelectionPreferences(NativeClientPreferences previous, bool auto, string? locationId)
    {
        try
        {
            _services.Preferences.Update(current =>
                current.AutoServerEnabled == auto && current.SelectedLocationId == locationId
                    ? current with
                    {
                        AutoServerEnabled = previous.AutoServerEnabled,
                        SelectedLocationId = previous.SelectedLocationId,
                    }
                    : current);
            return true;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or CryptographicException)
        {
            LogUiFailure(error);
            return false;
        }
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
        SynchronizeCatalogFilter();
        RenderServerCatalog();
        LocationPicker.IsEnabled = !_selectionBusy;
        RefreshLocationCards();
    }

    private void SetLocationBusy(bool busy)
    {
        _selectionBusy = busy;
        ApplyLocationButton.IsEnabled = !busy;
        LocationPicker.IsEnabled = !busy;
        LocationCarousel.IsEnabled = !busy;
        AutoServerRadio.IsEnabled = !busy;
        ManualServerRadio.IsEnabled = !busy;
        AutoServerButton.IsEnabled = !busy;
        EmptyLocationButton.IsEnabled = !busy;
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
        var canCancel = _services.VpnUiState.IsConnectionInFlight && _services.VpnUiState.ConnectionDesired;
        if (canCancel)
        {
            PowerButtonText.Text = "Подключение…";
            StatusText.Text = "Нажмите, чтобы отменить подключение";
            PowerButton.IsEnabled = true;
        }
        else if (_services.VpnUiState.IsConnectionCleanupInFlight && !_services.VpnUiState.ConnectionDesired)
        {
            PowerButtonText.Text = "Отключение…";
            StatusText.Text = "Подтверждаем отмену подключения";
            PowerButton.IsEnabled = false;
        }
        else PowerButton.IsEnabled &= !_requestBusy && !_selectionBusy;
        var busy = _requestBusy || _services.VpnUiState.IsConnectionInFlight ||
            _services.VpnUiState.IsConnectionCleanupInFlight || snapshot.Phase is
            VpnConnectionPhase.Connecting or
            VpnConnectionPhase.Disconnecting;
        PowerBusyIndicator.IsActive = busy;
        PowerBusyIndicator.Visibility = busy
            ? Visibility.Visible
            : Visibility.Collapsed;
        var connected = snapshot.Phase == VpnConnectionPhase.Connected;
        var tint = (Brush)Application.Current.Resources[connected ? "VexCyanLightBrush" : "VexCyanBrush"];
        PowerRing.Stroke = tint;
        PowerGlyph.Foreground = tint;
        PowerGlyph.Opacity = busy ? 0.22 : 1;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(PowerButton,
            canCancel ? "Отменить подключение VPN" :
                VpnConnectionActionPolicy.ShouldDisconnect(snapshot) ? "Отключить VPN" : "Подключить VPN");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(PowerButton, StatusText.Text);
        if (connected != _heroWasConnected)
        {
            _heroWasConnected = connected;
            StartHeroAnimations();
        }
        RenderOrbitColors(connected);
        FooterMessage.Text = snapshot.ErrorCode is null
            ? string.Empty
            : ErrorMessage(snapshot.ErrorCode);
        FooterNotice.Visibility = string.IsNullOrWhiteSpace(FooterMessage.Text) ? Visibility.Collapsed : Visibility.Visible;

        var preferences = _services.Preferences.Current;
        AutoServerSelectionIcon.Visibility = preferences.AutoServerEnabled ? Visibility.Visible : Visibility.Collapsed;
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
        RecordTrafficSample();
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
        var groups = ServerCatalog.Groups(_locations, selectedId, limit: 6);
        var availableWidth = Math.Max(240, Math.Min(1080, HomeRoot.ActualWidth - HomeContent.Margin.Left - HomeContent.Margin.Right));
        var columns = Math.Min(Math.Max(groups.Count, 1), availableWidth >= 780 ? 3 : availableWidth >= 500 ? 2 : 1);
        var cardWidth = (availableWidth - (columns - 1) * 12 - 4) / columns;
        var signature = $"{cardWidth:0.0}|" + string.Join('|', groups.Select(group =>
            $"{group.Id}:{group.Title}:{group.FlagEmoji}:{group.IsSelected}:{group.Representative.Id}:{group.AvailableNodeCount}:" +
            string.Join(';', group.Locations.Select(node =>
                $"{node.Id}:{node.City}:{node.Status}:{node.Availability}:{node.HealthyNodes}:{node.Awg3Nodes}:{node.LatencyMs}"))));
        if (_locationCardsSignature != signature)
        {
            _locationCardsSignature = signature;
            LocationCarousel.ItemsSource = groups.Select(group => LocationCardPresentation.Create(group, cardWidth)).ToArray();
        }
        LocationCarousel.Visibility = groups.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        EmptyLocationButton.Visibility = groups.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private string? PreferredLocationId => _services.Preferences.Current.AutoServerEnabled
        ? _services.VpnUiState.Snapshot.LocationId ?? _services.Coordinator.CurrentState?.LocationId
        : _services.Preferences.Current.SelectedLocationId ?? _services.VpnUiState.Snapshot.LocationId;

    private ServerCatalogFilter CurrentCatalogFilter => _services.Preferences.Current.ServerCatalogFilter switch
    {
        "fastest" => ServerCatalogFilter.Fastest,
        "favorites" => ServerCatalogFilter.Favorites,
        "available" => ServerCatalogFilter.Available,
        _ => ServerCatalogFilter.All,
    };

    private void SynchronizeCatalogFilter()
    {
        if (ServerFilterPicker is null) return;
        _synchronizingFilter = true;
        try
        {
            ServerFilterPicker.SelectedIndex = CurrentCatalogFilter switch
            {
                ServerCatalogFilter.Fastest => 1,
                ServerCatalogFilter.Favorites => 2,
                ServerCatalogFilter.Available => 3,
                _ => 0,
            };
        }
        finally { _synchronizingFilter = false; }
    }

    private void RenderServerCatalog()
    {
        if (LocationPicker is null || ServerSearchBox is null) return;
        var favorites = ServerCatalog.NormalizeFavoriteIds(_services.Preferences.Current.FavoriteLocationIds);
        _filteredLocations = ServerCatalog.Filter(_locations, ServerSearchBox.Text, CurrentCatalogFilter, favorites);
        var groups = ServerCatalog.Groups(_filteredLocations, PreferredLocationId)
            .OrderBy(group => _filteredLocations.ToList().FindIndex(location =>
                group.Locations.Any(member => member.Id == location.Id)))
            .Select(group => new ServerCountryPresentation(group.Title,
                _filteredLocations.Where(location => group.Locations.Any(member => member.Id == location.Id))
                    .Select(CreateServerRow).ToArray()))
            .ToArray();
        CatalogSource.Source = groups;
        LocationPicker.ItemsSource = CatalogSource.View;
        LocationPicker.SelectedItem = groups.SelectMany(group => group.Rows)
            .FirstOrDefault(row => string.Equals(row.Location.Id, PreferredLocationId, StringComparison.OrdinalIgnoreCase));
        CatalogCountText.Text = $"Стран: {groups.Length} · серверов: {_filteredLocations.Count}";
        CatalogEmptyText.Text = CurrentCatalogFilter == ServerCatalogFilter.Favorites && string.IsNullOrWhiteSpace(ServerSearchBox.Text)
            ? "Избранных серверов пока нет. Нажмите звезду рядом с узлом."
            : "Ничего не найдено. Измените поиск или фильтр.";
        CatalogEmptyText.Visibility = _filteredLocations.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        RenderCatalogStatus();
    }

    private ServerRowPresentation CreateServerRow(VpnLocation location)
    {
        var available = ServerCatalog.IsAvailable(location);
        var favorite = ServerCatalog.NormalizeFavoriteIds(_services.Preferences.Current.FavoriteLocationIds).Contains(location.Id);
        var title = string.IsNullOrWhiteSpace(location.City) ? location.Id : location.City;
        var status = available ? "Доступен" : location.Status?.Trim().ToLowerInvariant() switch
        {
            "maintenance" => "Обслуживание",
            "offline" => "Не в сети",
            _ => "Недоступен",
        };
        return new(location, title, location.Id,
            string.IsNullOrWhiteSpace(location.FlagEmoji) ? location.CountryCode?.ToUpperInvariant() ?? "◇" : location.FlagEmoji,
            status, available && location.LatencyMs is { } latency && double.IsFinite(latency) && latency >= 0
                ? $"{Math.Round(latency):0} мс" : "—",
            favorite ? "\uE735" : "\uE734",
            favorite ? $"Убрать {title} из избранного" : $"Добавить {title} в избранное",
            available ? 1 : 0.52,
            $"{ServerCatalog.CountryTitle(location)}, {title}, {location.Id}, {status}");
    }

    private void RenderCatalogStatus()
    {
        if (RefreshCatalogButton is null) return;
        RefreshCatalogButton.IsEnabled = !_catalogLoading;
        CatalogLoadingIndicator.IsActive = _catalogLoading;
        CatalogLoadingIndicator.Visibility = _catalogLoading ? Visibility.Visible : Visibility.Collapsed;
        RefreshCatalogIcon.Visibility = _catalogLoading ? Visibility.Collapsed : Visibility.Visible;
        LocationCapabilityText.Text = _catalogLoading ? "Обновляем серверы…"
            : _catalogError ?? (_locations.Count == 0 ? "Серверы ещё не загружены. Нажмите «Обновить»." : "Список обновляется каждые 20 секунд.");
    }

    private void OnServerSearchTextChanged(object sender, TextChangedEventArgs args) => RenderServerCatalog();

    private void OnServerSearchKeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (args.Key is not (global::Windows.System.VirtualKey.Enter or global::Windows.System.VirtualKey.Down)) return;
        var first = _filteredLocations.FirstOrDefault(ServerCatalog.IsAvailable);
        if (first is null) return;
        if (args.Key == global::Windows.System.VirtualKey.Enter) SelectLocationCard(first);
        else
        {
            var rows = (CatalogSource.Source as IReadOnlyList<ServerCountryPresentation>)?.SelectMany(group => group.Rows);
            LocationPicker.SelectedItem = rows?.FirstOrDefault(row => row.Location.Id == first.Id);
            LocationPicker.Focus(FocusState.Keyboard);
            LocationPicker.ScrollIntoView(LocationPicker.SelectedItem);
        }
        args.Handled = true;
    }

    private void OnLocationPickerKeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (args.OriginalSource is Button) return;
        if (args.Key == global::Windows.System.VirtualKey.Enter && sender is ListView { SelectedItem: ServerRowPresentation row })
        {
            SelectLocationCard(row.Location);
            args.Handled = true;
        }
        else if (args.Key == global::Windows.System.VirtualKey.Escape)
        {
            _countryFlyout?.Hide();
            ServerPickerDialog.Hide();
            args.Handled = true;
        }
    }

    private void OnServerFilterChanged(object sender, SelectionChangedEventArgs args)
    {
        if (_synchronizingFilter || ServerSearchBox is null) return;
        if (ServerFilterPicker.SelectedItem is ComboBoxItem { Tag: string filter }) SetCatalogFilter(filter);
    }

    private void SetCatalogFilter(string filter)
    {
        try { _services.Preferences.Update(current => current with { ServerCatalogFilter = filter }); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or CryptographicException)
        {
            ShowNotice("Не удалось сохранить фильтр серверов.", InfoBarSeverity.Warning);
            LogUiFailure(error);
        }
        SynchronizeCatalogFilter();
        RenderServerCatalog();
    }

    private void OnFavoriteLocationClick(object sender, RoutedEventArgs args)
    {
        if (sender is not Button { Tag: VpnLocation location }) return;
        try
        {
            _services.Preferences.Update(current =>
            {
                var favorites = ServerCatalog.NormalizeFavoriteIds(current.FavoriteLocationIds).ToHashSet(StringComparer.OrdinalIgnoreCase);
                if (!favorites.Remove(location.Id)) favorites.Add(location.Id.ToLowerInvariant());
                return current with { FavoriteLocationIds = favorites.Order(StringComparer.Ordinal).ToArray() };
            });
            RenderServerCatalog();
            if (_countryFlyout?.Content is StackPanel panel && panel.Children.LastOrDefault() is ListView list)
            {
                list.ItemsSource = (list.ItemsSource as IEnumerable<ServerRowPresentation>)?
                    .Select(row => CreateServerRow(row.Location)).ToArray();
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or CryptographicException)
        {
            ShowNotice("Не удалось сохранить избранные серверы.", InfoBarSeverity.Warning);
            LogUiFailure(error);
        }
    }

    private async void OnRefreshCatalogClick(object sender, RoutedEventArgs args)
    {
        if (_catalogLoading) return;
        if (IsPreviewMode) LoadPreviewLocations();
        else await LoadLocationsAsync();
    }

    private void StartCatalogTimer()
    {
        if (IsPreviewMode) return;
        if (_catalogTimer is null)
        {
            _catalogTimer = DispatcherQueue.CreateTimer();
            _catalogTimer.Interval = TimeSpan.FromSeconds(20);
            _catalogTimer.IsRepeating = true;
            _catalogTimer.Tick += OnCatalogTimerTick;
        }
        _catalogTimer.Start();
    }

    private async void OnCatalogTimerTick(Microsoft.UI.Dispatching.DispatcherQueueTimer sender, object args)
    {
        if (_serverDialogOpen && _pageLifetime is not null && !_catalogLoading && !_selectionBusy && CoordinatorStateAvailable())
            await LoadLocationsAsync();
    }

    private static void SetCountryArtworkHover(
        DependencyObject? root,
        bool hovered,
        bool motionAllowed)
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
            scale.ScaleX = hovered && motionAllowed ? 1.28 : 1;
            scale.ScaleY = hovered && motionAllowed ? 1.28 : 1;
        }
        artwork.Opacity = hovered
            ? 0.20
            : artwork.DataContext is LocationCardPresentation card
                ? card.CountryOpacity
                : 0.08;
        var surface = FindDescendant<Border>(root, "CountryCardSurface");
        if (surface?.DataContext is LocationCardPresentation presentation)
        {
            surface.BorderBrush = hovered && !presentation.Group.IsSelected
                ? HomeBrush(0x61, 0x22, 0xD3, 0xEE)
                : presentation.CardBorder;
            surface.Background = hovered
                ? HomeBrush(0xC2, 0x07, 0x11, 0x13)
                : presentation.CardBackground;
        }
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
        "tunnel_cleanup_incomplete" => "Отключение VPN ещё не подтверждено. VEX повторит очистку; можно нажать, чтобы повторить сейчас.",
        _ => "Не удалось выполнить операцию VPN.",
    };

    private sealed record ServerCountryPresentation(string Title, IReadOnlyList<ServerRowPresentation> Rows);

    private sealed record ServerRowPresentation(VpnLocation Location, string Title, string LocationId,
        string FlagEmoji, string StatusText, string LatencyText, string FavoriteGlyph,
        string FavoriteHelp, double AvailabilityOpacity, string AccessibleName);

    private sealed record LocationCardPresentation(
        ServerCountryGroup Group,
        double CardWidth,
        string AccessibleName,
        VpnLocation Location,
        string FlagEmoji,
        string? FlagAsset,
        Visibility FlagAssetVisibility,
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
            ServerCountryGroup group,
            double cardWidth)
        {
            var location = group.Representative;
            var selected = group.IsSelected;
            var countryCode = !string.IsNullOrWhiteSpace(
                location.CountryCode)
                ? location.CountryCode
                : location.Id.Split(
                    '-',
                    StringSplitOptions.RemoveEmptyEntries)
                    .FirstOrDefault();
            return new LocationCardPresentation(
                Group: group,
                CardWidth: cardWidth,
                AccessibleName: $"{group.Title}, доступно узлов: {group.AvailableNodeCount}. Выбрать сервер страны.",
                Location: location,
                FlagEmoji: string.IsNullOrWhiteSpace(group.FlagEmoji) ? "◇" : group.FlagEmoji,
                FlagAsset: CountryFlagAsset(countryCode),
                FlagAssetVisibility: CountryFlagAsset(countryCode) is null ? Visibility.Collapsed : Visibility.Visible,
                DisplayName: group.Title,
                AvailabilityText: group.AvailableNodeCount > 0
                    ? $"{group.AvailableNodeCount} узлов · доступно"
                    : "Нет доступных узлов",
                LatencyText: ServerCatalog.IsAvailable(location) && location.LatencyMs is { } latency &&
                    double.IsFinite(latency) && latency >= 0 ? $"{Math.Round(latency):0} мс" : "—",
                CountryGeometry:
                    CountrySilhouetteGeometry.Create(countryCode),
                CardBackground: Brush(
                    selected ? (byte)0xD1 : (byte)0xA3,
                    0x07,
                    0x11,
                    0x13),
                CardBorder: Brush(
                    selected ? (byte)0xD1 : (byte)0x14,
                    selected ? (byte)0x22 : (byte)0xFF,
                    selected ? (byte)0xD3 : (byte)0xFF,
                    selected ? (byte)0xEE : (byte)0xFF),
                CountryFill: Brush(0xFF, 0x22, 0xD3, 0xEE),
                CountryStroke: Brush(0xFF, 0xB9, 0xFB, 0xFF),
                CountryOpacity: selected ? 0.085 : 0.048,
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
