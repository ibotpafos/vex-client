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
    private ActivationSnapshot? _initialActivation;
    private ActivationSnapshot? _startupRedirect;

    public App(AppActivationArguments initialActivation)
        : this(ActivationSnapshot.Capture(initialActivation ?? throw new ArgumentNullException(nameof(initialActivation))))
    {
    }

    internal App(ActivationSnapshot initialActivation)
    {
        ArgumentNullException.ThrowIfNull(initialActivation);
        _initialActivation = initialActivation;
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
#if DEBUG
        if (UiPreviewContext.IsProtectedStateFaultPreview)
            ProtectedStateFaultPreview.RecordStartup(AppServices.Current);
#endif
        // Packaged activation arguments are available only on their first SDK
        // read. Program captured them before selecting the primary instance.
        var initialActivation = _initialActivation;
        _initialActivation = null;
        if (initialActivation is not null)
        {
            _ = HandleActivationAsync(
                initialActivation,
                ProtocolActivationUriParser.Parse(args.Arguments));
        }
        var startupRedirect = _startupRedirect;
        _startupRedirect = null;
        if (startupRedirect is not null) HandleRedirectedActivation(startupRedirect);
    }

    internal void HandleRedirectedActivation(
        ActivationSnapshot args)
    {
        if (_window is null)
        {
            // A redirected callback can reach the dispatcher before OnLaunched
            // has created the window. Keep it until the shell can receive it.
            _startupRedirect = args;
            return;
        }

        if (UiPreviewContext.IsTrayRecoveryCommand(
            args.LaunchArguments))
        {
#if DEBUG
            if (!UiPreviewTrayRequest.TryParse(args.LaunchArguments, out var request)) return;
            var trace = new UiPreviewTrayActivation(request!);
            trace.Record("redirected-request-accepted");
            _ = HandleActivationAsync(args, trayTrace: trace);
#else
            _ = HandleActivationAsync(args);
#endif
            return;
        }

#if DEBUG
        if (UiPreviewContext.IsMinimizeCommand(
            args.LaunchArguments))
        {
            _window.MinimizePreviewWindow();
            return;
        }
#endif

        _window.ShowShellWindow();
        _window.Activate();
        _window.BringToFront();
        _ = HandleActivationAsync(args);
    }

    private async Task HandleActivationAsync(
        ActivationSnapshot args,
        Uri? launchUri = null
#if DEBUG
        , UiPreviewTrayActivation? trayTrace = null
#endif
        )
    {
        AuthActivationTrace.Record(AuthActivationStage.HandlerStarted);
        try
        {
            if (args.CaptureFailed)
            {
                AuthActivationTrace.Record(AuthActivationStage.HandlerFaulted);
                return;
            }
            await HandleActivationCoreAsync(args, launchUri
#if DEBUG
                , trayTrace
#endif
            );
            AuthActivationTrace.Record(AuthActivationStage.HandlerCompleted);
        }
        catch (Exception error) when (error is not OutOfMemoryException and not AccessViolationException)
        {
            // Observe every activation task. Fixed stages carry no callback,
            // account data or exception text; native auth presents its errors.
            AuthActivationTrace.Record(AuthActivationStage.HandlerFaulted);
            AuthActivationTrace.RecordFault(error);
        }
    }

    private async Task HandleActivationCoreAsync(
        ActivationSnapshot args,
        Uri? launchUri = null
#if DEBUG
        , UiPreviewTrayActivation? trayTrace = null
#endif
        )
    {
        var launchArguments = args.LaunchArguments;
        if (UiPreviewContext.IsEnabled)
        {
#if DEBUG
            if (UiPreviewContext.IsTrayRecoveryCommand(launchArguments))
            {
                if (trayTrace is null)
                {
                    if (!UiPreviewTrayRequest.TryParse(launchArguments, out var request)) return;
                    trayTrace = new UiPreviewTrayActivation(request!);
                }
                if (_trayIconHost is null) return;
                var services = AppServices.Current;
                var scenario = trayTrace.Request.Scenario;
                try
                {
                    trayTrace.Record("handler-started");
                    if (scenario == "reset")
                    {
                        trayTrace.Record("reset-session-restoring");
                        await services.StateStore.RestorePreviewSessionAsync();
                        trayTrace.Record("reset-session-restored");
                        trayTrace.Record("reset-ui-requested");
                        await _window!.ShowAuthenticationRecoveryAsync(trayTrace.Record);
                        trayTrace.Record("reset-ui-completed");
                    }
                    else
                    {
                        if (scenario == "locked") await services.StateStore.LockPreviewSessionAsync();
                        else if (UiPreviewContext.IsAuthenticated)
                            throw new InvalidOperationException("Signed-out tray checks require a signed-out preview.");
                        await _trayIconHost.ToggleConnectionAsync();
                    }
                    trayTrace.Record("completion-recording");
                    UiPreviewFixtures.RecordTrayRecovery(trayTrace, services);
                }
                catch (Exception error)
                {
                    trayTrace.RecordFailure(error);
                    throw;
                }
                return;
            }
#endif
            if (UiPreviewContext.IsExitCommand(launchArguments)) ExitApplication();
            // UI-review activations never enter browser authentication.
            return;
        }
        var protocolUri = args.ProtocolUri ?? launchUri;
        if (protocolUri is null)
        {
            AuthActivationTrace.Record(AuthActivationStage.HandlerNoProtocol);
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
#if DEBUG
            if (UiPreviewContext.IsProtectedStateFaultPreview)
                ProtectedStateFaultPreview.RecordCleanup();
#endif
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
