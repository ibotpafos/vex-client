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
foreach ($functionName in @('Wait-SmokeCondition', 'Wait-SmokeCaptureBounds', 'Get-SmokeCaptureCursorPoint', 'Set-SmokeCaptureFocus', 'Assert-SmokeTrayRecoveryDiagnostic', 'Assert-SmokeProtectedStateDiagnostic')) {
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
