using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using System.Runtime.InteropServices;
using Vex.Windows.App.Services;
using Vex.Windows.Client.Auth;
using Windows.ApplicationModel.Activation;

namespace Vex.Windows.App;

internal static class Program
{
    private static readonly object ActivationSync = new();
    private static AppInstance? _instance;
    private static App? _app;
    private static DispatcherQueue? _dispatcherQueue;
    private static AppActivationArguments? _pendingActivation;

    [STAThread]
    private static int Main(string[] args)
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();

        var current = AppInstance.GetCurrent();
        var activationArgs = current.GetActivatedEventArgs();
        var protocolUri = activationArgs.Kind switch
        {
            ExtendedActivationKind.Protocol when activationArgs.Data is IProtocolActivatedEventArgs protocol => protocol.Uri,
            ExtendedActivationKind.Launch when activationArgs.Data is ILaunchActivatedEventArgs launch =>
                ProtocolActivationUriParser.Parse(launch.Arguments) ?? UiPreviewContext.ParseActivationUri(launch.Arguments),
            _ => ProtocolActivationUriParser.Parse(string.Join(" ", args)) ?? UiPreviewContext.ParseActivationUri(string.Join(" ", args)),
        };
        UiPreviewContext.Initialize(args, protocolUri);
        if (UiPreviewContext.IsPreviewRequest && !UiPreviewContext.IsSupported) return 0;
        _instance = AppInstance.FindOrRegisterForKey(UiPreviewContext.InstanceKey);
        if (!_instance.IsCurrent)
        {
            RedirectActivationTo(activationArgs, _instance);
            return 0;
        }
        // Control-only preview activations cannot create a preview or launch
        // the normal account/VPN application when no preview is running.
        if (UiPreviewContext.IsCommandOnly) return 0;

        _instance.Activated += OnActivated;
        Application.Start(_ =>
        {
            var dispatcherQueue = DispatcherQueue.GetForCurrentThread();
            SynchronizationContext.SetSynchronizationContext(
                new DispatcherQueueSynchronizationContext(dispatcherQueue));
            var app = new App();
            AppActivationArguments? pendingActivation;
            lock (ActivationSync)
            {
                _app = app;
                _dispatcherQueue = dispatcherQueue;
                pendingActivation = _pendingActivation;
                _pendingActivation = null;
            }

            if (pendingActivation is not null)
            {
                dispatcherQueue.TryEnqueue(
                    () => app.HandleRedirectedActivation(pendingActivation));
            }
        });
        return 0;
    }

    private static void OnActivated(
        object? sender,
        AppActivationArguments args)
    {
        App? app;
        DispatcherQueue? dispatcherQueue;
        lock (ActivationSync)
        {
            app = _app;
            dispatcherQueue = _dispatcherQueue;
            if (app is null || dispatcherQueue is null)
            {
                _pendingActivation = args;
                return;
            }
        }

        dispatcherQueue.TryEnqueue(
            () => app.HandleRedirectedActivation(args));
    }

    private static void RedirectActivationTo(
        AppActivationArguments args,
        AppInstance instance)
    {
        using var completed = new ManualResetEvent(initialState: false);
        var redirect = Task.Run(async () =>
        {
            try
            {
                await instance.RedirectActivationToAsync(args);
            }
            finally
            {
                completed.Set();
            }
        });
        var handles = new[]
        {
            completed.SafeWaitHandle.DangerousGetHandle(),
        };
        var waitResult = CoWaitForMultipleObjects(
            flags: 0,
            milliseconds: uint.MaxValue,
            handleCount: 1,
            handles,
            out _);
        if (waitResult != 0)
        {
            throw new InvalidOperationException(
                $"Activation redirection wait failed: 0x{waitResult:X8}");
        }

        redirect.GetAwaiter().GetResult();
    }

    [DllImport("ole32.dll")]
    private static extern uint CoWaitForMultipleObjects(
        uint flags,
        uint milliseconds,
        ulong handleCount,
        nint[] handles,
        out uint index);
}
