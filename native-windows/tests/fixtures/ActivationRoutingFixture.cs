global using System;
global using System.Collections.Generic;
global using System.IO;
global using System.Linq;
global using System.Reflection;
global using System.Threading;
global using System.Threading.Tasks;

namespace Vex.Windows.App
{
    public static class ActivationRoutingFixture
    {
        internal static readonly List<Uri> Received = new();
        internal static Action? BeforeLaunch;
        internal static bool WindowReady;
        internal static int WindowCount;
        internal static bool Preview;

        public static int Main()
        {
            try { Console.WriteLine("PASS activation routing: " + Run()); return 0; }
            catch { Console.Error.WriteLine("Actual-source activation routing failed."); return 1; }
        }
        public static int Run()
        {
            var failures = new List<string>();
            var originalContext = SynchronizationContext.Current;
            var cases = new (string Name, Action Test)[]
            {
                ("cold-protocol", () => Cold("vexguard")),
                ("cold-legacy-protocol", () => Cold("vex")),
                ("launch-argument", LaunchArgument),
                ("startup-redirect", StartupRedirect),
                ("warm-redirect", WarmRedirect),
                ("preview-isolation", PreviewIsolation),
            };
            try
            {
                foreach (var item in cases)
                {
                    try { item.Test(); }
                    catch { failures.Add(item.Name); }
                }
                if (failures.Count != 0)
                    throw new InvalidOperationException("Activation scenarios failed: " + string.Join(",", failures));
                return cases.Length;
            }
            finally { SynchronizationContext.SetSynchronizationContext(originalContext); }
        }

        private static Uri Callback(string scheme = "vexguard") =>
            new(scheme + "://auth/callback?code=synthetic-code&state=synthetic-state._~");

        private static void Reset(Microsoft.Windows.AppLifecycle.AppActivationArguments initial)
        {
            Received.Clear(); BeforeLaunch = null; WindowReady = false; WindowCount = 0; Preview = false;
            foreach (var name in new[] { "_instance", "_app", "_dispatcherQueue", "_pendingActivation" })
                typeof(Program).GetField(name, BindingFlags.NonPublic | BindingFlags.Static)!.SetValue(null, null);
            Microsoft.Windows.AppLifecycle.AppInstance.Reset(initial);
        }
        private static void Start() => typeof(Program)
            .GetMethod("Main", BindingFlags.NonPublic | BindingFlags.Static)!
            .Invoke(null, new object[] { Array.Empty<string>() });
        private static Microsoft.Windows.AppLifecycle.AppActivationArguments Protocol(Uri uri) =>
            new(Microsoft.Windows.AppLifecycle.ExtendedActivationKind.Protocol, new ProtocolData(uri));
        private static Microsoft.Windows.AppLifecycle.AppActivationArguments Launch(string value = "") =>
            new(Microsoft.Windows.AppLifecycle.ExtendedActivationKind.Launch, new LaunchData(value));
        private static void Check(bool value) { if (!value) throw new InvalidOperationException("Activation invariant failed."); }

        private static void Cold(string scheme)
        {
            var uri = Callback(scheme); Reset(Protocol(uri)); Start();
            Check(Received.Count == 1 && Received[0] == uri && WindowCount == 1);
            Check(Microsoft.Windows.AppLifecycle.AppInstance.GetCurrent().ReadCount == 1);
        }
        private static void LaunchArgument()
        {
            var uri = Callback(); Reset(Launch(uri.AbsoluteUri)); Start();
            Check(Received.Count == 1 && Received[0] == uri);
            Check(Microsoft.Windows.AppLifecycle.AppInstance.GetCurrent().ReadCount == 1);
        }
        private static void StartupRedirect()
        {
            var uri = Callback(); Reset(Launch());
            BeforeLaunch = () =>
            {
                Microsoft.Windows.AppLifecycle.AppInstance.GetCurrent().Raise(Protocol(uri));
                Check(!WindowReady && Received.Count == 0);
            };
            Start(); Check(Received.Count == 1 && Received[0] == uri && WindowCount == 1);
        }
        private static void WarmRedirect()
        {
            var uri = Callback(); Reset(Launch()); Start();
            var instance = Microsoft.Windows.AppLifecycle.AppInstance.GetCurrent();
            var reads = instance.ReadCount;
            instance.Raise(Protocol(uri));
            Check(Received.Count == 1 && Received[0] == uri && WindowCount == 1 && instance.ReadCount == reads);
        }
        private static void PreviewIsolation()
        {
            Reset(Protocol(Callback())); Preview = true; Start();
            Check(Received.Count == 0 && WindowCount == 1);
        }

        private sealed class ProtocolData(Uri uri) : global::Windows.ApplicationModel.Activation.IProtocolActivatedEventArgs
        { public Uri Uri => uri; }
        private sealed class LaunchData(string arguments) : global::Windows.ApplicationModel.Activation.ILaunchActivatedEventArgs
        { public string Arguments => arguments; }
    }

    public partial class App { private void InitializeComponent() { } }
    public sealed class MainWindow
    {
        public MainWindow() { ActivationRoutingFixture.WindowReady = true; ActivationRoutingFixture.WindowCount++; }
        public event Microsoft.UI.Xaml.WindowClosedEventHandler Closed { add { } remove { } }
        public void ShowShellWindow() { }
        public void Activate() { }
        public void BringToFront() { }
        public void RequestExit() { }
        public void NavigateToSection(Vex.Windows.Core.Navigation.AppSection section, bool forceReload) { }
    }
}

namespace Microsoft.UI.Xaml
{
    public sealed class LaunchActivatedEventArgs { public string Arguments => ""; }
    public sealed class WindowEventArgs : EventArgs { }
    public delegate void WindowClosedEventHandler(object sender, WindowEventArgs args);
    public class Application
    {
        private static Application? _current;
        protected Application() { _current = this; }
        public static void Start(Action<object> initialize)
        {
            initialize(new object());
            Vex.Windows.App.ActivationRoutingFixture.BeforeLaunch?.Invoke();
            _current!.OnLaunched(new LaunchActivatedEventArgs());
        }
        protected virtual void OnLaunched(LaunchActivatedEventArgs args) { }
    }
}
namespace Microsoft.UI.Dispatching
{
    public sealed class DispatcherQueue
    {
        public static DispatcherQueue GetForCurrentThread() => new();
        public bool TryEnqueue(Action callback) { callback(); return true; }
    }
    public sealed class DispatcherQueueSynchronizationContext : SynchronizationContext
    { public DispatcherQueueSynchronizationContext(DispatcherQueue queue) { } }
}
namespace Microsoft.Windows.AppLifecycle
{
    public enum ExtendedActivationKind { Launch, Protocol }
    public sealed class AppActivationArguments(ExtendedActivationKind kind, object data)
    { public ExtendedActivationKind Kind => kind; public object Data => data; }
    public sealed class AppInstance
    {
        private static AppInstance _current = new();
        private AppActivationArguments _initial = new(ExtendedActivationKind.Launch, new EmptyLaunch());
        public int ReadCount { get; private set; }
        public bool IsCurrent => true;
        public event EventHandler<AppActivationArguments>? Activated;
        public static AppInstance GetCurrent() => _current;
        public static AppInstance FindOrRegisterForKey(string key) => _current;
        public static void Reset(AppActivationArguments initial) => _current = new() { _initial = initial };
        // Match the documented packaged one-shot contract; later calls lose
        // the rich activation and fall back to ordinary launch arguments.
        public AppActivationArguments GetActivatedEventArgs() => ++ReadCount == 1
            ? _initial : new(ExtendedActivationKind.Launch, new EmptyLaunch());
        public void Raise(AppActivationArguments args) => Activated?.Invoke(this, args);
        public Task RedirectActivationToAsync(AppActivationArguments args) =>
            throw new InvalidOperationException("Native secondary-process routing is outside this inert fixture.");
        private sealed class EmptyLaunch : global::Windows.ApplicationModel.Activation.ILaunchActivatedEventArgs
        { public string Arguments => ""; }
    }
    public static class ActivationRegistrationManager
    {
        public static void RegisterForProtocolActivation(string scheme, string logo, string name, string executable) =>
            throw new InvalidOperationException("An inert test attempted native protocol registration.");
    }
}
namespace Windows.ApplicationModel.Activation
{
    public interface IProtocolActivatedEventArgs { Uri Uri { get; } }
    public interface ILaunchActivatedEventArgs { string Arguments { get; } }
}
namespace Windows.ApplicationModel
{
    public sealed class Package
    { public static Package Current => new(); public PackageId Id => new(); }
    public sealed class PackageId { public string Name => "Fixture.Package"; }
}
namespace WinRT
{
    public static class ComWrappersSupport { public static void InitializeComWrappers() { } }
}
namespace WinRT.Interop
{
    public static class WindowNative { public static nint GetWindowHandle(object window) => 1; }
}
namespace Vex.Windows.Core.Navigation { public enum AppSection { Account } }
namespace Vex.Windows.Client.Session { public enum ClientStateAccessKind { Available } }
namespace Vex.Windows.App.Services
{
    public static class UiPreviewContext
    {
        public static bool IsEnabled => Vex.Windows.App.ActivationRoutingFixture.Preview;
        public static bool IsPreviewRequest => IsEnabled;
        public static bool IsSupported => true;
        public static bool IsCommandOnly => false;
        public static string InstanceKey => IsEnabled ? "preview" : "main";
        public static void Initialize(string[] arguments, Uri? protocolUri) { }
        public static Uri? ParseActivationUri(string? arguments) => null;
        public static bool IsTrayRecoveryCommand(string? arguments) => false;
        public static bool IsExitCommand(string? arguments) => false;
        public static void Cleanup() { }
    }
    public static class UiPreviewProtocolRegistration { public static void Register() { } public static void Unregister() { } }
    public sealed class AppServices
    {
        public static AppServices Current { get; } = new();
        public InertLifetime BackgroundUpdates { get; } = new();
        public InertLifetime BackgroundVpn { get; } = new();
        public InertLifetime ProfileWarmup { get; } = new();
        public InertAuth Auth { get; } = new();
        public InertCoordinator Coordinator { get; } = new();
        public void RegisterMainWindow(Vex.Windows.App.MainWindow window) { }
        public void ClearMainWindow(Vex.Windows.App.MainWindow window) { }
    }
    public sealed class InertLifetime : IDisposable { public void Start() { } public void Dispose() { } }
    public sealed class InertAuth
    {
        public Task HandleProtocolActivationAsync(Uri uri, CancellationToken token)
        {
            if (!Vex.Windows.App.ActivationRoutingFixture.WindowReady) throw new InvalidOperationException("Window not ready.");
            Vex.Windows.App.ActivationRoutingFixture.Received.Add(uri); return Task.CompletedTask;
        }
    }
    public sealed class InertCoordinator
    { public Vex.Windows.Client.Session.ClientStateAccessKind CurrentStateAccess => Vex.Windows.Client.Session.ClientStateAccessKind.Available; }
    public sealed class TrayIconHost : IDisposable
    {
        public TrayIconHost(Vex.Windows.App.MainWindow window, AppServices services, Action exit) { }
        public void Dispose() { }
    }
}
