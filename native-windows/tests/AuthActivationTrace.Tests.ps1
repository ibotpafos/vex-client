param([switch]$NativeEtwFixture)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../scripts/invoke-signed-install-acceptance.ps1') -FunctionsOnly
. (Join-Path $PSScriptRoot '../scripts/AuthActivationTrace.ps1')
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Event([int]$Stage, [int]$ProcessId, [Guid]$Provider = $script:AuthTraceProvider) {
    return [pscustomobject]@{ ProviderId = $Provider; ProcessId = $ProcessId; Properties = @([pscustomobject]@{ Value = $Stage }) }
}
$events = @((Event 1 10), (Event 12 10), (Event 22 10), (Event 3 11), (Event 4 11), (Event 1 10 ([Guid]::Empty)))
$summary = Convert-WindowsAuthTraceEvents -Events $events -PrimaryProcessId 10
Check ($summary.stage_payload_only -and @($summary.primary_stages).Count -eq 3 -and @($summary.secondary_stages).Count -eq 2) 'Stage grouping changed.'
Check ('CallbackEntered' -cin $summary.primary_stages -and 'RedirectCompleted' -cin $summary.secondary_stages) 'Primary/secondary attribution changed.'
Check (($summary | ConvertTo-Json -Compress) -cnotmatch 'ProcessId|ProviderId|Properties|"10"|"11"') 'Raw event metadata escaped.'
foreach ($bad in @(@((Event 0 10)), @((Event 28 10)), (@((Event 1 10)) * 257),
    @([pscustomobject]@{ ProviderId = $script:AuthTraceProvider; ProcessId = 10; Properties = @([pscustomobject]@{ Value = 'private-value' }) }))) {
    $rejected = $false
    try { $null = Convert-WindowsAuthTraceEvents -Events $bad -PrimaryProcessId 10 } catch { $rejected = $true }
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
