param(
    [ValidateSet('Release', 'Debug')]
    [string]$Configuration
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([string]::IsNullOrEmpty($Configuration)) {
    $pwsh = [Environment]::ProcessPath
    foreach ($mode in @('Release', 'Debug')) {
        & $pwsh -NoProfile -NonInteractive -File $PSCommandPath -Configuration $mode
        if ($LASTEXITCODE -ne 0) { throw "UiPreviewContext runtime checks failed for $mode." }
    }
    return
}

$sourcePath = Join-Path (Join-Path $PSScriptRoot '..') 'src/Vex.Windows.App/Services/UiPreviewContext.cs'
$actualSource = Get-Content -LiteralPath $sourcePath -Raw
$globalUsings = @'
#nullable enable
global using System;
global using System.IO;
global using System.Linq;

'@
$harness = @'

public static class UiPreviewContextTestHarness
{
    private const string EnvironmentName = "VEX_WINDOWS_PREVIEW";
    private const string EnvironmentSentinel = "preview-runtime-test-original-value";
    private static int _scenarios;
    private static string? _debugCommandInstanceKey;

    public static int Run(bool expectedDebug)
    {
        var originalEnvironment = Environment.GetEnvironmentVariable(EnvironmentName);
        try
        {
            Environment.SetEnvironmentVariable(EnvironmentName, EnvironmentSentinel);
            Check(UiPreviewContext.IsSupported == expectedDebug, "The actual source was compiled with the wrong configuration.");
            Check(UiPreviewContext.ProtocolScheme == "vexguard-ui-preview", "The private preview scheme changed.");

            foreach (var raw in new[]
            {
                "vexguard-ui-preview://ui-smoke/activate",
                "VEXGUARD-UI-PREVIEW://UI-SMOKE/activate",
            })
            {
                var uri = new Uri(raw, UriKind.Absolute);
                Check(UiPreviewContext.IsActivationUri(uri), "The valid activation endpoint was rejected.");
                Check(UiPreviewContext.ParseActivationUri("app.exe \"" + raw + "\"") == uri,
                    "A quoted valid activation URL was not parsed from launch arguments.");
                AssertReservedStartup(new[] { "app.exe", raw }, null, expectedDebug);
                AssertReservedStartup(Array.Empty<string>(), uri, expectedDebug);
            }

            foreach (var raw in new[]
            {
                "vexguard-ui-preview://ui-smoke/unknown-route",
                "vexguard-ui-preview://another-host/activate",
                "vexguard-ui-preview://ui-smoke/activate?route=account",
                "vexguard-ui-preview://user@ui-smoke/activate",
                "vexguard-ui-preview://user:password@ui-smoke/activate",
                "vexguard-ui-preview://ui-smoke/activate#fragment",
                "vexguard-ui-preview://ui-smoke:4321/activate",
                "vexguard-ui-preview:opaque-private-command",
            })
            {
                var uri = new Uri(raw, UriKind.Absolute);
                Check(!UiPreviewContext.IsActivationUri(uri), "An unsupported activation endpoint was accepted: " + raw);
                Check(UiPreviewContext.IsPreviewProtocolUri(uri), "A private command URL escaped scheme reservation: " + raw);
                Check(UiPreviewContext.ParseActivationUri("app.exe \"" + raw + "\"") == uri,
                    "An unsupported private URL escaped raw-argument reservation: " + raw);
                // The Windows SDK may omit ProtocolActivatedEventArgs for an
                // unsupported route. The raw URI still cannot launch normal UI.
                AssertReservedStartup(new[] { "app.exe", "\"" + raw + "\"" }, null, expectedDebug);
                AssertReservedStartup(Array.Empty<string>(), uri, expectedDebug);
            }

            foreach (var raw in new[]
            {
                "vexguard://auth/callback?code=login-code&state=login-state",
                "vex://auth/callback?code=login-code&state=login-state",
                "https://ui-smoke/activate",
                "https://example.test/?redirect=vexguard-ui-preview%3Aopaque",
            })
            {
                var uri = new Uri(raw, UriKind.Absolute);
                Check(!UiPreviewContext.IsActivationUri(uri) && !UiPreviewContext.IsPreviewProtocolUri(uri) &&
                    UiPreviewContext.ParseActivationUri("app.exe \"" + raw + "\"") is null,
                    "Normal auth or HTTPS launch was classified as preview.");
                AssertNormalStartup(new[] { "app.exe", raw }, null);
                AssertNormalStartup(Array.Empty<string>(), uri);
            }
            Check(UiPreviewContext.ParseActivationUri(null) is null && UiPreviewContext.ParseActivationUri(" ") is null &&
                !UiPreviewContext.IsPreviewProtocolUri(null) && !UiPreviewContext.IsActivationUri(null),
                "An empty activation was classified as preview.");
            AssertNormalStartup(new[] { "app.exe", "--normal-argument" }, null);

            var fixtureDirectories = new System.Collections.Generic.HashSet<string>(StringComparer.Ordinal);
            foreach (var flags in new[]
            {
                new[] { "--signed-out-ui-preview" },
                new[] { "--focus-pulse-ui-preview" },
                new[] { "--signed-out-ui-preview", "--focus-pulse-ui-preview" },
            })
            {
                Reset();
                UiPreviewContext.Initialize(flags, null);
                Check(UiPreviewContext.IsPreviewRequest, "A reserved fixture flag escaped preview classification.");
                if (!expectedDebug)
                {
                    Check(!UiPreviewContext.IsEnabled && !UiPreviewContext.IsAuthenticated && UiPreviewContext.StateDirectory is null,
                        "A Release flag enabled preview fixtures or assigned a data directory.");
                    Check(Environment.GetEnvironmentVariable(EnvironmentName) == EnvironmentSentinel,
                        "A Release flag changed the preview environment.");
                    Check(!UiPreviewContext.IsExitCommand("--ui-smoke-exit"), "Release accepted a preview exit command.");
                }
                else
                {
                    var authenticated = flags.Contains("--focus-pulse-ui-preview", StringComparer.Ordinal);
                    Check(UiPreviewContext.IsEnabled && !UiPreviewContext.IsCommandOnly &&
                        UiPreviewContext.IsAuthenticated == authenticated,
                        "Debug fixture flags selected the wrong preview mode.");
                    Check(Environment.GetEnvironmentVariable(EnvironmentName) == (authenticated ? "1" : "0"),
                        "Debug preview did not publish the selected fixture mode.");
                    var directory = UiPreviewContext.StateDirectory ?? throw new InvalidOperationException("Debug fixtures lack an isolated directory.");
                    var root = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "VEX.Windows.UiPreview")) + Path.DirectorySeparatorChar;
                    Check(Path.IsPathFullyQualified(directory) && Path.GetFullPath(directory).StartsWith(root, StringComparison.Ordinal) &&
                        fixtureDirectories.Add(directory), "Debug preview reused state or escaped its isolated temporary root.");
                    Check(!Directory.Exists(directory), "Initializing preview unexpectedly wrote data to disk.");
                    Check(UiPreviewContext.IsExitCommand("--ui-smoke-exit") && !UiPreviewContext.IsExitCommand("--not-ui-smoke-exit"),
                        "The Debug preview exit command does not match its exact reserved flag.");
                    Directory.CreateDirectory(directory);
                    File.WriteAllText(Path.Combine(directory, "isolated-fixture.txt"), "temporary preview test fixture");
                    UiPreviewContext.Cleanup();
                    Check(!Directory.Exists(directory), "Actual preview cleanup left its isolated test data behind.");
                }
                _scenarios++;
            }
            AssertReservedStartup(new[] { "app.exe", "--ui-smoke-exit" }, null, expectedDebug);
            return _scenarios;
        }
        finally
        {
            Reset();
            Environment.SetEnvironmentVariable(EnvironmentName, originalEnvironment);
        }
    }

    private static void AssertReservedStartup(string[] arguments, Uri? protocolUri, bool expectedDebug)
    {
        Reset();
        UiPreviewContext.Initialize(arguments, protocolUri);
        Check(UiPreviewContext.IsPreviewRequest && !UiPreviewContext.IsEnabled && !UiPreviewContext.IsAuthenticated &&
            UiPreviewContext.StateDirectory is null, "A reserved private command activated normal or fixture state.");
        if (expectedDebug)
        {
            Check(UiPreviewContext.IsCommandOnly && !string.IsNullOrEmpty(UiPreviewContext.InstanceKey) &&
                UiPreviewContext.InstanceKey != "main", "Debug redirected a private command into the production instance.");
            _debugCommandInstanceKey ??= UiPreviewContext.InstanceKey;
            Check(UiPreviewContext.InstanceKey == _debugCommandInstanceKey,
                "Private command URLs selected different instances for the same executable.");
        }
        else
        {
            Check(UiPreviewContext.InstanceKey == "main", "Release rejection selected a preview instance.");
        }
        Check(Environment.GetEnvironmentVariable(EnvironmentName) == EnvironmentSentinel,
            "A command-only launch changed the preview environment.");
        _scenarios++;
    }

    private static void AssertNormalStartup(string[] arguments, Uri? protocolUri)
    {
        Reset();
        UiPreviewContext.Initialize(arguments, protocolUri);
        Check(!UiPreviewContext.IsPreviewRequest && !UiPreviewContext.IsEnabled && !UiPreviewContext.IsCommandOnly &&
            UiPreviewContext.StateDirectory is null && UiPreviewContext.InstanceKey == "main",
            "Normal launch acquired preview state or a preview instance identity.");
        Check(Environment.GetEnvironmentVariable(EnvironmentName) == EnvironmentSentinel,
            "Normal launch changed the preview environment.");
        _scenarios++;
    }

    private static void Reset()
    {
        UiPreviewContext.Cleanup();
        SetProperty("IsEnabled", false);
        SetProperty("IsAuthenticated", false);
        SetProperty("IsPreviewRequest", false);
        SetProperty("IsCommandOnly", false);
        SetProperty("StateDirectory", null);
        SetProperty("InstanceKey", "main");
        Environment.SetEnvironmentVariable(EnvironmentName, EnvironmentSentinel);
    }

    private static void SetProperty(string name, object? value)
    {
        var property = typeof(UiPreviewContext).GetProperty(name,
            System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Static)
            ?? throw new InvalidOperationException("Preview state property is missing: " + name);
        var setter = property.GetSetMethod(nonPublic: true)
            ?? throw new InvalidOperationException("Preview state cannot be reset: " + name);
        setter.Invoke(null, new[] { value });
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
'@

$compilerOptions = @('/nullable:enable')
if ($Configuration -eq 'Debug') { $compilerOptions += '/define:DEBUG' }
# Compile the production file verbatim. Only the normal project global usings
# and a public harness in its existing file-scoped namespace are added.
Add-Type -TypeDefinition ($globalUsings + [Environment]::NewLine + $actualSource + [Environment]::NewLine + $harness) -CompilerOptions $compilerOptions
$scenarios = [Vex.Windows.App.Services.UiPreviewContextTestHarness]::Run($Configuration -eq 'Debug')
Write-Host "PASS UiPreviewContext actual-source $Configuration runtime: $scenarios startup scenarios."
