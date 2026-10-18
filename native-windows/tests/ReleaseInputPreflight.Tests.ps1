$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$scriptPath = Join-Path $root 'native-windows/scripts/test-release-inputs.ps1'
$source = [IO.File]::ReadAllText($scriptPath)
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw 'Preflight source does not parse.' }
foreach ($name in @('Get-ReleaseRequiredInputNames', 'Get-ReleasePresenceInputNames',
    'Get-ReleaseInputPresenceReport', 'Get-ReleasePreflightCheckoutCommit', 'Write-ReleaseInputPreflightReceipt')) {
    $definitions = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
    }, $true))
    if ($definitions.Count -ne 1) { throw 'Preflight exact production function is missing.' }
    . ([scriptblock]::Create($definitions[0].Extent.Text))
}
$required = @(Get-ReleaseRequiredInputNames)
$contract = @()
foreach ($path in @('native-windows/packaging/package-native-windows.ps1', 'native-windows/packaging/publish-native-windows.ps1')) {
    $contract += @([regex]::Matches([IO.File]::ReadAllText((Join-Path $root $path)), "Get-RequiredEnv '([^']+)'") |
        ForEach-Object { $_.Groups[1].Value })
}
$contract = @($contract | Where-Object { $_ -cnotin @('VEX_WINDOWS_MANIFEST_REVISION', 'VEX_WINDOWS_RELEASE_NOTES') } | Sort-Object -Unique)
if (($required | Sort-Object) -join ',' -cne ($contract -join ',')) { throw 'Persistent release input membership differs from actual package/publisher contracts.' }
$allNames = @(Get-ReleasePresenceInputNames)
$workflow = [IO.File]::ReadAllText((Join-Path $root '.github/workflows/native-windows-release-preflight.yml'))
$secrets = @('VEX_WINDOWS_SIGN_PFX_BASE64', 'VEX_WINDOWS_SIGN_PFX_PASSWORD',
    'VEX_WINDOWS_UPDATE_PUBLIC_KEY_BASE64', 'VEX_WINDOWS_UPDATE_PRIVATE_KEY_BASE64')
function Assert-ReleasePreflightWorkflowContract {
    param([Parameter(Mandatory = $true)][string]$Workflow,
        [Parameter(Mandatory = $true)][string[]]$Names)
    $bindings = @([regex]::Matches($Workflow,
        '(?m)^          (VEX_WINDOWS_[A-Z0-9_]+)_PRESENT: \$\{\{ (vars|secrets)\.(VEX_WINDOWS_[A-Z0-9_]+) != '''' \}\}\r?$'))
    if ($bindings.Count -ne $Names.Count) { throw 'Workflow presence bindings are incomplete or include actual values.' }
    foreach ($binding in $bindings) {
        $name = $binding.Groups[1].Value
        $context = if ($name -cin $secrets) { 'secrets' } else { 'vars' }
        if ($name -cnotin $Names -or $binding.Groups[3].Value -cne $name -or $binding.Groups[2].Value -cne $context) {
            throw 'Workflow input provenance or boolean mapping is invalid.'
        }
    }
    if (@($bindings | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique).Count -ne $Names.Count -or
        @([regex]::Matches($Workflow, '\$\{\{ (vars|secrets)\.')).Count -ne $Names.Count -or
        $Workflow -notmatch "(?s)on:\s+workflow_dispatch:\s+permissions:\s+contents: read" -or
        $Workflow -notmatch "github.event_name == 'workflow_dispatch' &&\s+github.ref == 'refs/heads/main' &&\s+github.repository == 'ibotpafos/vex-client'" -or
        $Workflow -match '(?m)^  (push|pull_request|pull_request_target|workflow_call):' -or
        $Workflow -match '(?m)^\s+(package_release|release_version|manifest_revision|release_notes|environment):' -or
        $Workflow -notmatch 'persist-credentials: false' -or $Workflow -notmatch 'if: always\(\)') {
        throw 'Manual main-only permission, no-value or artifact-retention gate changed.'
    }
}

# Exercise the same exact matcher against both Git checkout line-ending forms.
# The validator itself does not normalize input, so CRLF must actually match.
$lfWorkflow = $workflow.Replace("`r`n", "`n")
$crlfWorkflow = $lfWorkflow.Replace("`n", "`r`n")
if ($lfWorkflow.Contains("`r") -or -not $crlfWorkflow.Contains("`r`n")) {
    throw 'Workflow line-ending regression fixtures are not distinct LF and CRLF.'
}
$historicalLfOnlyMatcher = '(?m)^          (VEX_WINDOWS_[A-Z0-9_]+)_PRESENT: \$\{\{ (vars|secrets)\.(VEX_WINDOWS_[A-Z0-9_]+) != '''' \}\}$'
if ([regex]::Matches($lfWorkflow, $historicalLfOnlyMatcher).Count -ne $allNames.Count -or
    [regex]::Matches($crlfWorkflow, $historicalLfOnlyMatcher).Count -ne 0) {
    throw 'Historical LF-only matcher did not reproduce the original CRLF failure.'
}
Write-Output ("Historical LF-only matcher reproduced {0} LF matches and zero CRLF matches." -f $allNames.Count)
foreach ($variant in @($lfWorkflow, $crlfWorkflow)) {
    Assert-ReleasePreflightWorkflowContract -Workflow $variant -Names $allNames
    foreach ($invalid in @(
        $variant.Replace('${{ secrets.VEX_WINDOWS_SIGN_PFX_BASE64 != '''' }}', '${{ secrets.VEX_WINDOWS_SIGN_PFX_BASE64 }}'),
        $variant.Replace('${{ secrets.VEX_WINDOWS_SIGN_PFX_BASE64 != '''' }}', '${{ vars.VEX_WINDOWS_SIGN_PFX_BASE64 != '''' }}'),
        $variant.Replace('VEX_WINDOWS_SIGN_PFX_BASE64_PRESENT:', 'VEX_WINDOWS_UNKNOWN_PRESENT:')
    )) {
        if ($invalid -ceq $variant) { throw 'Workflow negative binding fixture did not change the source.' }
        $rejected = $false
        try { Assert-ReleasePreflightWorkflowContract -Workflow $invalid -Names $allNames } catch { $rejected = $true }
        if (-not $rejected) { throw 'Workflow line-ending support accepted raw values, wrong provenance or unknown binding names.' }
    }
}
Write-Output ("Exact {0} boolean workflow bindings passed LF and CRLF; six raw-value/provenance/name controls rejected." -f $allNames.Count)

$presence = @{}
foreach ($name in $allNames) { $presence[$name] = $false }
foreach ($name in $required) { $presence[$name] = $true }
foreach ($architecture in @('X64', 'ARM64')) {
    foreach ($asset in @('AMNEZIAWG', 'WINTUN')) {
        $presence["VEX_WINDOWS_SERVICE_$($asset)_URI_$architecture"] = $true
        $presence["VEX_WINDOWS_SERVICE_$($asset)_SHA256_$architecture"] = $true
    }
}
$positive = Get-ReleaseInputPresenceReport -Presence $presence
if (-not $positive.configured_inputs_ready -or @($positive.missing_inputs).Count -ne 0 -or
    @($positive.runtime_sources | Where-Object { -not $_.vclibs_builtin_source }).Count -ne 0) {
    throw 'Required persistent inputs and built-in Microsoft VCLibs source did not pass presence.'
}
$msiPresence = $presence.Clone()
foreach ($architecture in @('X64', 'ARM64')) {
    foreach ($asset in @('AMNEZIAWG', 'WINTUN')) {
        $msiPresence["VEX_WINDOWS_SERVICE_$($asset)_URI_$architecture"] = $false
        $msiPresence["VEX_WINDOWS_SERVICE_$($asset)_SHA256_$architecture"] = $false
    }
}
if ((Get-ReleaseInputPresenceReport -Presence $msiPresence).configured_inputs_ready) { throw 'MSI fallback cannot be implicit.' }
$msiPresence['VEX_WINDOWS_SERVICE_MSI_SOURCE'] = $true
if (-not (Get-ReleaseInputPresenceReport -Presence $msiPresence).configured_inputs_ready) { throw 'Explicit qualified MSI pair must provide both runtime architectures.' }
$msiPresence['VEX_WINDOWS_SERVICE_AMNEZIAWG_URI_X64'] = $true
if ((Get-ReleaseInputPresenceReport -Presence $msiPresence).configured_inputs_ready) { throw 'MSI fallback cannot bypass a custom PE URI missing its hash.' }
foreach ($name in $required) {
    $copy = $presence.Clone(); $copy[$name] = $false
    $negative = Get-ReleaseInputPresenceReport -Presence $copy
    if ($negative.configured_inputs_ready -or @($negative.missing_inputs).Count -ne 1 -or $negative.missing_inputs[0] -cne $name) {
        throw 'Missing required input was not rejected with its constant name.'
    }
}
foreach ($architecture in @('X64', 'ARM64')) {
    foreach ($asset in @('AMNEZIAWG', 'WINTUN')) {
        $prefix = "VEX_WINDOWS_SERVICE_$asset"
        $copy = $presence.Clone(); $copy["$($prefix)_PATH_$architecture"] = $true
        $copy["$($prefix)_SHA256_$architecture"] = $false
        $negative = Get-ReleaseInputPresenceReport -Presence $copy
        if ($negative.configured_inputs_ready -or "$($prefix)_SHA256_$architecture" -cnotin $negative.missing_inputs) {
            throw 'A path incorrectly bypassed a configured URI without its hash.'
        }
        $copy["$($prefix)_URI_$architecture"] = $false
        if (-not (Get-ReleaseInputPresenceReport -Presence $copy).configured_inputs_ready) { throw 'Specific local path fallback was rejected.' }
        $copy["$($prefix)_PATH_$architecture"] = $false; $copy["$($prefix)_PATH"] = $true
        if (-not (Get-ReleaseInputPresenceReport -Presence $copy).configured_inputs_ready) { throw 'Legacy local path fallback was rejected.' }
        $copy["$($prefix)_PATH"] = $false
        if ((Get-ReleaseInputPresenceReport -Presence $copy).configured_inputs_ready) { throw 'Absent runtime sources were accepted.' }
    }
    $copy = $presence.Clone(); $copy["VEX_WINDOWS_VCLIBS_URI_$architecture"] = $true
    if ((Get-ReleaseInputPresenceReport -Presence $copy).configured_inputs_ready) { throw 'A custom VCLibs URI without hash was accepted.' }
    $copy["VEX_WINDOWS_VCLIBS_PATH_$architecture"] = $true
    if (-not (Get-ReleaseInputPresenceReport -Presence $copy).configured_inputs_ready) { throw 'VCLibs path did not take priority over its custom URI.' }
    $copy["VEX_WINDOWS_VCLIBS_PATH_$architecture"] = $false; $copy['VEX_WINDOWS_VCLIBS_PATH'] = $true
    if (-not (Get-ReleaseInputPresenceReport -Presence $copy).configured_inputs_ready) { throw 'VCLibs legacy path priority changed.' }
    $copy['VEX_WINDOWS_VCLIBS_PATH'] = $false; $copy["VEX_WINDOWS_VCLIBS_SHA256_$architecture"] = $true
    if (-not (Get-ReleaseInputPresenceReport -Presence $copy).configured_inputs_ready) { throw 'Custom VCLibs URI with hash presence was rejected.' }
}
foreach ($invalid in @('true ', 'TRUE', 'false ', '1', 1, $null, 'PRIVATE_MARKER_DO_NOT_DISCLOSE')) {
    $copy = $presence.Clone(); $copy[$required[0]] = $invalid
    $negative = Get-ReleaseInputPresenceReport -Presence $copy
    if ($negative.configured_inputs_ready -or $required[0] -cnotin $negative.invalid_presence_bindings -or
        ($negative | ConvertTo-Json -Depth 6) -match 'PRIVATE_MARKER_DO_NOT_DISCLOSE') { throw 'Malformed presence binding failed closed without value disclosure.' }
}
$copy = $presence.Clone(); $copy['UNRECOGNIZED_MARKER_INPUT'] = 'PRIVATE_MARKER_DO_NOT_DISCLOSE'
if ((Get-ReleaseInputPresenceReport -Presence $copy | ConvertTo-Json -Depth 6) -match 'PRIVATE_MARKER_DO_NOT_DISCLOSE') {
    throw 'Unrecognized environment content was disclosed.'
}
Write-Output 'Release input exact contract, main-only boolean bindings and runtime precedence tests passed.'

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('vex-release-input-test-' + [Guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($temporary)
try {
    $resultPath = Join-Path $temporary 'missing.json'
    $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })))
    $start.UseShellExecute = $false; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    foreach ($argument in @('-NoProfile', '-File', $scriptPath, '-ResultPath', $resultPath)) { $start.ArgumentList.Add($argument) }
    foreach ($name in $allNames) { $start.Environment["$($name)_PRESENT"] = 'false' }
    foreach ($name in $secrets) { $start.Environment[$name] = 'PRIVATE_MARKER_DO_NOT_DISCLOSE' }
    $process = [Diagnostics.Process]::Start($start)
    try {
        if (-not $process.WaitForExit(10000)) { $process.Kill($true); throw 'Actual preflight subprocess exceeded its bound.' }
        $output = $process.StandardOutput.ReadToEnd() + $process.StandardError.ReadToEnd()
        if ($process.ExitCode -eq 0 -or $output -match 'PRIVATE_MARKER_DO_NOT_DISCLOSE') { throw 'Actual missing-input process did not fail safely.' }
    }
    finally { $process.Dispose() }
    $json = [IO.File]::ReadAllText($resultPath)
    $result = $json | ConvertFrom-Json
    $expectedCommit = Get-ReleasePreflightCheckoutCommit -RepositoryRoot $root
    if ($json -match 'PRIVATE_MARKER_DO_NOT_DISCLOSE' -or [IO.FileInfo]::new($resultPath).Length -gt 16384 -or
        $result.schema -cne 'vex.windows-release-input-preflight.v1' -or $result.source_commit -cne $expectedCommit -or
        $result.configured_inputs_ready -or -not $result.presence_only -or $result.values_disclosed -or
        $result.signing_verified -or $result.public_vpn_verified -or $result.installed_lifecycle_verified -or
        $result.runtime_uri_and_hash_format_verified -or $result.runtime_files_and_architecture_verified -or
        @($result.missing_inputs | Where-Object { $_ -cnotin $allNames }).Count -ne 0) {
        throw 'Actual bounded missing receipt has an invalid commit, claim or disclosed value.'
    }
    $positivePath = Join-Path $temporary 'configured.json'
    $start.ArgumentList[$start.ArgumentList.Count - 1] = $positivePath
    foreach ($name in $allNames) { $start.Environment["$($name)_PRESENT"] = $(if ($presence[$name]) { 'true' } else { 'false' }) }
    $process = [Diagnostics.Process]::Start($start)
    try {
        if (-not $process.WaitForExit(10000)) { $process.Kill($true); throw 'Configured preflight subprocess exceeded its bound.' }
        $output = $process.StandardOutput.ReadToEnd() + $process.StandardError.ReadToEnd()
        if ($process.ExitCode -ne 0 -or $output -match 'PRIVATE_MARKER_DO_NOT_DISCLOSE') { throw 'Configured presence did not pass without value disclosure.' }
    }
    finally { $process.Dispose() }
    $positiveJson = [IO.File]::ReadAllText($positivePath)
    $positiveResult = $positiveJson | ConvertFrom-Json
    if (-not $positiveResult.configured_inputs_ready -or $positiveResult.source_commit -cne $expectedCommit -or
        $positiveResult.values_disclosed -or $positiveResult.signing_verified -or $positiveResult.public_vpn_verified -or
        $positiveResult.installed_lifecycle_verified -or $positiveResult.runtime_uri_and_hash_format_verified -or
        $positiveResult.runtime_files_and_architecture_verified -or $positiveJson -match 'PRIVATE_MARKER_DO_NOT_DISCLOSE') {
        throw 'Configured presence falsely claimed content, signing or Windows qualification.'
    }
    $before = [IO.File]::ReadAllBytes($resultPath)
    $rejected = $false
    try { Write-ReleaseInputPreflightReceipt -Path $resultPath -Report @{ invalid = $true } } catch { $rejected = $true }
    if (-not $rejected -or [Convert]::ToBase64String([IO.File]::ReadAllBytes($resultPath)) -cne [Convert]::ToBase64String($before)) {
        throw 'Preflight overwrote an existing receipt.'
    }
    $rejected = $false
    try { Write-ReleaseInputPreflightReceipt -Path (Join-Path $temporary 'oversized.json') -Report @{ invalid = ('x' * 16384) } } catch { $rejected = $true }
    if (-not $rejected) { throw 'Preflight wrote an unbounded receipt.' }
    Write-Output 'Actual missing/configured subprocesses retained bounded checkout-bound evidence without values or qualification claims.'
}
finally { [IO.Directory]::Delete($temporary, $true) }
