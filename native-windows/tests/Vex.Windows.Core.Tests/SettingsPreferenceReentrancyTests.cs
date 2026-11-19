using System.Reflection;
using System.Runtime.Loader;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;
using Vex.Windows.App.Services;
using Vex.Windows.Client.Api;
using Vex.Windows.Core.Vpn;

internal static class SettingsPreferenceReentrancyTests
{
    public static void Run()
    {
        var source = File.ReadAllText(Path.Combine(AppMetadataContractTests.FindRepositoryRoot(), "native-windows", "src",
            "Vex.Windows.App", "Views", "SettingsPage.xaml.cs"));
        var page = CSharpSyntaxTree.ParseText(source).GetRoot().DescendantNodes()
            .OfType<ClassDeclarationSyntax>().Single(type => type.Identifier.ValueText == "SettingsPage");
        var methods = new[] { "OnPreferenceToggled", "OnAutoUpdatesToggled", "SetBusy", "RenderBusyState", "IsSettingsOperationFailure" }
            .Select(name => page.Members.OfType<MethodDeclarationSyntax>()
                .Single(method => method.Identifier.ValueText == name).ToFullString());
        // Full method text is retained. Only UI/store/service boundaries below
        // are fakes; the real preference DTO is reused from the application.
        var probe = Scaffold.Replace("// PRODUCTION_METHODS", string.Join("\n", methods), StringComparison.Ordinal);
        var paths = ((string?)AppContext.GetData("TRUSTED_PLATFORM_ASSEMBLIES"))?.Split(Path.PathSeparator)
            ?? throw new InvalidOperationException("Runtime compiler references not found.");
        var references = paths.Concat(new[] { typeof(NativeClientPreferences).Assembly.Location,
                typeof(VexApiException).Assembly.Location, typeof(VpnConnectionPhase).Assembly.Location })
            .Distinct(StringComparer.Ordinal).Select(path => MetadataReference.CreateFromFile(path));
        var compilation = CSharpCompilation.Create("SettingsPreferenceProbe" + Guid.NewGuid().ToString("N"),
            new[] { CSharpSyntaxTree.ParseText(probe) }, references,
            new CSharpCompilationOptions(OutputKind.DynamicallyLinkedLibrary,
                nullableContextOptions: NullableContextOptions.Enable));
        using var output = new MemoryStream();
        var emitted = compilation.Emit(output);
        if (!emitted.Success)
            throw new InvalidOperationException(string.Join("\n", emitted.Diagnostics.Where(diagnostic =>
                diagnostic.Severity == DiagnosticSeverity.Error)));
        output.Position = 0;
        var context = new AssemblyLoadContext("settings-preference-probe", isCollectible: true);
        try
        {
            var assembly = context.LoadFromStream(output);
            var run = assembly.GetType("SettingsMutationProbe")!.GetMethod("Run", BindingFlags.Public | BindingFlags.Static)!;
            var failures = (string[])run.Invoke(null, null)!;
            if (failures.Length != 0) throw new InvalidOperationException(string.Join("; ", failures));
        }
        finally { context.Unload(); }
    }

    private const string Scaffold = """
using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using Vex.Windows.App.Services;
using Vex.Windows.Client.Api;
using Vex.Windows.Client.Session;
using Vex.Windows.Core.Vpn;
using Vex.Windows.Core.Vpn.Ipc;

public sealed class SettingsMutationProbe
{
    private readonly Services _services = new();
    private bool _renderingPreferences = false, _refreshInFlight, _refreshInterruptedByMutation = false, _isLoaded = true;
    private int _busyCount = 0, _cancelRenders = 0, _resumed = 0, _warnings = 0;
    private readonly CancellationTokenSource _refreshCancellation = new();
    private Update _updateSnapshot = new();
    private readonly ToggleSwitch AutoLaunchToggle = new(), AutoUpdatesToggle = new(), AutoServerToggle = new(),
        SmartRoutingToggle = new(), AntiLeakToggle = new(), AutoRecoveryToggle = new();
    private readonly Control BusyIndicator = new(), RefreshSettingsButton = new(), OpenDownloadsButton = new(),
        CheckUpdatesButton = new(), InstallUpdateButton = new(), RepairServiceButton = new(), CopyDiagnosticsButton = new(),
        LanguagePicker = new(), EnableWindowsHelloButton = new(), DisableWindowsHelloButton = new(), UnlockWindowsHelloButton = new();

    public static string[] Run()
    {
        var failures = new List<string>();
        foreach (var name in new[] { "server", "routing", "anti-leak", "recovery", "updates" })
        foreach (var original in new[] { false, true })
        foreach (var inline in new[] { false, true })
        {
            var result = Execute(name, original, inline, failSave: false, rendering: false);
            if (result != null) failures.Add(result);
        }
        foreach (var name in new[] { "server", "routing", "anti-leak", "recovery", "updates" })
        foreach (var original in new[] { false, true })
        {
            foreach (var failSave in new[] { false, true })
            {
                var result = Execute(name, original, inline: true, failSave: failSave, rendering: !failSave);
                if (result != null) failures.Add(result);
            }
        }
        Console.WriteLine("SETTINGS_CAPTURE_SCENARIOS=40 failures=" + failures.Count);
        return failures.ToArray();
    }

    private static string? Execute(string name, bool original, bool inline, bool failSave, bool rendering)
    {
        var page = new SettingsMutationProbe { _refreshInFlight = inline };
        var initial = NativeClientPreferences.Default with { AutoServerEnabled = original,
            SmartRoutingEnabled = original, AntiLeakEnabled = original, AutoRecoveryEnabled = original,
            AutoUpdatesEnabled = original };
        page._services.Preferences.Current = initial;
        page._services.Preferences.Fail = failSave;
        page.RenderPreferences();
        var control = name switch {
            "server" => page.AutoServerToggle, "routing" => page.SmartRoutingToggle,
            "anti-leak" => page.AntiLeakToggle, "recovery" => page.AutoRecoveryToggle,
            _ => page.AutoUpdatesToggle };
        var enabled = !original;
        control.IsOn = enabled;
        page._renderingPreferences = rendering;
        using var callback = page._refreshCancellation.Token.Register(() => {
            // Complete the retired read inline, as Cancel permits. A concurrent
            // preferences change must also survive the subsequent atomic Update.
            page._services.Preferences.Current = page._services.Preferences.Current with {
                InterfaceLanguage = "en", SelectedLocationId = "parallel-selection" };
            page._refreshInFlight = false;
            page._cancelRenders++;
            page.RenderPreferences();
        });
        try
        {
            if (name == "updates") page.OnAutoUpdatesToggled(control, new RoutedEventArgs());
            else page.OnPreferenceToggled(control, new RoutedEventArgs());
            var expected = inline && !rendering ? initial with {
                InterfaceLanguage = "en", SelectedLocationId = "parallel-selection" } : initial;
            if (!rendering && !failSave)
                expected = name switch {
                    "server" => expected with { AutoServerEnabled = enabled },
                    "routing" => expected with { SmartRoutingEnabled = enabled },
                    "anti-leak" => expected with { AntiLeakEnabled = enabled },
                    "recovery" => expected with { AutoRecoveryEnabled = enabled },
                    _ => expected with { AutoUpdatesEnabled = enabled } };
            var shouldApply = !rendering && !failSave;
            if (page._services.Preferences.Current != expected)
                return $"{name} original={original} inline={inline}: captured intent or concurrent preferences lost";
            if (page._services.Preferences.Writes != (rendering ? 0 : 1) || page._busyCount != 0)
                return name + ": write or busy ownership changed";
            if (page._cancelRenders != (inline && !rendering ? 1 : 0)
                || page._resumed != (inline && !rendering ? 1 : 0))
                return name + ": refresh cancellation/resume changed";
            if (page._warnings != (failSave ? 1 : 0)) return name + ": save failure was not presented";
            if (page._services.Coordinator.Routing != (shouldApply && name == "routing" ? enabled ? "split" : "full" : null))
                return name + ": routing payload differs from intent";
            if (page._services.VpnClient.Enabled != (shouldApply && name == "anti-leak" ? (bool?)enabled : null))
                return name + ": protection payload differs from intent";
            if (page._services.BackgroundUpdates.Checks != (shouldApply && name == "updates" && enabled ? 1 : 0))
                return name + ": update check differs from intent";
            return null;
        }
        finally { page._refreshCancellation.Dispose(); }
    }

    private void RenderPreferences()
    {
        _renderingPreferences = true;
        try {
            var current = _services.Preferences.Current;
            AutoServerToggle.IsOn = current.AutoServerEnabled; SmartRoutingToggle.IsOn = current.SmartRoutingEnabled;
            AntiLeakToggle.IsOn = current.AntiLeakEnabled; AutoRecoveryToggle.IsOn = current.AutoRecoveryEnabled;
            AutoUpdatesToggle.IsOn = current.AutoUpdatesEnabled;
        } finally { _renderingPreferences = false; }
    }
    private void Render() => RenderPreferences();
    private Task RefreshAsync() { _resumed++; _refreshInFlight = true; RenderBusyState(); return Task.CompletedTask; }
    private void ShowNotice(string message, InfoBarSeverity severity) { if (severity == InfoBarSeverity.Warning) _warnings++; }

    // PRODUCTION_METHODS

    private class Control { public bool IsEnabled { get; set; } = true; public bool IsActive { get; set; } }
    private sealed class ToggleSwitch : Control { public bool IsOn { get; set; } }
    private sealed class RoutedEventArgs : EventArgs { }
    private enum InfoBarSeverity { Success, Warning }
    private sealed class Services {
        public Preferences Preferences { get; } = new(); public Coordinator Coordinator { get; } = new();
        public VpnState VpnUiState { get; } = new(); public Client VpnClient { get; } = new();
        public Updates BackgroundUpdates { get; } = new();
    }
    private sealed class Preferences {
        public NativeClientPreferences Current { get; set; } = NativeClientPreferences.Default;
        public bool Fail { get; set; } public int Writes { get; private set; }
        public NativeClientPreferences Update(Func<NativeClientPreferences, NativeClientPreferences> update) {
            Writes++; if (Fail) throw new IOException("fixture save rejected"); return Current = update(Current);
        }
    }
    private sealed class Coordinator {
        public object CurrentState { get; } = new(); public string? Routing { get; private set; }
        public Task SetRoutingPreferencesAsync(string routing, string? bypassRegion, CancellationToken token) {
            Routing = routing; return Task.CompletedTask;
        }
    }
    private sealed class Snapshot { public VpnConnectionPhase Phase => VpnConnectionPhase.Connected; }
    private sealed class VpnState {
        public Snapshot Snapshot { get; } = new();
        public Task<Response> RunAsync(Func<CancellationToken, Task<Response>> run, CancellationToken token) => run(token);
    }
    private sealed class Response { public bool Success => true; }
    private sealed class Client {
        public bool? Enabled { get; private set; }
        public Task<Response> SetAntiLeakAsync(bool enabled, CancellationToken token) {
            Enabled = enabled; return Task.FromResult(new Response());
        }
    }
    private sealed class Release { public string Version => "fixture"; }
    private sealed class Update {
        public bool UpdateAvailable => false; public bool Required => false; public string State => "current";
        public string? Message => null; public Release? Release => null;
    }
    private sealed class Updates {
        public int Checks { get; private set; }
        public Task<Update> CheckNowAsync(CancellationToken token) { Checks++; return Task.FromResult(new Update()); }
    }
}
""";
}
