param([switch]$NativeEtwFixture, [switch]$ReaderCatalogFixture)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# Compile the provider on its own, as the native ETW fixture does. The routing
# fixture's global usings must not mask a missing dependency in this source.
if ($NativeEtwFixture -and $ReaderCatalogFixture) { throw 'Select one trace fixture mode.' }
if (-not $ReaderCatalogFixture) {
    Add-Type -Path (Join-Path $PSScriptRoot '../src/Vex.Windows.Client/Auth/AuthActivationTrace.cs')
}
. (Join-Path $PSScriptRoot '../scripts/invoke-signed-install-acceptance.ps1') -FunctionsOnly
. (Join-Path $PSScriptRoot '../scripts/AuthActivationTrace.ps1')
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Event([int]$Stage, [bool]$Primary) {
    return [pscustomobject]@{ Stage = $Stage; Primary = $Primary }
}
$events = @((Event 1 $true), (Event 12 $true), (Event 22 $true), (Event 3 $false), (Event 4 $false))
$summary = Convert-WindowsAuthTraceEvents -Events $events
Check ($summary.stage_payload_only -and @($summary.primary_stages).Count -eq 3 -and @($summary.secondary_stages).Count -eq 2) 'Stage grouping changed.'
Check ('CallbackEntered' -cin $summary.primary_stages -and 'RedirectCompleted' -cin $summary.secondary_stages) 'Primary/secondary attribution changed.'
Check (($summary | ConvertTo-Json -Compress) -cnotmatch 'ProcessId|ProviderId|Properties|"10"|"11"') 'Raw event metadata escaped.'
$captureStages = @('ActivationCaptured', 'ActivationCaptureFailed', 'HandlerWrongThread', 'HandlerInvalidCast', 'HandlerOtherFault')
for ($index = 0; $index -lt $captureStages.Count; $index++) {
    $captureSummary = Convert-WindowsAuthTraceEvents -Events @((Event ($index + 28) $true))
    Check (@($captureSummary.primary_stages).Count -eq 1 -and $captureSummary.primary_stages[0] -ceq $captureStages[$index]) 'Capture diagnostics changed their append-only stage IDs.'
}
foreach ($bad in @(@((Event 0 $true)), @((Event 33 $true)), (@((Event 1 $true)) * 257),
    @([pscustomobject]@{ Primary = $true; Stage = 'private-value' }), @([pscustomobject]@{ Primary = $true; Stage = 1; Extra = 'private-value' }))) {
    $rejected = $false
    try { $null = Convert-WindowsAuthTraceEvents -Events $bad } catch { $rejected = $true }
    Check $rejected 'Invalid/unbounded stage data was accepted.'
}
$startup = Convert-WindowsStartupTraceEvents -Events @((Event 1 $true), (Event 13 $true), (Event 4 $false))
Check ($startup.schema -ceq 'vex.windows-startup-trace.v1' -and $startup.stage_payload_only -and
    'ProcessEntered' -cin $startup.primary_stages -and 'WindowActivated' -cin $startup.primary_stages -and
    @($startup.secondary_stages).Count -eq 1 -and $startup.secondary_stages[0] -ceq 'UiDispatcherEntered') 'Startup stage catalog or process grouping changed.'
Check (($startup | ConvertTo-Json -Compress) -cnotmatch 'ProcessId|ProviderId|Properties|private-value') 'Startup trace exposed raw metadata.'
foreach ($bad in @(@((Event 0 $true)), @((Event 14 $true)), @((Event 32 $true)), (@((Event 1 $true)) * 257),
    @([pscustomobject]@{ Primary = $true; Stage = 'private-value' }), @([pscustomobject]@{ Primary = $true; Stage = 1; Extra = 'private-value' }))) {
    $rejected = $false
    try { $null = Convert-WindowsStartupTraceEvents -Events $bad } catch { $rejected = $true }
    Check $rejected 'Invalid/unbounded startup stage data was accepted.'
}
Check (@(Get-WindowsTraceStageNames).Count -eq 32 -and @(Get-WindowsTraceStageNames -Startup).Count -eq 13) 'Stage catalogs lost legacy compatibility or mixed event families.'
if ($NativeEtwFixture) {
    # Explicit disposable x64 runner only; no installed app, account, VPN or
    # signing credentials. Qualify the real OS consumer before production QA.
    Assert-AcceptanceRunner $true
    $trace = Start-WindowsAuthTrace -DisposableRunner
    try {
        [Vex.Windows.Client.Auth.AuthActivationTrace]::Record([Vex.Windows.Client.Auth.AuthActivationStage]::ProcessStarted)
        [Vex.Windows.Client.Auth.AuthActivationTrace]::Record([Vex.Windows.Client.Auth.AuthActivationStage]::AuthSucceeded)
        [Vex.Windows.Client.Auth.AuthActivationTrace]::Record([Vex.Windows.Client.Auth.AuthActivationStage]::ActivationCaptured)
    } finally { $native = Stop-WindowsAuthTrace -State $trace -PrimaryProcessId $PID }
    Check ('ProcessStarted' -cin $native.primary_stages -and 'AuthSucceeded' -cin $native.primary_stages -and 'ActivationCaptured' -cin $native.primary_stages) 'Native ETW did not decode the actual numeric provider payload.'
    Check (-not (Test-Path -LiteralPath $trace.Directory)) 'Owned native trace files remained.'
    $trace = Start-WindowsAuthTrace -DisposableRunner
    try {
        [Vex.Windows.Client.Auth.AuthActivationTrace]::RecordStartup([Vex.Windows.Client.Auth.AppStartupStage]::ProcessEntered)
        [Vex.Windows.Client.Auth.AuthActivationTrace]::RecordStartup([Vex.Windows.Client.Auth.AppStartupStage]::WindowActivated)
        [Vex.Windows.Client.Auth.AuthActivationTrace]::Record([Vex.Windows.Client.Auth.AuthActivationStage]::AuthSucceeded)
    } finally { $native = Stop-WindowsAuthTrace -State $trace -PrimaryProcessId $PID -Startup }
    Check ('ProcessEntered' -cin $native.primary_stages -and 'WindowActivated' -cin $native.primary_stages -and
        'AuthSucceeded' -cnotin $native.primary_stages) 'Native ETW mixed startup and legacy auth payloads.'
    Check (-not (Test-Path -LiteralPath $trace.Directory)) 'Owned startup trace files remained.'
    Write-Host 'PASS native bounded ETW capture, stage decoding and owned cleanup; authentication was not attempted.'
}
Write-Host 'PASS auth/startup trace allowlists, payload privacy, process grouping and fixed event budgets.'
