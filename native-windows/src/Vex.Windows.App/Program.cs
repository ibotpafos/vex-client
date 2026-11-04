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
    private static ActivationSnapshot? _pendingActivation;

    [STAThread]
    private static int Main(string[] args)
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();
        AuthActivationTrace.Record(AuthActivationStage.ProcessStarted);

        var current = AppInstance.GetCurrent();
        var activationArgs = current.GetActivatedEventArgs();
        var activation = ActivationSnapshot.Capture(activationArgs);
        var protocolUri = activation.CaptureFailed ? null : activation.ProtocolUri
            ?? UiPreviewContext.ParseActivationUri(activation.LaunchArguments)
            ?? ProtocolActivationUriParser.Parse(string.Join(" ", args))
            ?? UiPreviewContext.ParseActivationUri(string.Join(" ", args));
        UiPreviewContext.Initialize(args, protocolUri);
        if (UiPreviewContext.IsPreviewRequest && !UiPreviewContext.IsSupported) return 0;
        _instance = AppInstance.FindOrRegisterForKey(UiPreviewContext.InstanceKey);
        if (!_instance.IsCurrent)
        {
            try { RedirectActivationTo(activationArgs, _instance); return 0; }
            catch (Exception error) when (error is not OutOfMemoryException and not AccessViolationException)
            {
                AuthActivationTrace.Record(AuthActivationStage.RedirectFailed);
                return 1;
            }
        }
        AuthActivationTrace.Record(AuthActivationStage.PrimarySelected);
        // Control-only preview activations cannot create a preview or launch
        // the normal account/VPN application when no preview is running.
        if (UiPreviewContext.IsCommandOnly) return 0;

        _instance.Activated += OnActivated;
        Application.Start(_ =>
        {
            var dispatcherQueue = DispatcherQueue.GetForCurrentThread();
            SynchronizationContext.SetSynchronizationContext(
                new DispatcherQueueSynchronizationContext(dispatcherQueue));
            var app = new App(activation);
            ActivationSnapshot? pendingActivation;
            lock (ActivationSync)
            {
                _app = app;
                _dispatcherQueue = dispatcherQueue;
                pendingActivation = _pendingActivation;
                _pendingActivation = null;
            }

            if (pendingActivation is not null)
            {
                EnqueueActivation(dispatcherQueue, app, pendingActivation);
            }
        });
        return 0;
    }

    private static void OnActivated(
        object? sender,
        AppActivationArguments args)
    {
        AuthActivationTrace.Record(AuthActivationStage.RedirectReceived);
        // Read WinRT arguments on the event's receiving thread, before either
        // startup retention or the UI queue can outlive their native context.
        var activation = ActivationSnapshot.Capture(args);
        App? app;
        DispatcherQueue? dispatcherQueue;
        lock (ActivationSync)
        {
            app = _app;
            dispatcherQueue = _dispatcherQueue;
            if (app is null || dispatcherQueue is null)
            {
                _pendingActivation = activation;
                AuthActivationTrace.Record(AuthActivationStage.StartupQueued);
                return;
            }
        }

        EnqueueActivation(dispatcherQueue, app, activation);
    }

    private static void EnqueueActivation(DispatcherQueue dispatcherQueue, App app, ActivationSnapshot args)
    {
        var accepted = dispatcherQueue.TryEnqueue(() => app.HandleRedirectedActivation(args));
        AuthActivationTrace.Record(accepted ? AuthActivationStage.DispatcherAccepted : AuthActivationStage.DispatcherRejected);
    }

    private static void RedirectActivationTo(
        AppActivationArguments args,
        AppInstance instance)
    {
        AuthActivationTrace.Record(AuthActivationStage.RedirectStarted);
        var completed = new ManualResetEvent(initialState: false);
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
            milliseconds: 30_000,
            handleCount: 1,
            handles,
            out _);
        if (waitResult != 0)
        {
            // A bounded STA wait must not dispose the event while the native
            // redirect still owns it. Observe its eventual fault and release
            // the handle after completion, without blocking the primary UI.
            _ = redirect.ContinueWith(task =>
            {
                _ = task.Exception;
                completed.Dispose();
            }, CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
            throw new InvalidOperationException(
                $"Activation redirection wait failed: 0x{waitResult:X8}");
        }

        try { redirect.GetAwaiter().GetResult(); }
        finally { completed.Dispose(); }
        AuthActivationTrace.Record(AuthActivationStage.RedirectCompleted);
    }

    [DllImport("ole32.dll")]
    private static extern uint CoWaitForMultipleObjects(
        uint flags,
        uint milliseconds,
        uint handleCount,
        nint[] handles,
        out uint index);
}
