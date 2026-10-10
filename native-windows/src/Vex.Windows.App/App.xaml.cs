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
        if (!UiPreviewContext.IsEnabled)
        {
            AppServices.Current.BackgroundUpdates.Start();
            AppServices.Current.BackgroundVpn.Start();
            AppServices.Current.ProfileWarmup.Start();
        }
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

        if (UiPreviewContext.IsTrayRecoveryCommand(
            (args.Data as ILaunchActivatedEventArgs)?.Arguments))
        {
            _ = HandleActivationAsync(args);
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
        var launchArguments = args.Data is ILaunchActivatedEventArgs launch
            ? launch.Arguments : null;
        if (UiPreviewContext.IsEnabled)
        {
            if (UiPreviewContext.IsExitCommand(launchArguments)) ExitApplication();
#if DEBUG
            else if (UiPreviewContext.IsTrayRecoveryCommand(launchArguments) && _trayIconHost is not null)
            {
                var services = AppServices.Current;
                var scenario = UiPreviewContext.HasCommand(launchArguments, "--ui-smoke-tray-connect-locked")
                    ? "locked" : UiPreviewContext.HasCommand(launchArguments, "--ui-smoke-tray-reset") ? "reset" : "signed-out";
                if (scenario == "reset")
                {
                    await services.StateStore.RestorePreviewSessionAsync();
                    await _window!.ShowAuthenticationRecoveryAsync();
                }
                else
                {
                    if (scenario == "locked") await services.StateStore.LockPreviewSessionAsync();
                    else if (UiPreviewContext.IsAuthenticated)
                        throw new InvalidOperationException("Signed-out tray checks require a signed-out preview.");
                    await _trayIconHost.ToggleConnectionAsync();
                }
                UiPreviewFixtures.RecordTrayRecovery(scenario, services);
            }
#endif
            // UI-review activations never enter browser authentication.
            return;
        }
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
        if (AppServices.Current.Coordinator.CurrentStateAccess !=
            Vex.Windows.Client.Session.ClientStateAccessKind.Available)
        {
            _window?.NavigateToSection(AppSection.Account, forceReload: true);
        }
    }

    private void ExitApplication()
    {
        _trayIconHost?.Dispose();
        _trayIconHost = null;
        AppServices.Current.BackgroundUpdates.Dispose();
        AppServices.Current.BackgroundVpn.Dispose();
        AppServices.Current.ProfileWarmup.Dispose();
        _window?.RequestExit();
    }

    private void OnWindowClosed(object sender, WindowEventArgs args)
    {
        _trayIconHost?.Dispose();
        _trayIconHost = null;
        AppServices.Current.BackgroundUpdates.Dispose();
        AppServices.Current.BackgroundVpn.Dispose();
        AppServices.Current.ProfileWarmup.Dispose();
        if (_window is not null)
        {
            AppServices.Current.ClearMainWindow(_window);
        }
        _window = null;
        if (UiPreviewContext.IsEnabled)
        {
            try
            {
                UiPreviewProtocolRegistration.Unregister();
            }
            catch (Exception error) when (error is InvalidOperationException or
                System.Runtime.InteropServices.COMException or UnauthorizedAccessException or
                System.ComponentModel.Win32Exception or IOException)
            {
                Debug.WriteLine($"Preview protocol cleanup failed: {error.GetType().Name}");
            }
            UiPreviewContext.Cleanup();
        }
    }

    private static void RegisterProtocolActivations()
    {
        if (UiPreviewContext.IsEnabled)
        {
            try { UiPreviewProtocolRegistration.Register(); }
            catch (Exception error)
            {
                Debug.WriteLine($"UI preview protocol registration failed: {error.GetType().Name}");
            }
            return;
        }
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
