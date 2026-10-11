[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$path = Join-Path $PSScriptRoot '../scripts/smoke-application.ps1'
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$parseErrors)
if (@($parseErrors).Count -ne 0) { throw 'Application smoke has PowerShell parse errors.' }

# Compile the exact interop definitions used by the smoke; no native calls run here.
$nativeSource = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
        $node.Value.Contains('namespace Vex.Windows.Smoke')
}, $true)
if ($null -eq $nativeSource) { throw 'Application smoke interop definitions are missing.' }
if (-not ('Vex.Windows.Smoke.NativeMethods' -as [type])) {
    Add-Type -TypeDefinition $nativeSource.Value
}

if ($IsWindows) {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Windows.Forms
}

$typeNodes = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.TypeExpressionAst] -or
        $node -is [System.Management.Automation.Language.TypeConstraintAst]
}, $true))
$deferred = [Collections.Generic.HashSet[string]]::new()
$checked = [Collections.Generic.HashSet[string]]::new()
foreach ($node in $typeNodes) {
    $name = $node.TypeName.FullName
    if (-not $IsWindows -and $name -match '^Windows\.(Automation|Forms)\.') {
        [void]$deferred.Add($name)
        continue
    }
    if ($null -eq $node.TypeName.GetReflectionType()) {
        throw "Application smoke uses an unresolved runtime type: $name"
    }
    [void]$checked.Add($name)
}

# These casts execute, unlike AST parsing; a C# alias such as [nint] cannot substitute.
if ([System.IntPtr]::Zero.ToInt64() -ne 0 -or ([System.IntPtr](-4)).ToInt64() -ne -4) {
    throw 'Application smoke native pointer conversion is invalid.'
}
if ([Runtime.InteropServices.Marshal]::SizeOf([type][Vex.Windows.Smoke.WindowRect]) -ne 16) {
    throw 'Application smoke native window rectangle layout is invalid.'
}
if ([Runtime.InteropServices.Marshal]::SizeOf([type][Vex.Windows.Smoke.WindowPoint]) -ne 8) {
    throw 'Application smoke native cursor point layout is invalid.'
}

# Execute the actual pure capture helpers, without desktop interaction.
foreach ($functionName in @('Wait-SmokeCondition', 'Wait-SmokeCaptureBounds', 'Get-SmokeCaptureCursorPoint', 'Set-SmokeCaptureFocus',
    'Assert-SmokeTrayRecoveryDiagnostic', 'Assert-SmokeProtectedStateDiagnostic', 'Open-SmokeTrayDiagnosticRead',
    'Read-SmokeTrayDiagnostic', 'Assert-SmokeTrayActivationProgress', 'Wait-SmokeTrayRecoveryDiagnostic',
    'Get-SmokeTrayRequestPaths', 'Invoke-SmokeTrayRequest')) {
    $functionAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
    }, $true)
    if ($null -eq $functionAst) { throw "Application smoke helper is missing: $functionName" }
    . ([scriptblock]::Create($functionAst.Extent.Text))
}
$trayDiagnostic = [ordered]@{
    schema = 'vex.windows.ui-preview-tray-recovery.v1'; process_id = 123; preview_mode = 'fixtures';
    scenario = 'locked'; access = 'Locked'; handler_completed = $true;
    connect_requests = 0; trusted_connect_requests = 0; connection_desired = $false; waiting_for_browser_auth = $false
}
Assert-SmokeTrayRecoveryDiagnostic -Diagnostic ([pscustomobject]$trayDiagnostic) -Scenario 'locked' -Access 'Locked' -Mode 'fixtures' -ProcessId 123
foreach ($invalid in @(
    @{ key = 'connect_requests'; value = 1 }, @{ key = 'trusted_connect_requests'; value = 1 },
    @{ key = 'connection_desired'; value = $true }, @{ key = 'waiting_for_browser_auth'; value = $true },
    @{ key = 'handler_completed'; value = $false }, @{ key = 'process_id'; value = 999 },
    @{ key = 'access'; value = 'Available' }, @{ key = 'connection_desired'; value = 'false' }
)) {
    $badDiagnostic = [ordered]@{}
    foreach ($key in $trayDiagnostic.Keys) { $badDiagnostic[$key] = $trayDiagnostic[$key] }
    $badDiagnostic[$invalid.key] = $invalid.value
    $rejected = $false
    try { Assert-SmokeTrayRecoveryDiagnostic -Diagnostic ([pscustomobject]$badDiagnostic) -Scenario 'locked' -Access 'Locked' -Mode 'fixtures' -ProcessId 123 }
    catch { $rejected = $true }
    if (-not $rejected) { throw "Application smoke accepts invalid actual tray evidence: $($invalid.key)." }
}

# Execute the actual progress validator and wait; a progress/failure record
# cannot replace the completed-v1/no-connect proof or its eight-second gate.
$progress = [ordered]@{
    schema = 'vex.windows.ui-preview-tray-activation.v1'; process_id = 123; preview_mode = 'fixtures'
    scenario = 'reset'; stage = 'reset-ui-requested'; failure_type = $null
}
$progressRejected = 0
$progressMutations = @(
    @{ key = 'schema'; value = 'vex.windows.ui-preview-tray-activation.v0' }
    @{ key = 'schema'; value = $true }
    @{ key = 'process_id'; value = 999 }
    @{ key = 'process_id'; value = '123' }
    @{ key = 'process_id'; value = @(123) }
    @{ key = 'preview_mode'; value = 'signed-out' }
    @{ key = 'preview_mode'; value = $true }
    @{ key = 'scenario'; value = 'locked' }
    @{ key = 'scenario'; value = 'unknown' }
    @{ key = 'scenario'; value = @('reset') }
    @{ key = 'stage'; value = 'completed' }
    @{ key = 'stage'; value = 'unknown' }
    @{ key = 'stage'; value = @('reset-ui-requested') }
    @{ key = 'failure_type'; value = '' }
    @{ key = 'failure_type'; value = 'System.IO.IOException' }
    @{ key = 'failure_type'; value = 'IOException: arbitrary message' }
    @{ key = 'failure_type'; value = 'private/token/Exception' }
    @{ key = 'failure_type'; value = (('A' * 72) + 'Exception') }
    @{ key = 'failure_type'; value = $true }
    @{ key = 'failure_type'; value = @('IOException') }
    @{ key = 'unexpected_message'; value = 'private fixture value' }
)
foreach ($mutation in $progressMutations) {
    $bad = [ordered]@{}
    foreach ($key in $progress.Keys) { $bad[$key] = $progress[$key] }
    $bad[$mutation.key] = $mutation.value
    $bad = [pscustomobject]$bad | ConvertTo-Json -Depth 6 | ConvertFrom-Json
    $rejected = $false
    try { Assert-SmokeTrayActivationProgress -Diagnostic $bad -Scenario 'reset' -Mode 'fixtures' -ProcessId 123 }
    catch { $rejected = $true }
    if (-not $rejected) { throw "Application smoke accepts invalid tray progress: $($mutation.key)." }
    $progressRejected++
}
foreach ($missing in $progress.Keys) {
    $bad = [pscustomobject]$progress | ConvertTo-Json | ConvertFrom-Json
    $bad.PSObject.Properties.Remove($missing)
    $rejected = $false
    try { Assert-SmokeTrayActivationProgress -Diagnostic $bad -Scenario 'reset' -Mode 'fixtures' -ProcessId 123 }
    catch { $rejected = $true }
    if (-not $rejected) { throw "Application smoke accepts missing tray progress field: $missing." }
    $progressRejected++
}
Assert-SmokeTrayActivationProgress -Diagnostic ([pscustomobject]$progress) -Scenario 'reset' -Mode 'fixtures' -ProcessId 123
foreach ($exceptionType in @('Exception', 'IOException', 'UnauthorizedAccessException')) {
    $progress.failure_type = $exceptionType
    Assert-SmokeTrayActivationProgress -Diagnostic ([pscustomobject]$progress) -Scenario 'reset' -Mode 'fixtures' -ProcessId 123
}
$progress.failure_type = $null

# Windows replacement may report access denied (5) or sharing violation (32).
# Only their exact managed type/HRESULT pairs count as the expected conflict.
function Test-SmokeTraySharingFailure {
    param([Parameter(Mandatory = $true)][Exception]$ErrorObject)
    $original = $ErrorObject.GetBaseException()
    return (($original.GetType() -eq [UnauthorizedAccessException] -and $original.HResult -eq -2147024891) -or
        ($original.GetType() -eq [IO.IOException] -and $original.HResult -eq -2147024864))
}
$denied = [UnauthorizedAccessException]::new('isolated classification fixture')
$sharing = [IO.IOException]::new('isolated classification fixture', -2147024864)
foreach ($expected in @($denied, $sharing, [Exception]::new('isolated wrapper', $denied),
    [Exception]::new('isolated wrapper', [Exception]::new('nested wrapper', $sharing)))) {
    if (-not (Test-SmokeTraySharingFailure -ErrorObject $expected)) { throw 'Tray sharing control rejects an exact Windows denied-replacement type/HRESULT pair.' }
}
$wrongDenied = [UnauthorizedAccessException]::new('isolated classification fixture')
$wrongDenied.HResult = -2147024864
$wrongSharing = [IO.IOException]::new('isolated classification fixture', -2147024891)
$wrongFacility = [IO.IOException]::new('isolated classification fixture', 32)
$derivedSharing = [IO.DirectoryNotFoundException]::new('isolated classification fixture')
$derivedSharing.HResult = -2147024864
foreach ($unexpected in @($wrongDenied, $wrongSharing, $wrongFacility, $derivedSharing,
    [IO.IOException]::new('isolated classification fixture'), [NullReferenceException]::new(),
    [Exception]::new('isolated wrapper', [ArgumentException]::new()))) {
    if (Test-SmokeTraySharingFailure -ErrorObject $unexpected) { throw 'Tray sharing control accepts an unrelated failure or a mismatched Windows type/HRESULT pair.' }
}
Write-Host 'Tray sharing exception classification passed: 4 exact/nested positives; 7 unrelated/mismatched negatives.'

# Paths are computed by the actual consumer from a typed nonce and original PID.
$trayTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('vex-tray-diagnostic-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $trayTestRoot | Out-Null
$ownedTrayPaths = [Collections.Generic.List[string]]::new()
function Own-TrayPaths {
    param([Guid]$RequestId, [int]$ProcessId = $PID, [string]$Scenario = 'reset')
    $paths = Get-SmokeTrayRequestPaths -RequestId $RequestId -ProcessId $ProcessId -Scenario $Scenario
    foreach ($candidate in @($paths.Completed, $paths.Completed + '.tmp', $paths.Progress, $paths.Progress + '.tmp')) {
        if (Test-Path -LiteralPath $candidate) { throw 'Tray test refuses pre-existing request files.' }
        $ownedTrayPaths.Add($candidate)
    }
    return $paths
}
try {
    $PreviewMode = 'fixtures'
    $process = [pscustomobject]@{ Id = 123 }
    $result = [ordered]@{ tray_activation_progress = $null }
    $trayDiagnosticHashes = @{}
    $waitRequest = [Guid]::NewGuid()
    $waitPaths = Own-TrayPaths -RequestId $waitRequest -ProcessId 123
    $trayDiagnosticPath = $waitPaths.Completed
    foreach ($failureType in @($null, 'IOException')) {
        $progress.failure_type = $failureType
        [IO.File]::WriteAllText($waitPaths.Progress, ([pscustomobject]$progress | ConvertTo-Json -Compress))
        $waitStarted = [DateTime]::UtcNow
        $rejected = $false
        try { Wait-SmokeTrayRecoveryDiagnostic -RequestId $waitRequest -Scenario 'reset' -Access 'Available' | Out-Null }
        catch {
            if ($_.Exception.Message -cne 'Actual tray recovery did not complete with an isolated diagnostic.') { throw }
            $rejected = $true
        }
        if (-not $rejected -or ([DateTime]::UtcNow - $waitStarted).TotalSeconds -lt 8 -or
            $null -ne $script:trayRecoveryDiagnostic -or $null -eq $result.tray_activation_progress -or
            $result.tray_activation_progress.failure_type -cne $failureType) {
            throw 'Tray progress or failure bypassed completion, lost its sanitized evidence or changed the eight-second wait.'
        }
    }
    $completed = [ordered]@{}
    foreach ($key in $trayDiagnostic.Keys) { $completed[$key] = $trayDiagnostic[$key] }
    $completed.scenario = 'reset'; $completed.access = 'Available'
    [IO.File]::WriteAllText($trayDiagnosticPath, ([pscustomobject]$completed | ConvertTo-Json -Compress))
    $actual = Wait-SmokeTrayRecoveryDiagnostic -RequestId $waitRequest -Scenario 'reset' -Access 'Available'
    if ($actual.scenario -cne 'reset' -or -not $actual.handler_completed -or $null -ne $result.tray_activation_progress) {
        throw 'Actual completed v1 tray receipt changed its contract or retained stale progress from the previous wait.'
    }
    # A valid receipt belonging to another nonce cannot satisfy this request.
    $wrongNonce = [Guid]::NewGuid()
    $wrongPaths = Own-TrayPaths -RequestId $wrongNonce -ProcessId 123
    $waitStarted = [DateTime]::UtcNow
    $rejected = $false
    try { Wait-SmokeTrayRecoveryDiagnostic -RequestId $wrongNonce -Scenario 'reset' -Access 'Available' | Out-Null }
    catch {
        if ($_.Exception.Message -cne 'Actual tray recovery did not complete with an isolated diagnostic.') { throw }
        $rejected = $true
    }
    if (-not $rejected -or ([DateTime]::UtcNow - $waitStarted).TotalSeconds -lt 8 -or $null -ne $script:trayRecoveryDiagnostic) {
        throw 'A different request nonce bypassed the original eight-second completion gate.'
    }
    foreach ($invalid in @(
        @{ RequestId = [Guid]::Empty; ProcessId = 123; Scenario = 'reset' }
        @{ RequestId = [Guid]::NewGuid(); ProcessId = 0; Scenario = 'reset' }
        @{ RequestId = [Guid]::NewGuid(); ProcessId = 123; Scenario = 'unknown' }
        @{ RequestId = [Guid]::NewGuid(); ProcessId = 123; Scenario = 'Reset' }
        @{ RequestId = 'malformed'; ProcessId = 123; Scenario = 'reset' }
    )) {
        $rejected = $false
        try { Get-SmokeTrayRequestPaths @invalid | Out-Null } catch { $rejected = $true }
        if (-not $rejected) { throw 'Tray request paths accept an invalid nonce, process or scenario.' }
    }
    # Exercise actual launch metadata without starting a process or touching UI.
    function Invoke-RedirectedLaunch { param([string]$Arguments) $script:capturedTrayArguments = $Arguments }
    $requestA = Invoke-SmokeTrayRequest -Scenario 'locked'
    $argumentsA = $script:capturedTrayArguments
    $requestB = Invoke-SmokeTrayRequest -Scenario 'locked'
    if ($requestA -eq $requestB -or $argumentsA -cne "--ui-smoke-tray-connect-locked --ui-smoke-tray-request=$($requestA.ToString('N'))" -or
        $script:capturedTrayArguments -cne "--ui-smoke-tray-connect-locked --ui-smoke-tray-request=$($requestB.ToString('N'))") {
        throw 'Actual tray launch consumer did not issue fresh canonical request metadata.'
    }
    foreach ($invalidBytes in @([byte[]]@(0xff), [byte[]]::new(65537), [byte[]]::new(0))) {
        [IO.File]::WriteAllBytes($trayDiagnosticPath, $invalidBytes)
        $rejected = $false
        try { Read-SmokeTrayDiagnostic -Path $trayDiagnosticPath | Out-Null } catch { $rejected = $true }
        if (-not $rejected) { throw 'Tray diagnostic reader accepts invalid UTF8, an empty file or an oversized file.' }
    }
    [IO.File]::WriteAllText($trayDiagnosticPath, '{')
    $rejected = $false
    try { Read-SmokeTrayDiagnostic -Path $trayDiagnosticPath | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Tray diagnostic reader accepts malformed JSON.' }

    # Current completed writer and typed request/progress helpers are exact
    # source, compiled with minimal services instead of WinUI/auth/VPN.
    $fixtureSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../src/Vex.Windows.App/Services/UiPreviewFixtures.cs') -Raw
    $start = $fixtureSource.IndexOf('    internal static void RecordTrayRecovery(')
    $end = $fixtureSource.IndexOf("`n#endif", $start)
    if ($start -lt 0 -or $end -le $start) { throw 'Actual tray receipt writer cannot be extracted.' }
    $writer = $fixtureSource.Substring($start, $end - $start)
    $activationSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../src/Vex.Windows.App/Services/UiPreviewTrayActivation.cs') -Raw
    $requestSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../src/Vex.Windows.App/Services/UiPreviewTrayRequest.cs') -Raw
    # This historical same-path control is VERBATIM from e2779dd2's bounded
    # RecordTrayRecovery method (full source SHA09a5cbc9...). New overwrite:false
    # cannot prove old sharing: an existing destination fails without a reader.
    $legacyWriter = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/UiPreviewTrayLegacyWriter.cs.txt') -Raw).Replace("`r`n", "`n")
    $legacyHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($legacyWriter))).ToLowerInvariant()
    if ($legacyHash -cne 'e9a9858211c1e47f391da50b46eafb9a5a98689eee5c7e9565e96e44c34a4b96') { throw 'Historical tray writer control differs from its frozen source method.' }
    $harnessSource = @'
#nullable enable
using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
namespace Vex.Windows.App.Services;
internal static class UiPreviewContext
{
    internal const string TrayRequestPrefix = "--ui-smoke-tray-request";
    internal static bool IsEnabled = true;
    internal static string? StateDirectory = "isolated-test-directory";
    internal static bool IsProtectedStateFaultPreview = false;
    internal static bool IsAuthenticated = true;
}
internal sealed class AppServices
{
    internal CoordinatorStub Coordinator { get; } = new();
    internal VpnStub VpnUiState { get; } = new();
    internal AuthStub Auth { get; } = new();
}
internal sealed class CoordinatorStub { internal string CurrentStateAccess => "Available"; }
internal sealed class VpnStub { internal bool ConnectionDesired => false; }
internal sealed class AuthStub { internal bool IsWaitingForBrowserAuth => false; }
internal static class UiPreviewFixtures
{
    private static int _connectRequests = 0;
    private static int _trustedConnectRequests = 0;
__ACTUAL_WRITER__
}
internal static class HistoricalUiPreviewFixtures
{
    private static int _connectRequests = 0;
    private static int _trustedConnectRequests = 0;
__HISTORICAL_WRITER__
}
public static class TrayDiagnosticWriterHarness
{
    public static string HistoricalPath => Path.Combine(Path.GetTempPath(), $"vex-ui-preview-tray-{Environment.ProcessId}.json");
    public static void HistoricalComplete() => HistoricalUiPreviewFixtures.RecordTrayRecovery("reset", new());
    public static string CompletedPath(Guid id) => new UiPreviewTrayRequest(id, "reset").CompletedPath;
    public static string ProgressPath(Guid id) => new UiPreviewTrayRequest(id, "reset").ProgressPath;
    public static void Complete(Guid id) => UiPreviewFixtures.RecordTrayRecovery(new(new(id, "reset")), new());
    public static void Stage(Guid id, string stage) => new UiPreviewTrayActivation(new(id, "reset")).Record(stage);
    public static void Fail(Guid id) => new UiPreviewTrayActivation(new(id, "reset")).RecordFailure(new IOException("private test message"));
    public static bool Parse(string? arguments) => UiPreviewTrayRequest.TryParse(arguments, out _);
    public static void RejectOutsidePreview(Guid id)
    {
        UiPreviewContext.IsEnabled = false;
        try { Stage(id, "handler-started"); }
        finally { UiPreviewContext.IsEnabled = true; }
    }
}
'@
    $harnessSource = $harnessSource.Replace('__ACTUAL_WRITER__', $writer).Replace('__HISTORICAL_WRITER__', $legacyWriter)
    $activationSource = $activationSource.Replace('using System.Text.Json;', '').Replace('namespace Vex.Windows.App.Services;', '')
    $requestSource = $requestSource.Replace('namespace Vex.Windows.App.Services;', '')
    Add-Type -TypeDefinition ($harnessSource + "`n" + $activationSource + "`n" + $requestSource) -CompilerOptions @('/nullable:enable', '/define:DEBUG')
    $canonical = 'abcdef0123456789abcdef0123456789'
    foreach ($command in @('--ui-smoke-tray-reset', '--ui-smoke-tray-connect', '--ui-smoke-tray-connect-locked')) {
        if (-not [Vex.Windows.App.Services.TrayDiagnosticWriterHarness]::Parse("$command --ui-smoke-tray-request=$canonical")) { throw 'Actual tray parser rejects a canonical request.' }
        foreach ($executable in @([Environment]::ProcessPath, ('"' + [Environment]::ProcessPath + '"'))) {
            if (-not [Vex.Windows.App.Services.TrayDiagnosticWriterHarness]::Parse("$executable $command --ui-smoke-tray-request=$canonical")) { throw 'Actual tray parser rejects its exact executable-prefixed SDK launch data.' }
        }
    }
    $invalidRequests = @(
        $null, '', '--ui-smoke-tray-reset', "--ui-smoke-tray-request=$canonical",
        '--ui-smoke-tray-reset --ui-smoke-tray-request=00000000000000000000000000000000',
        '--ui-smoke-tray-reset --ui-smoke-tray-request=malformed',
        "--ui-smoke-tray-reset --ui-smoke-tray-request=$([Guid]::Parse($canonical).ToString('D'))",
        "--ui-smoke-tray-reset --ui-smoke-tray-request=$($canonical.ToUpperInvariant())",
        "--ui-smoke-tray-reset --ui-smoke-tray-request=$canonical --ui-smoke-tray-request=$canonical",
        "--ui-smoke-tray-reset --ui-smoke-tray-reset --ui-smoke-tray-request=$canonical",
        "--ui-smoke-tray-reset --ui-smoke-tray-connect --ui-smoke-tray-request=$canonical",
        "--ui-smoke-tray-reset --ui-smoke-tray-request-unknown=$canonical",
        "--ui-smoke-tray-reset --ui-smoke-tray-request=$canonical --ui-smoke-exit",
        "--ui-smoke-tray-reset --ui-smoke-tray-request=$canonical --ui-smoke-minimize",
        "--ui-smoke-tray-reset --ui-smoke-tray-request=$canonical --focus-pulse-ui-preview",
        "--ui-smoke-tray-reset --ui-smoke-tray-request=$canonical --unknown",
        "--ui-smoke-tray-reset --ui-smoke-tray-request $canonical"
        "unknown.exe --ui-smoke-tray-reset --ui-smoke-tray-request=$canonical"
        ('"unknown.exe" --ui-smoke-tray-reset --ui-smoke-tray-request=' + $canonical)
        ('"' + [Environment]::ProcessPath + '"--ui-smoke-tray-reset --ui-smoke-tray-request=' + $canonical)
        ([Environment]::ProcessPath + '.other --ui-smoke-tray-reset --ui-smoke-tray-request=' + $canonical)
    )
    foreach ($invalid in $invalidRequests) {
        if ([Vex.Windows.App.Services.TrayDiagnosticWriterHarness]::Parse($invalid)) { throw 'Actual tray parser accepts malformed, duplicate, missing or mixed request metadata.' }
    }
    $producerRequest = [Guid]::NewGuid()
    $producerPaths = Own-TrayPaths -RequestId $producerRequest
    if ([Vex.Windows.App.Services.TrayDiagnosticWriterHarness]::CompletedPath($producerRequest) -cne $producerPaths.Completed -or
        [Vex.Windows.App.Services.TrayDiagnosticWriterHarness]::ProgressPath($producerRequest) -cne $producerPaths.Progress) { throw 'Actual producer and consumer disagree about nonce-bound paths.' }
    [Vex.Windows.App.Services.TrayDiagnosticWriterHarness]::Stage($producerRequest, 'reset-ui-requested')
    $written = Read-SmokeTrayDiagnostic -Path $producerPaths.Progress
    Assert-SmokeTrayActivationProgress -Diagnostic $written -Scenario 'reset' -Mode 'fixtures' -ProcessId $PID
    [Vex.Windows.App.Services.TrayDiagnosticWriterHarness]::Fail($producerRequest)
    $written = Read-SmokeTrayDiagnostic -Path $producerPaths.Progress
    Assert-SmokeTrayActivationProgress -Diagnostic $written -Scenario 'reset' -Mode 'fixtures' -ProcessId $PID
    if ($written.failure_type -cne 'IOException' -or ($written | ConvertTo-Json) -match 'private test message') { throw 'Actual Debug progress writer leaked an exception message.' }
    $before = (Get-FileHash -LiteralPath $producerPaths.Progress -Algorithm SHA256).Hash
    [Vex.Windows.App.Services.TrayDiagnosticWriterHarness]::RejectOutsidePreview($producerRequest)
    if ((Get-FileHash -LiteralPath $producerPaths.Progress -Algorithm SHA256).Hash -cne $before) { throw 'Debug progress wrote outside active isolated preview.' }
    New-Item -ItemType Directory -Path ($producerPaths.Progress + '.tmp') | Out-Null
    try {
        [Vex.Windows.App.Services.TrayDiagnosticWriterHarness]::Stage($producerRequest, 'handler-started')
        if ((Get-FileHash -LiteralPath $producerPaths.Progress -Algorithm SHA256).Hash -cne $before) { throw 'Best-effort progress changed evidence after a failed write.' }
        # Completion must succeed independently of its blocked progress writer.
        [Vex.Windows.App.Services.TrayDiagnosticWriterHarness]::Complete($producerRequest)
        $actual = Read-SmokeTrayDiagnostic -Path $producerPaths.Completed
        Assert-SmokeTrayRecoveryDiagnostic -Diagnostic $actual -Scenario 'reset' -Access 'Available' -Mode 'fixtures' -ProcessId $PID
    }
    finally { Remove-Item -LiteralPath ($producerPaths.Progress + '.tmp') }
    $completedHash = (Get-FileHash -LiteralPath $producerPaths.Completed -Algorithm SHA256).Hash
    $rejected = $false
    try { [Vex.Windows.App.Services.TrayDiagnosticWriterHarness]::Complete($producerRequest) } catch { $rejected = $true }
    if (-not $rejected -or (Get-FileHash -LiteralPath $producerPaths.Completed -Algorithm SHA256).Hash -cne $completedHash -or
        (Test-Path -LiteralPath ($producerPaths.Completed + '.tmp'))) { throw 'Reused request rewrote an accepted immutable completed receipt.' }
    $blockedRequest = [Guid]::NewGuid()
    $blockedPaths = Own-TrayPaths -RequestId $blockedRequest
    New-Item -ItemType Directory -Path ($blockedPaths.Completed + '.tmp') | Out-Null
    $rejected = $false
    try { [Vex.Windows.App.Services.TrayDiagnosticWriterHarness]::Complete($blockedRequest) } catch { $rejected = $true }
    if (-not $rejected -or (Test-Path -LiteralPath $blockedPaths.Completed)) { throw 'Blocked completed temporary path did not preserve producer failure.' }
    Remove-Item -LiteralPath ($blockedPaths.Completed + '.tmp')

    function Invoke-CurrentTrayWriterControl {
        param([Guid]$RequestId)
        try { [Vex.Windows.App.Services.TrayDiagnosticWriterHarness]::Complete($RequestId) }
        catch {
            $original = $_.Exception.GetBaseException()
            $kind = $original.GetType().Name
            if ($kind -cnotmatch '^(Exception|[A-Za-z_][A-Za-z0-9_]{0,70}Exception)$') { $kind = 'UnexpectedException' }
            $stage = 'before-operation-stage'
            $paths = Get-SmokeTrayRequestPaths -RequestId $RequestId -ProcessId $PID -Scenario 'reset'
            if (Test-Path -LiteralPath $paths.Progress -PathType Leaf) {
                $diagnostic = Read-SmokeTrayDiagnostic -Path $paths.Progress
                Assert-SmokeTrayActivationProgress -Diagnostic $diagnostic -Scenario 'reset' -Mode 'fixtures' -ProcessId $PID
                $stage = $diagnostic.stage
            }
            Write-Host ('Current unique tray producer failure: stage={0}; type={1}; HRESULT={2:X8}.' -f $stage, $kind, $original.HResult)
            throw 'Current unique tray producer failed its Windows held-reader control.'
        }
    }
    $producerPath = [Vex.Windows.App.Services.TrayDiagnosticWriterHarness]::HistoricalPath
    if ($IsWindows) {
        foreach ($candidate in @($producerPath, $producerPath + '.tmp')) {
            if (Test-Path -LiteralPath $candidate) { throw 'Historical tray writer control refuses pre-existing diagnostic paths.' }
            $ownedTrayPaths.Add($candidate)
        }
        # Both old provider and actual bounded Delete reader retain old paths.
        # Historical same-path replacement fails; unique current receipt works.
        foreach ($readerKind in @('provider', 'bounded-Delete')) {
            $locked = [ordered]@{}
            foreach ($key in $trayDiagnostic.Keys) { $locked[$key] = $trayDiagnostic[$key] }
            $locked.process_id = $PID
            [IO.File]::WriteAllText($producerPath, ([pscustomobject]$locked | ConvertTo-Json -Compress))
            if (Test-Path -LiteralPath ($producerPath + '.tmp')) { throw 'Historical sharing control refuses a pre-existing temporary receipt.' }
            $legacyTargetHash = (Get-FileHash -LiteralPath $producerPath -Algorithm SHA256).Hash
            $legacyReaders = $null; $held = $null
            if ($readerKind -ceq 'provider') {
                $legacyReaders = $ExecutionContext.SessionState.InvokeProvider.Content.GetReader($producerPath)
                if ($legacyReaders.Count -ne 1) { throw 'Historical control did not obtain exactly one actual provider reader.' }
                $legacy = $legacyReaders[0]
                $snapshot = @($legacy.Read(1))
                if ($snapshot.Count -ne 1) { throw 'Historical provider did not retain exactly one old JSON snapshot.' }
                $old = $snapshot[0] | ConvertFrom-Json
                $flags = [Reflection.BindingFlags]'NonPublic,Instance'
                $streamField = $legacy.GetType().GetField('_stream', $flags)
                $shareField = $legacy.GetType().GetField('_share', $flags)
                if ($null -eq $streamField -or $null -eq $shareField) { throw 'Actual provider lacks inspectable held stream/share state.' }
                $held = $streamField.GetValue($legacy)
                $share = $shareField.GetValue($legacy)
                if ($share -isnot [IO.FileShare] -or ($share -band [IO.FileShare]::Delete) -ne 0) { throw 'Provider negative lacks no-Delete sharing.' }
            }
            else {
                $held = Open-SmokeTrayDiagnosticRead -Path $producerPath
                $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
            }
            try {
                if ($held -isnot [IO.FileStream] -or -not $held.CanRead -or $held.SafeFileHandle.IsClosed -or $held.SafeFileHandle.IsInvalid) { throw 'Historical control lacks a valid held original handle.' }
                Write-Host ('Tray sharing control runtime: PowerShell={0}; framework={1}; reader={2}; share={3}; held-open=True.' -f
                    $PSVersionTable.PSVersion.ToString(), [Runtime.InteropServices.RuntimeInformation]::FrameworkDescription, $readerKind, [int]$share)
                $succeeded = $false; $rejected = $false
                try { [Vex.Windows.App.Services.TrayDiagnosticWriterHarness]::HistoricalComplete(); $succeeded = $true }
                catch {
                    $original = $_.Exception.GetBaseException()
                    $kind = $original.GetType().Name
                    if ($kind -cnotmatch '^(Exception|[A-Za-z_][A-Za-z0-9_]{0,70}Exception)$') { $kind = 'UnexpectedException' }
                    Write-Host ('Historical same-path producer failure: reader={0}; type={1}; HRESULT={2:X8}.' -f $readerKind, $kind, $original.HResult)
                    $rejected = Test-SmokeTraySharingFailure -ErrorObject $_.Exception
                }
                if ($succeeded -or -not $rejected -or -not $held.CanRead -or $held.SafeFileHandle.IsClosed -or
                    $held.SafeFileHandle.IsInvalid -or (Get-FileHash -LiteralPath $producerPath -Algorithm SHA256).Hash -cne $legacyTargetHash) {
                    throw 'Historical held-reader replacement did not prove exact denied sharing and unchanged old receipt.'
                }
                $staged = Read-SmokeTrayDiagnostic -Path ($producerPath + '.tmp')
                Assert-SmokeTrayRecoveryDiagnostic -Diagnostic $staged -Scenario 'reset' -Access 'Available' -Mode 'fixtures' -ProcessId $PID
                $uniqueRequest = [Guid]::NewGuid()
                $uniquePaths = Own-TrayPaths -RequestId $uniqueRequest
                Invoke-CurrentTrayWriterControl -RequestId $uniqueRequest
                $new = Read-SmokeTrayDiagnostic -Path $uniquePaths.Completed
                Assert-SmokeTrayRecoveryDiagnostic -Diagnostic $new -Scenario 'reset' -Access 'Available' -Mode 'fixtures' -ProcessId $PID
                if (-not $held.CanRead -or $held.SafeFileHandle.IsClosed -or $held.SafeFileHandle.IsInvalid -or
                    (Get-FileHash -LiteralPath $producerPath -Algorithm SHA256).Hash -cne $legacyTargetHash) { throw 'Unique completion modified the old receipt or lost its held original reader.' }
                if ($readerKind -ceq 'bounded-Delete') {
                    $oldReader = [IO.StreamReader]::new($held, [Text.UTF8Encoding]::new($false, $true), $false, 1024, $true)
                    try { $old = $oldReader.ReadToEnd() | ConvertFrom-Json } finally { $oldReader.Dispose() }
                }
                Assert-SmokeTrayRecoveryDiagnostic -Diagnostic $old -Scenario 'locked' -Access 'Locked' -Mode 'fixtures' -ProcessId $PID
            }
            finally {
                if ($null -ne $legacyReaders) { foreach ($reader in $legacyReaders) { $reader.Close(); $reader.Dispose() } }
                elseif ($null -ne $held) { $held.Dispose() }
            }
            # The SAME historical writer succeeds when its destination closes.
            [Vex.Windows.App.Services.TrayDiagnosticWriterHarness]::HistoricalComplete()
            $released = Read-SmokeTrayDiagnostic -Path $producerPath
            Assert-SmokeTrayRecoveryDiagnostic -Diagnostic $released -Scenario 'reset' -Access 'Available' -Mode 'fixtures' -ProcessId $PID
            Write-Host ('Actual Windows tray topology control passed: reader={0}; historical same-path denied; same writer after close succeeds; current unique receipt succeeds with old reader held and old snapshot unchanged.' -f $readerKind)
        }
    }
    else { Write-Host 'DEFERRED actual Windows tray topology controls: portable host does not enforce Windows destination-open replacement semantics.' }
}
finally {
    foreach ($ownedPath in $ownedTrayPaths) {
        Remove-Item -LiteralPath $ownedPath -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $trayTestRoot -Recurse -Force
}
Write-Host "Application smoke tray progress passed: $progressRejected malformed records rejected; pending/fault/wrong-nonce cannot pass; actual Debug producer and bounded reader exercised."

# Exercise the exact receipt validator with JSON-shaped values. These checks
# never invoke DPAPI, the filesystem fault matrix, or the WinUI application.
function New-SmokeProtectedStateDiagnostic {
    param([ValidateSet('Startup', 'Cleanup')][string]$Phase)
    $expectedCases = [ordered]@{
        'dpapi-roundtrip' = 'available'; 'invalid-ciphertext' = 'unusable'; 'malformed-json' = 'unusable'
        'invalid-owner-map' = 'unusable'; 'missing-map' = 'unusable'; 'missing-own-account' = 'unusable'
        'registration-mismatch' = 'unusable'; 'external-id-mismatch' = 'unusable'
        'map-sharing-violation' = 'unavailable'; 'map-path-is-directory' = 'unavailable'
        'map-write-sharing-violation' = 'write-unavailable'; 'authoritative-key-restoration' = 'authoritative'
    }
    $cases = @(foreach ($id in $expectedCases.Keys) {
        [pscustomobject][ordered]@{
            id = $id; outcome = $expectedCases[$id]
            passed = $true; files_preserved = $true; reopened = $true; recovered = $true
        }
    })
    return [pscustomobject][ordered]@{
        schema = 'vex.windows.protected-state-faults.v1'; process_id = 123; mode = 'protected-state-fault'
        stage = $(if ($Phase -eq 'Cleanup') { 'completed' } else { 'startup-completed' })
        case_count = $cases.Count; cases = $cases
        real_current_user_dpapi = $true; startup_completed = $true; startup_access = 'Missing'
        startup_has_stored_session = $true; startup_error_reported = $true; startup_files_preserved = $true
        owned_directory_removed = ($Phase -eq 'Cleanup')
    }
}

$protectedStateMutations = @(
    @{ name = 'schema'; mutate = { param($bad) $bad.schema = 'vex.windows.protected-state-faults.v0' } }
    @{ name = 'schema-case'; mutate = { param($bad) $bad.schema = 'VEX.windows.protected-state-faults.v1' } }
    @{ name = 'schema-boolean-true'; mutate = { param($bad) $bad.schema = $true } }
    @{ name = 'schema-boolean-false'; mutate = { param($bad) $bad.schema = $false } }
    @{ name = 'schema-array'; mutate = { param($bad) $bad.schema = @($bad.schema) } }
    @{ name = 'schema-null'; mutate = { param($bad) $bad.schema = $null } }
    @{ name = 'unknown-private-field'; mutate = {
        param($bad)
        $bad | Add-Member -NotePropertyName 'private_material' -NotePropertyValue 'fixture-private-value'
    } }
    @{ name = 'process-id'; mutate = { param($bad) $bad.process_id = 999 } }
    @{ name = 'process-id-type'; mutate = { param($bad) $bad.process_id = '123' } }
    @{ name = 'mode'; mutate = { param($bad) $bad.mode = 'fixtures' } }
    @{ name = 'mode-boolean-true'; mutate = { param($bad) $bad.mode = $true } }
    @{ name = 'mode-boolean-false'; mutate = { param($bad) $bad.mode = $false } }
    @{ name = 'mode-array'; mutate = { param($bad) $bad.mode = @($bad.mode) } }
    @{ name = 'mode-null'; mutate = { param($bad) $bad.mode = $null } }
    @{ name = 'stage'; mutate = { param($bad) $bad.stage = 'matrix-completed' } }
    @{ name = 'stage-boolean-true'; mutate = { param($bad) $bad.stage = $true } }
    @{ name = 'stage-boolean-false'; mutate = { param($bad) $bad.stage = $false } }
    @{ name = 'stage-array'; mutate = { param($bad) $bad.stage = @($bad.stage) } }
    @{ name = 'stage-null'; mutate = { param($bad) $bad.stage = $null } }
    @{ name = 'phase'; mutate = { param($bad) $bad.stage = $(if ($bad.stage -eq 'completed') { 'startup-completed' } else { 'completed' }) } }
    @{ name = 'case-count'; mutate = { param($bad) $bad.case_count = 11 } }
    @{ name = 'case-count-type'; mutate = { param($bad) $bad.case_count = '12' } }
    @{ name = 'missing-case'; mutate = { param($bad) $bad.cases = @($bad.cases[0..10]) } }
    @{ name = 'unknown-case'; mutate = { param($bad) $bad.cases[11].id = 'unqualified-case' } }
    @{ name = 'duplicate-case'; mutate = { param($bad) $bad.cases[11] = $bad.cases[0] } }
    @{ name = 'case-id-case'; mutate = { param($bad) $bad.cases[0].id = 'DPAPI-roundtrip' } }
    @{ name = 'case-variant-duplicate'; mutate = {
        param($bad)
        $bad.cases[11].id = 'DPAPI-roundtrip'; $bad.cases[11].outcome = 'available'
    } }
    @{ name = 'wrong-outcome'; mutate = { param($bad) $bad.cases[1].outcome = 'available' } }
    @{ name = 'outcome-case'; mutate = { param($bad) $bad.cases[0].outcome = 'Available' } }
    @{ name = 'outcome-boolean-true'; mutate = { param($bad) $bad.cases[0].outcome = $true } }
    @{ name = 'outcome-boolean-false'; mutate = { param($bad) $bad.cases[0].outcome = $false } }
    @{ name = 'outcome-array'; mutate = { param($bad) $bad.cases[0].outcome = @($bad.cases[0].outcome) } }
    @{ name = 'outcome-null'; mutate = { param($bad) $bad.cases[0].outcome = $null } }
    @{ name = 'failed-case'; mutate = { param($bad) $bad.cases[0].passed = $false } }
    @{ name = 'case-pass-type'; mutate = { param($bad) $bad.cases[0].passed = 'true' } }
    @{ name = 'case-files-changed'; mutate = { param($bad) $bad.cases[0].files_preserved = $false } }
    @{ name = 'case-files-type'; mutate = { param($bad) $bad.cases[0].files_preserved = 'true' } }
    @{ name = 'case-not-reopened'; mutate = { param($bad) $bad.cases[0].reopened = $false } }
    @{ name = 'case-reopened-type'; mutate = { param($bad) $bad.cases[0].reopened = 1 } }
    @{ name = 'case-not-recovered'; mutate = { param($bad) $bad.cases[0].recovered = $false } }
    @{ name = 'case-recovered-type'; mutate = { param($bad) $bad.cases[0].recovered = 'true' } }
    @{ name = 'case-missing-proof'; mutate = { param($bad) $bad.cases[0].PSObject.Properties.Remove('recovered') } }
    @{ name = 'unknown-case-private-field'; mutate = {
        param($bad)
        $bad.cases[0] | Add-Member -NotePropertyName 'private_key' -NotePropertyValue 'fixture-private-value'
    } }
    @{ name = 'dpapi-not-real'; mutate = { param($bad) $bad.real_current_user_dpapi = $false } }
    @{ name = 'dpapi-type'; mutate = { param($bad) $bad.real_current_user_dpapi = 'true' } }
    @{ name = 'startup-incomplete'; mutate = { param($bad) $bad.startup_completed = $false } }
    @{ name = 'startup-completed-type'; mutate = { param($bad) $bad.startup_completed = 1 } }
    @{ name = 'startup-access'; mutate = { param($bad) $bad.startup_access = 'Available' } }
    @{ name = 'startup-access-boolean-true'; mutate = { param($bad) $bad.startup_access = $true } }
    @{ name = 'startup-access-boolean-false'; mutate = { param($bad) $bad.startup_access = $false } }
    @{ name = 'startup-access-array'; mutate = { param($bad) $bad.startup_access = @($bad.startup_access) } }
    @{ name = 'startup-access-null'; mutate = { param($bad) $bad.startup_access = $null } }
    @{ name = 'startup-session-lost'; mutate = { param($bad) $bad.startup_has_stored_session = $false } }
    @{ name = 'startup-session-type'; mutate = { param($bad) $bad.startup_has_stored_session = 'true' } }
    @{ name = 'startup-error-absent'; mutate = { param($bad) $bad.startup_error_reported = $false } }
    @{ name = 'startup-error-type'; mutate = { param($bad) $bad.startup_error_reported = 'true' } }
    @{ name = 'startup-files-changed'; mutate = { param($bad) $bad.startup_files_preserved = $false } }
    @{ name = 'startup-files-type'; mutate = { param($bad) $bad.startup_files_preserved = 'true' } }
    @{ name = 'startup-missing-proof'; mutate = { param($bad) $bad.PSObject.Properties.Remove('startup_files_preserved') } }
    @{ name = 'cleanup-phase'; mutate = { param($bad) $bad.owned_directory_removed = -not $bad.owned_directory_removed } }
    @{ name = 'cleanup-type'; mutate = { param($bad) $bad.owned_directory_removed = 'false' } }
)
$protectedStateRejected = 0
foreach ($phase in @('Startup', 'Cleanup')) {
    $validProtectedState = New-SmokeProtectedStateDiagnostic -Phase $phase
    Assert-SmokeProtectedStateDiagnostic -Diagnostic $validProtectedState -ProcessId 123 -Phase $phase
    $jsonProtectedState = $validProtectedState | ConvertTo-Json -Depth 6 | ConvertFrom-Json
    Assert-SmokeProtectedStateDiagnostic -Diagnostic $jsonProtectedState -ProcessId 123 -Phase $phase
    foreach ($mutation in $protectedStateMutations) {
        $bad = $validProtectedState | ConvertTo-Json -Depth 6 | ConvertFrom-Json
        $mutate = $mutation.mutate
        & $mutate $bad
        # Preserve the malformed field's actual JSON type, including arrays and
        # null, rather than relying on PowerShell assignment coercion.
        $bad = $bad | ConvertTo-Json -Depth 6 | ConvertFrom-Json
        $rejected = $false
        try { Assert-SmokeProtectedStateDiagnostic -Diagnostic $bad -ProcessId 123 -Phase $phase }
        catch { $rejected = $true }
        if (-not $rejected) { throw "Application smoke accepts invalid protected-state $phase evidence: $($mutation.name)." }
        $protectedStateRejected++
    }
}
Write-Host "Application smoke protected-state receipt verification passed: 2 valid phases; $protectedStateRejected invalid receipts rejected."

$desktop = [pscustomobject]@{ Left = -1920; Top = -200; Right = 0; Bottom = 880 }
$bounds = [pscustomobject]@{ Left = -1840; Top = -140; Right = -900; Bottom = 500 }
$point = Get-SmokeCaptureCursorPoint -Desktop $desktop -WindowBounds $bounds
if ($point.X -ne -1918 -or $point.Y -ne -198) {
    throw 'Application smoke cursor selection mishandles negative desktop origins.'
}
$desktop = [pscustomobject]@{ Left = 0; Top = 0; Right = 1024; Bottom = 768 }
$bounds = [pscustomobject]@{ Left = 0; Top = 0; Right = 700; Bottom = 650 }
$point = Get-SmokeCaptureCursorPoint -Desktop $desktop -WindowBounds $bounds
if ($point.X -ne 1021 -or $point.Y -ne 2) {
    throw 'Application smoke cursor selection does not skip an occupied desktop corner.'
}
$noOutsidePointRejected = $false
try { Get-SmokeCaptureCursorPoint -Desktop $desktop -WindowBounds $desktop | Out-Null }
catch { $noOutsidePointRejected = $true }
if (-not $noOutsidePointRejected) { throw 'Application smoke allows a cursor over a full-desktop window.' }

# Capture focus must skip headings, clipped controls and disabled actions.
$script:focusedCaptureControl = $null
function Find-SmokeElement {
    param([string]$AutomationId)
    $element = [pscustomobject]@{
        Current = [pscustomobject]@{
            IsOffscreen = $AutomationId -eq 'Hidden'
            IsEnabled = $AutomationId -ne 'Disabled'
            IsKeyboardFocusable = $AutomationId -ne 'Heading'
            AutomationId = $AutomationId
        }
    }
    $element | Add-Member -MemberType ScriptMethod -Name SetFocus -Value {
        $script:focusedCaptureControl = $this.Current.AutomationId
    }
    return $element
}
$focused = Set-SmokeCaptureFocus -AutomationIds @('Heading', 'Hidden', 'Disabled', 'Action')
if ($focused -ne 'Action' -or $script:focusedCaptureControl -ne 'Action') {
    throw 'Application smoke failed to focus a visible enabled page action.'
}
$noFocusTargetRejected = $false
try { Set-SmokeCaptureFocus -AutomationIds @('Heading', 'Hidden', 'Disabled') | Out-Null }
catch { $noFocusTargetRejected = $true }
if (-not $noFocusTargetRejected) { throw 'Application smoke accepts capture without a safe focus target.' }

# Model a page entering from outside the window and moving before it settles.
$script:captureProbeCalls = 0
function Find-SmokeElement {
    param([string]$AutomationId)
    $script:captureProbeCalls++
    $left = if ($script:captureProbeCalls -lt 5) { 950 }
        elseif ($script:captureProbeCalls -lt 7) { 130 }
        else { 120 }
    [pscustomobject]@{
        Current = [pscustomobject]@{
            IsOffscreen = $script:captureProbeCalls -lt 3
            BoundingRectangle = [pscustomobject]@{
                IsEmpty = $false; Left = $left; Top = 100; Right = $left + 40; Bottom = 130; Width = 40; Height = 30
            }
        }
    }
}
$bounds = [pscustomobject]@{ Left = 50; Top = 50; Right = 960; Bottom = 650 }
$settleStarted = [DateTime]::UtcNow
$elements = @(Wait-SmokeCaptureBounds -AutomationIds @('Heading', 'Action') -WindowBounds $bounds)
if ($elements.Count -ne 2 -or $elements[0].left -ne 120 -or $elements[1].left -ne 120 -or
    ([DateTime]::UtcNow - $settleStarted).TotalMilliseconds -lt 1500) {
    throw 'Application smoke capture did not wait for fully visible stable controls.'
}
Write-Host 'Application smoke capture geometry verification passed.'
Write-Host "Application smoke runtime type verification passed: $($checked.Count) types; Windows-only types deferred: $($deferred.Count)."
