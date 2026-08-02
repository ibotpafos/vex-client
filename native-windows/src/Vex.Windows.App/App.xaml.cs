using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using System.Diagnostics;
using Windows.ApplicationModel.Activation;
using Vex.Windows.App.Services;
using Vex.Windows.Client.Auth;
using Vex.Windows.Core.Navigation;

namespace Vex.Windows.App;

public partial class App : Application
{
    private MainWindow? _window;
    private TrayIconHost? _trayIconHost;

    public App()
    {
        InitializeComponent();
    }

    public nint ShellWindowHandle =>
        _window is null
            ? 0
            : WinRT.Interop.WindowNative.GetWindowHandle(_window);

    protected override void OnLaunched(
        Microsoft.UI.Xaml.LaunchActivatedEventArgs args)
    {
        RegisterProtocolActivations();
        var current = AppInstance.GetCurrent();
        _window ??= new MainWindow();
        _window.Closed += OnWindowClosed;
        AppServices.Current.RegisterMainWindow(_window);
        _trayIconHost ??= new TrayIconHost(
            _window,
            AppServices.Current,
            ExitApplication);
        AppServices.Current.BackgroundUpdates.Start();
        _window.ShowShellWindow();
        _window.Activate();
        _ = HandleActivationAsync(
            current.GetActivatedEventArgs(),
            ProtocolActivationUriParser.Parse(args.Arguments));
    }

    internal void HandleRedirectedActivation(
        AppActivationArguments args)
    {
        if (_window is null)
        {
            return;
        }

        _window.ShowShellWindow();
        _window.Activate();
        _window.BringToFront();
        _ = HandleActivationAsync(args);
    }

    private async Task HandleActivationAsync(
        AppActivationArguments args,
        Uri? launchUri = null)
    {
        var protocolUri = args.Kind switch
        {
            ExtendedActivationKind.Protocol
                when args.Data is IProtocolActivatedEventArgs protocolArgs =>
                    protocolArgs.Uri,
            ExtendedActivationKind.Launch
                when args.Data is ILaunchActivatedEventArgs launchArgs =>
                    ProtocolActivationUriParser.Parse(launchArgs.Arguments),
            _ => launchUri,
        };
        if (protocolUri is null)
        {
            return;
        }

        await AppServices.Current.Auth.HandleProtocolActivationAsync(
            protocolUri,
            CancellationToken.None);
        _window?.NavigateToSection(
            AppServices.Current.Coordinator.CurrentState is null
                ? AppSection.Account
                : AppSection.Home,
            forceReload: true);
    }

    private void ExitApplication()
    {
        _trayIconHost?.Dispose();
        _trayIconHost = null;
        AppServices.Current.BackgroundUpdates.Dispose();
        _window?.RequestExit();
    }

    private void OnWindowClosed(object sender, WindowEventArgs args)
    {
        _trayIconHost?.Dispose();
        _trayIconHost = null;
        AppServices.Current.BackgroundUpdates.Dispose();
        if (_window is not null)
        {
            AppServices.Current.ClearMainWindow(_window);
        }
        _window = null;
    }

    private static void RegisterProtocolActivations()
    {
        if (HasPackageIdentity())
        {
            // Packaged builds own both URI schemes through AppxManifest.xml.
            return;
        }

        var exePath = Environment.ProcessPath;
        if (string.IsNullOrWhiteSpace(exePath))
        {
            return;
        }

        var logo = exePath + ",0";
        try
        {
            ActivationRegistrationManager.RegisterForProtocolActivation(
                "vexguard",
                logo,
                "VEX VPN",
                exePath);
            ActivationRegistrationManager.RegisterForProtocolActivation(
                "vex",
                logo,
                "VEX VPN",
                exePath);
        }
        catch (Exception error)
        {
            Debug.WriteLine(
                $"Unpackaged VEX protocol registration was not available: {error.GetType().Name}");
        }
    }

    private static bool HasPackageIdentity()
    {
        try
        {
            _ = global::Windows.ApplicationModel.Package.Current.Id.Name;
            return true;
        }
        catch (InvalidOperationException)
        {
            return false;
        }
    }
}
