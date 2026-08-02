using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
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
    private AppSection _currentSection = AppSection.Home;

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
        ContentFrame.Navigate(typeof(HomePage));
        AppServices.Current.UpdateService.Changed += OnUpdateSnapshotChanged;
        RenderShellState();
        IsShellWindowVisible = true;
    }

    public bool IsShellWindowVisible { get; private set; }

    public event EventHandler? ShellWindowVisibilityChanged;

    public void NavigateToSection(
        AppSection section,
        bool forceReload = false)
    {
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

    private async void OnShellRootLoaded(
        object sender,
        RoutedEventArgs args)
    {
        ShellVersionText.Text = DisplayVersion();
        RenderUpdateState();
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
        FocusPulseHeader.Margin = compact
            ? new Thickness(14, 8, 14, 0)
            : new Thickness(24, 10, 24, 0);
        HeaderBrandText.Visibility = args.NewSize.Width < 520
            ? Visibility.Collapsed
            : Visibility.Visible;
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
            "Vex.ico");
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

    private void RenderShellState()
    {
        var pageTitle = _currentSection switch
        {
            AppSection.Account => "Аккаунт",
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
        RenderUpdateState();
    }

    private void RenderUpdateState()
    {
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
        try
        {
            var locations =
                await AppServices.Current.ProductParity.GetLocationsAsync(
                    AppServices.Current.Coordinator,
                    CancellationToken.None);
            var available = locations.Any(location =>
                location.HealthyNodes > 0 &&
                !string.Equals(
                    location.Status,
                    "offline",
                    StringComparison.OrdinalIgnoreCase));
            ServerHealthDot.Fill = new SolidColorBrush(
                available
                    ? global::Windows.UI.Color.FromArgb(
                        0xFF, 0x7C, 0xE7, 0xDD)
                    : global::Windows.UI.Color.FromArgb(
                        0xFF, 0xF5, 0x9E, 0x0B));
            ToolTipService.SetToolTip(
                ServerHealthDot,
                available
                    ? "Серверы VEX доступны"
                    : "Часть серверов недоступна");
        }
        catch
        {
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
            AppSection.Home => typeof(HomePage),
            AppSection.Account => typeof(AccountPage),
            AppSection.Support => typeof(SupportPage),
            AppSection.Settings => typeof(SettingsPage),
            _ => typeof(HomePage),
        };

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
