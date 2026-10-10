[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ApplicationPath,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [ValidateRange(3, 30)][int]$ObserveSeconds = 10
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $IsWindows) {
    throw 'WinUI application startup smoke requires Windows.'
}
if (-not (Test-Path -LiteralPath $ApplicationPath -PathType Leaf)) {
    throw 'Published WinUI application is missing.'
}
$ApplicationPath = (Resolve-Path -LiteralPath $ApplicationPath).ProviderPath
# This check is for a clean hosted build machine, not an installed VPN user.
if (Get-Service -Name 'VEX VPN Service', 'AmneziaWGTunnel$vex' -ErrorAction SilentlyContinue) {
    throw 'Startup smoke requires a host without an installed VEX VPN service.'
}
if (Get-Process -Name 'Vex.Windows.App' -ErrorAction SilentlyContinue) {
    throw 'Startup smoke requires a host without a running VEX application.'
}
$sessionPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'VEX/VPN/client-state.bin'
if (Test-Path -LiteralPath $sessionPath) {
    throw 'Startup smoke requires a fresh profile without a saved VEX session.'
}

$startedAt = [DateTime]::UtcNow
$process = $null
$result = [ordered]@{
    schema = 'vex.windows-startup-smoke.v1'
    started_at_utc = $startedAt.ToString('O')
    observation_seconds = $ObserveSeconds
    process_id = $null
    alive_at_deadline = $false
    main_window_created = $false
    exit_code = $null
    failure_type = $null
    crash_events = @()
}
try {
    $process = Start-Process -FilePath $ApplicationPath `
        -WorkingDirectory (Split-Path -Parent $ApplicationPath) -PassThru
    $result.process_id = $process.Id
    $deadline = $startedAt.AddSeconds($ObserveSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $process.Refresh()
        if ($process.HasExited) {
            $result.exit_code = $process.ExitCode
            throw 'Published WinUI application exited during startup.'
        }
        if ($process.MainWindowHandle -ne 0) {
            $result.main_window_created = $true
        }
        Start-Sleep -Milliseconds 250
    }
    $process.Refresh()
    if ($process.HasExited) {
        $result.exit_code = $process.ExitCode
        throw 'Published WinUI application exited before the observation deadline.'
    }
    $result.alive_at_deadline = $true
    Write-Host "WinUI application remained alive for $ObserveSeconds seconds."
    Write-Host "WinUI main window created: $($result.main_window_created)."
}
catch {
    $result.failure_type = $_.Exception.GetType().FullName
    throw
}
finally {
    if ($null -ne $process) {
        $process.Refresh()
        if (-not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            [void]$process.WaitForExit(5000)
        }
    }
    # Store only selected event identifiers and fault module/code fields.
    # Raw event messages, stdout, account state and process dumps are excluded.
    $result.crash_events = @(
        Get-WinEvent -FilterHashtable @{
            LogName = 'Application'
            StartTime = $startedAt.ToLocalTime()
            Id = @(1000, 1001, 1026)
        } -ErrorAction SilentlyContinue |
            Where-Object { $_.Message -like '*Vex.Windows.App.exe*' } |
            Select-Object -First 5 |
            ForEach-Object {
                $event = $_
                [xml]$xml = $event.ToXml()
                $fields = [ordered]@{}
                foreach ($data in @($xml.SelectNodes('//*[local-name()="EventData"]/*[local-name()="Data"]'))) {
                    if ($data.GetAttribute('Name') -in @('AppName', 'ModuleName', 'ExceptionCode')) {
                        $fields[$data.GetAttribute('Name')] = $data.InnerText
                    }
                }
                [ordered]@{
                    event_id = $event.Id
                    provider = $event.ProviderName
                    time_utc = $event.TimeCreated.ToUniversalTime().ToString('O')
                    fields = $fields
                }
            }
    )
    $directory = Split-Path -Parent $ResultPath
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ResultPath -Encoding utf8
}
