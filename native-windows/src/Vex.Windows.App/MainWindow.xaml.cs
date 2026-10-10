using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Composition;
using System.Numerics;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Vex.Windows.App.Services;
using Vex.Windows.App.Views;
using Vex.Windows.Core.Navigation;
using WinRT.Interop;

namespace Vex.Windows.App;

public sealed partial class MainWindow : Window
{
    private const int DefaultWidth = 920;
    private const int DefaultHeight = 620;
    private bool _allowClose;
    private bool _closed;
    private bool _hasAuthenticatedSession;
    private long _authGeneration;
    private AppSection _currentSection = AppSection.Home;
    private readonly CancellationTokenSource _shellLifetime = new();
    private ContainerVisual? _ambientVisual;
    private SpriteVisual? _accentVisual;
    private SpriteVisual? _lightVisual;
    private CompositionColorGradientStop? _accentStop;
    private CompositionColorGradientStop? _accentFadeStop;

    public MainWindow()
    {
        InitializeComponent();
        Title = "VEX";
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(FocusPulseHeader);
        ConfigureTitleBar();
        ResizeForCurrentDpi();
        AppWindow.Closing += OnAppWindowClosing;
        ConfigureNavigation();
        _hasAuthenticatedSession = AppServices.Current.Coordinator.CurrentState is not null;
        NavigateToSection(AppSection.Home);
        AppServices.Current.Auth.StateChanged += OnAuthStateChanged;
        AppServices.Current.UpdateService.Changed += OnUpdateSnapshotChanged;
        Closed += OnWindowClosed;
        RenderShellState();
        IsShellWindowVisible = true;
    }

    public bool IsShellWindowVisible { get; private set; }

    public event EventHandler? ShellWindowVisibilityChanged;

    public void NavigateToSection(
        AppSection section,
        bool forceReload = false)
    {
        if (_closed) return;
        if (!_hasAuthenticatedSession && section != AppSection.Settings)
        {
            section = AppSection.Home;
        }
        var page = ResolvePage(section);
        if (forceReload ||
            ContentFrame.CurrentSourcePageType != page)
        {
            ContentFrame.Navigate(page);
        }

        HomeNavigationButton.IsChecked = section == AppSection.Home;
        AccountNavigationButton.IsChecked = section == AppSection.Account;
        SupportNavigationButton.IsChecked = section == AppSection.Support;
        _currentSection = section;
        RenderShellState();
    }

    public void ShowShellWindow()
    {
        var handle = WindowNative.GetWindowHandle(this);
        NativeMethods.ShowWindow(handle, NativeMethods.ShowWindowRestore);
        IsShellWindowVisible = true;
        ShellWindowVisibilityChanged?.Invoke(this, EventArgs.Empty);
    }

    public void HideShellWindow()
    {
        var handle = WindowNative.GetWindowHandle(this);
        NativeMethods.ShowWindow(handle, NativeMethods.ShowWindowHide);
        IsShellWindowVisible = false;
        ShellWindowVisibilityChanged?.Invoke(this, EventArgs.Empty);
    }

    public void RequestExit()
    {
        _allowClose = true;
        Close();
    }

    public void BringToFront()
    {
        var handle = WindowNative.GetWindowHandle(this);
        NativeMethods.SetForegroundWindow(handle);
    }

    private void OnNavigationButtonClick(
        object sender,
        RoutedEventArgs args)
    {
        if (sender is not ToggleButton { Tag: AppSection section })
        {
            return;
        }

        NavigateToSection(section);
    }

    private void ConfigureNavigation()
    {
        HomeNavigationButton.Tag = AppSection.Home;
        AccountNavigationButton.Tag = AppSection.Account;
        SupportNavigationButton.Tag = AppSection.Support;
        SettingsNavigationButton.Tag = AppSection.Settings;
    }

    private async void OnWebsiteClick(object sender, RoutedEventArgs args)
    {
        if (UiPreviewContext.IsEnabled) return;
        try
        {
            await global::Windows.System.Launcher.LaunchUriAsync(new Uri("https://vexguard.app"));
        }
        catch (Exception error) when (error is COMException or InvalidOperationException)
        {
            Debug.WriteLine($"Website launch unavailable: {error.GetType().Name}");
        }
    }

    private async void OnShellRootLoaded(
        object sender,
        RoutedEventArgs args)
    {
        ShellVersionText.Text = DisplayVersion();
        RenderUpdateState();
        InitializeBackdrop();
        await RefreshServerHealthAsync();
    }

    private static string DisplayVersion()
    {
        var fileVersion = FileVersionInfo.GetVersionInfo(
            typeof(App).Assembly.Location).FileVersion;
        if (Version.TryParse(fileVersion, out var version))
        {
            return $"VEX {version.Major}.{version.Minor}.{version.Build}" +
                " · build " +
                version.Revision;
        }

        return $"VEX {AppServices.Current.UpdateService.CurrentSnapshot.CurrentVersion}";
    }

    private void OnShellRootSizeChanged(
        object sender,
        SizeChangedEventArgs args)
    {
        var compact = args.NewSize.Width < 680;
        var handle = WindowNative.GetWindowHandle(this);
        var dpi = NativeMethods.GetDpiForWindow(handle);
        var scale = dpi > 0 ? dpi / 96d : 1d;
        var captionInset = AppWindow.TitleBar.RightInset / scale;
        FocusPulseHeader.Margin = new Thickness(compact ? 16 : 22, 0,
            Math.Max(16, captionInset + 16), 0);
        ShellVersionText.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
        ShellWebsiteLink.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
        ResizeBackdrop();
    }

    private void ResizeForCurrentDpi()
    {
        var windowHandle = WindowNative.GetWindowHandle(this);
        var dpi = NativeMethods.GetDpiForWindow(windowHandle);
        var scale = dpi > 0 ? dpi / 96d : 1d;
        var displayArea = DisplayArea.GetFromWindowId(
            AppWindow.Id,
            DisplayAreaFallback.Primary);
        var workArea = displayArea.WorkArea;
        var maximumWidth = Math.Max(1, workArea.Width - 32);
        var maximumHeight = Math.Max(1, workArea.Height - 32);
        var width = Math.Min(
            checked((int)Math.Round(DefaultWidth * scale)),
            maximumWidth);
        var height = Math.Min(
            checked((int)Math.Round(DefaultHeight * scale)),
            maximumHeight);
        var x = workArea.X + Math.Max(0, (workArea.Width - width) / 2);
        var y = workArea.Y + Math.Max(0, (workArea.Height - height) / 2);
        AppWindow.MoveAndResize(new global::Windows.Graphics.RectInt32(
            x,
            y,
            width,
            height));
    }

    private void ConfigureTitleBar()
    {
        var iconPath = Path.Combine(
            AppContext.BaseDirectory,
            "Assets",
            "icon.ico");
        if (File.Exists(iconPath))
        {
            AppWindow.SetIcon(iconPath);
        }

        if (!AppWindowTitleBar.IsCustomizationSupported())
        {
            return;
        }

        var titleBar = AppWindow.TitleBar;
        titleBar.BackgroundColor = global::Windows.UI.Color.FromArgb(
            0xFF, 0x07, 0x11, 0x13);
        titleBar.ForegroundColor = global::Windows.UI.Color.FromArgb(
            0xFF, 0xFF, 0xFF, 0xFF);
        titleBar.InactiveBackgroundColor = global::Windows.UI.Color.FromArgb(
            0xFF, 0x07, 0x11, 0x13);
        titleBar.InactiveForegroundColor = global::Windows.UI.Color.FromArgb(
            0xFF, 0xA7, 0xB9, 0xBD);
        titleBar.ButtonBackgroundColor = global::Windows.UI.Color.FromArgb(
            0x00, 0x00, 0x00, 0x00);
        titleBar.ButtonForegroundColor = global::Windows.UI.Color.FromArgb(
            0xFF, 0xFF, 0xFF, 0xFF);
        titleBar.ButtonHoverBackgroundColor = global::Windows.UI.Color.FromArgb(
            0x24, 0xFF, 0xFF, 0xFF);
        titleBar.ButtonHoverForegroundColor = global::Windows.UI.Color.FromArgb(
            0xFF, 0xFF, 0xFF, 0xFF);
        titleBar.ButtonPressedBackgroundColor = global::Windows.UI.Color.FromArgb(
            0x18, 0xFF, 0xFF, 0xFF);
        titleBar.ButtonPressedForegroundColor = global::Windows.UI.Color.FromArgb(
            0xFF, 0xFF, 0xFF, 0xFF);
    }

    private void OnAppWindowClosing(
        AppWindow sender,
        AppWindowClosingEventArgs args)
    {
        if (_allowClose)
        {
            return;
        }

        args.Cancel = true;
        HideShellWindow();
    }

    private void OnUpdateSnapshotChanged(
        object? sender,
        EventArgs args) =>
        DispatcherQueue.TryEnqueue(RenderUpdateState);

    private void OnAuthStateChanged(object? sender, EventArgs args) =>
        DispatcherQueue.TryEnqueue(() =>
        {
            if (_closed) return;
            _authGeneration++;
            var authenticated = AppServices.Current.Coordinator.CurrentState is not null;
            if (authenticated == _hasAuthenticatedSession)
            {
                return;
            }
            _hasAuthenticatedSession = authenticated;
            if (!authenticated)
            {
                NavigateToSection(AppSection.Home);
            }
            else if (_currentSection is AppSection.Home or AppSection.Account)
            {
                NavigateToSection(AppSection.Home);
            }
            RenderShellState();
            _ = RefreshServerHealthAsync();
        });

    private void OnWindowClosed(object sender, WindowEventArgs args)
    {
        _closed = true;
        AppServices.Current.Auth.StateChanged -= OnAuthStateChanged;
        AppServices.Current.UpdateService.Changed -= OnUpdateSnapshotChanged;
        AppWindow.Closing -= OnAppWindowClosing;
        Closed -= OnWindowClosed;
        _shellLifetime.Cancel();
        _shellLifetime.Dispose();
        _ambientVisual?.Dispose();
        _ambientVisual = null;
    }

    private void RenderShellState()
    {
        var pageTitle = _currentSection switch
        {
            AppSection.Account when _hasAuthenticatedSession => "Аккаунт",
            AppSection.Support => "Поддержка",
            AppSection.Settings => "Настройки",
            _ => string.Empty,
        };
        var showTitle = !string.IsNullOrEmpty(pageTitle);
        PageTitleText.Text = pageTitle;
        PageTitleText.Visibility =
            showTitle ? Visibility.Visible : Visibility.Collapsed;

        HomeNavigationButton.IsChecked =
            _currentSection == AppSection.Home;
        SupportNavigationButton.IsChecked =
            _currentSection == AppSection.Support;
        AccountNavigationButton.IsChecked =
            _currentSection == AppSection.Account;
        SettingsNavigationButton.IsChecked =
            _currentSection == AppSection.Settings;
        AccountNavigationButton.Visibility = _hasAuthenticatedSession ? Visibility.Visible : Visibility.Collapsed;
        SupportNavigationButton.Visibility = _hasAuthenticatedSession ? Visibility.Visible : Visibility.Collapsed;
        RenderBackdrop();
        RenderUpdateState();
    }

    private void RenderUpdateState()
    {
        if (_closed) return;
        var snapshot = AppServices.Current.UpdateService.CurrentSnapshot;
        UpdateBadgeDot.Visibility = snapshot.UpdateAvailable
            ? Visibility.Visible
            : Visibility.Collapsed;
        var releaseVersion = snapshot.Release?.Version;
        var updateLabel = string.IsNullOrWhiteSpace(releaseVersion)
            ? "Доступно обновление VEX"
            : $"Доступно обновление VEX {releaseVersion}";
        AutomationProperties.SetName(
            SettingsNavigationButton,
            snapshot.UpdateAvailable
                ? $"Настройки. {updateLabel}"
                : "Настройки");
        ToolTipService.SetToolTip(
            SettingsNavigationButton,
            snapshot.UpdateAvailable
                ? updateLabel
                : "Настройки");
    }

    private async Task RefreshServerHealthAsync()
    {
        if (_closed) return;
        if (!_hasAuthenticatedSession)
        {
            ServerHealthDot.Fill = (SolidColorBrush)Application.Current.Resources["VexMutedBrush"];
            ToolTipService.SetToolTip(ServerHealthDot, "Статус серверов пока неизвестен");
            return;
        }
        var generation = _authGeneration;
        try
        {
            var locations =
                await AppServices.Current.ProductParity.GetLocationsAsync(
                    AppServices.Current.Coordinator,
                    _shellLifetime.Token);
            if (_shellLifetime.IsCancellationRequested || generation != _authGeneration || !_hasAuthenticatedSession) return;
            var available = locations.Any(location =>
                location.HealthyNodes > 0 &&
                !string.Equals(
                    location.Status,
                    "offline",
                    StringComparison.OrdinalIgnoreCase));
            ServerHealthDot.Fill = new SolidColorBrush(
                available
                    ? global::Windows.UI.Color.FromArgb(
                        0xFF, 0x2E, 0xC7, 0x59)
                    : global::Windows.UI.Color.FromArgb(
                        0xFF, 0xFF, 0xBF, 0x29));
            ToolTipService.SetToolTip(
                ServerHealthDot,
                available
                    ? "Серверы VEX доступны"
                    : "Часть серверов недоступна");
        }
        catch
        {
            if (_shellLifetime.IsCancellationRequested || generation != _authGeneration || !_hasAuthenticatedSession) return;
            ServerHealthDot.Fill = new SolidColorBrush(
                global::Windows.UI.Color.FromArgb(
                    0xFF, 0x8F, 0xBE, 0xC6));
            ToolTipService.SetToolTip(
                ServerHealthDot,
                "Статус серверов пока неизвестен");
        }
    }

    private Type ResolvePage(AppSection section) =>
        section switch
        {
            AppSection.Home when !_hasAuthenticatedSession => typeof(AccountPage),
            AppSection.Home => typeof(HomePage),
            AppSection.Account => typeof(AccountPage),
            AppSection.Support => typeof(SupportPage),
            AppSection.Settings => typeof(SettingsPage),
            _ => typeof(HomePage),
        };

    private void InitializeBackdrop()
    {
        if (_ambientVisual is not null) return;
        var compositor = ElementCompositionPreview.GetElementVisual(AmbientBackdrop).Compositor;
        _ambientVisual = compositor.CreateContainerVisual();
        var accent = compositor.CreateRadialGradientBrush();
        accent.EllipseCenter = new Vector2(0.78f, 0.18f);
        accent.EllipseRadius = new Vector2(0.72f, 1.05f);
        _accentStop = compositor.CreateColorGradientStop(0, global::Windows.UI.Color.FromArgb(38, 34, 211, 238));
        _accentFadeStop = compositor.CreateColorGradientStop(0.35f, global::Windows.UI.Color.FromArgb(9, 34, 211, 238));
        accent.ColorStops.Add(_accentStop);
        accent.ColorStops.Add(_accentFadeStop);
        accent.ColorStops.Add(compositor.CreateColorGradientStop(1, global::Windows.UI.Color.FromArgb(0, 34, 211, 238)));
        _accentVisual = compositor.CreateSpriteVisual();
        _accentVisual.Brush = accent;
        _ambientVisual.Children.InsertAtBottom(_accentVisual);

        var light = compositor.CreateRadialGradientBrush();
        light.EllipseCenter = new Vector2(0.16f, 0.84f);
        light.EllipseRadius = new Vector2(0.54f, 0.85f);
        light.ColorStops.Add(compositor.CreateColorGradientStop(0, global::Windows.UI.Color.FromArgb(19, 185, 251, 255)));
        light.ColorStops.Add(compositor.CreateColorGradientStop(1, global::Windows.UI.Color.FromArgb(0, 185, 251, 255)));
        _lightVisual = compositor.CreateSpriteVisual();
        _lightVisual.Brush = light;
        _ambientVisual.Children.InsertAtTop(_lightVisual);
        ElementCompositionPreview.SetElementChildVisual(AmbientBackdrop, _ambientVisual);
        ResizeBackdrop();
        RenderBackdrop();
    }

    private void ResizeBackdrop()
    {
        if (_ambientVisual is null) return;
        var size = new Vector2((float)ShellRoot.ActualWidth, (float)ShellRoot.ActualHeight);
        _ambientVisual.Size = size;
        if (_accentVisual is not null) _accentVisual.Size = size;
        if (_lightVisual is not null) _lightVisual.Size = size;
    }

    private void RenderBackdrop()
    {
        if (_accentStop is null || _accentFadeStop is null) return;
        var color = _currentSection switch
        {
            AppSection.Account or AppSection.Support => global::Windows.UI.Color.FromArgb(38, 107, 184, 255),
            AppSection.Settings => global::Windows.UI.Color.FromArgb(38, 140, 158, 255),
            _ => global::Windows.UI.Color.FromArgb(38, 34, 211, 238),
        };
        _accentStop.Color = color;
        color.A = 9;
        _accentFadeStop.Color = color;
    }

    private static partial class NativeMethods
    {
        public const int ShowWindowHide = 0;
        public const int ShowWindowRestore = 9;

        [LibraryImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static partial bool ShowWindow(
            nint windowHandle,
            int command);

        [LibraryImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static partial bool SetForegroundWindow(
            nint windowHandle);

        [LibraryImport("user32.dll")]
        public static partial uint GetDpiForWindow(nint windowHandle);
    }
}
