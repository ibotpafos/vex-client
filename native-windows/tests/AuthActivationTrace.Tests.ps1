param([switch]$NativeEtwFixture)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
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
foreach ($bad in @(@((Event 0 $true)), @((Event 28 $true)), (@((Event 1 $true)) * 257),
    @([pscustomobject]@{ Primary = $true; Stage = 'private-value' }), @([pscustomobject]@{ Primary = $true; Stage = 1; Extra = 'private-value' }))) {
    $rejected = $false
    try { $null = Convert-WindowsAuthTraceEvents -Events $bad } catch { $rejected = $true }
    Check $rejected 'Invalid/unbounded stage data was accepted.'
}
if ($NativeEtwFixture) {
    # Explicit disposable x64 runner only; no installed app, account, VPN or
    # signing credentials. Qualify the real OS consumer before production QA.
    Assert-AcceptanceRunner $true
    Add-Type -Path (Join-Path $PSScriptRoot '../src/Vex.Windows.Client/Auth/AuthActivationTrace.cs')
    $trace = Start-WindowsAuthTrace -DisposableRunner
    try {
        [Vex.Windows.Client.Auth.AuthActivationTrace]::Record([Vex.Windows.Client.Auth.AuthActivationStage]::ProcessStarted)
        [Vex.Windows.Client.Auth.AuthActivationTrace]::Record([Vex.Windows.Client.Auth.AuthActivationStage]::AuthSucceeded)
    } finally { $native = Stop-WindowsAuthTrace -State $trace -PrimaryProcessId $PID }
    Check ('ProcessStarted' -cin $native.primary_stages -and 'AuthSucceeded' -cin $native.primary_stages) 'Native ETW did not decode the actual numeric provider payload.'
    Check (-not (Test-Path -LiteralPath $trace.Directory)) 'Owned native trace files remained.'
    Write-Host 'PASS native bounded ETW capture, stage decoding and owned cleanup; authentication was not attempted.'
}
Write-Host 'PASS auth trace allowlist, payload privacy, process grouping and fixed event budget.'
