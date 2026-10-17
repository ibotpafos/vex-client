#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][switch]$DisposableRunner,
    [Parameter(Mandatory = $true)][string]$ExecutablePath,
    [Parameter(Mandatory = $true)][string]$ResultPath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$explicitDisposable = [bool]$DisposableRunner
$destination = [IO.Path]::GetFullPath($ResultPath)
$image = [IO.Path]::GetFullPath($ExecutablePath)
. (Join-Path $PSScriptRoot 'invoke-signed-install-acceptance.ps1') -FunctionsOnly
Assert-AcceptanceRunner $explicitDisposable
Assert-AcceptanceFreshHost 'VEX.Native.Windows'
$null = Assert-AcceptanceRegularPath $image
if (-not $image.StartsWith(([IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase) -or
    -not $destination.StartsWith(([IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Unsigned Setup UI checks must stay inside this disposable runner temporary folder.'
}
if ((Get-AuthenticodeSignature -LiteralPath $image).Status -eq 'Valid' -or
    (Get-Item -LiteralPath $image).VersionInfo.ProductVersion -match '[+]metadata[.]') {
    throw 'This non-installing smoke check accepts only the unsigned review launcher.'
}
$hash = (Get-FileHash -LiteralPath $image -Algorithm SHA256).Hash
$null = New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force
$null = Assert-AcceptanceRegularPath -Path (Split-Path -Parent $destination) -Directory
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$started = [DateTime]::UtcNow
$owned = $null
$receipt = [ordered]@{ schema = 'vex.windows-unsigned-setup-ui.v1'; passed = $false; stage = 'launch'; window_found = $false;
    disabled_install_verified = $false; installation_performed = $false; native_exit_code = $null; exception_type = $null;
    managed_crash_types = @(); cleanup_confirmed = $false }
try {
    $owned = Start-Process -FilePath $image -WorkingDirectory (Split-Path -Parent $image) -PassThru
    $receipt.stage = 'locate_controls'
    $until = [DateTime]::UtcNow.AddSeconds(35)
    do {
        $owned.Refresh()
        if ($owned.HasExited) { $receipt.native_exit_code = $owned.ExitCode; throw 'Unsigned Setup exited before its window was verified.' }
        if ($owned.MainModule.FileName -ine $image -or (Get-FileHash -LiteralPath $image).Hash -cne $hash) { throw 'Unexpected unsigned Setup image.' }
        if ($owned.MainWindowHandle -ne [IntPtr]::Zero) {
            try {
                $window = [Windows.Automation.AutomationElement]::FromHandle($owned.MainWindowHandle)
                $ready = $window.Current.AutomationId -ceq 'VexSetupWindow' -or $window.Current.Name -ceq 'VexSetupWindow'
                $disabled = $true
                foreach ($id in @('SetupInstallButton', 'SetupRepairButton', 'SetupUninstallButton', 'SetupVerifyButton', 'SetupStatusText')) {
                    $element = $window.FindFirst([Windows.Automation.TreeScope]::Descendants,
                        [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty, $id))
                    if ($null -eq $element -or $element.Current.IsOffscreen) { $ready = $false; continue }
                    if ($id -in @('SetupInstallButton', 'SetupRepairButton', 'SetupUninstallButton') -and $element.Current.IsEnabled) { $disabled = $false }
                    if ($id -ceq 'SetupVerifyButton' -and -not $element.Current.IsEnabled) { $ready = $false }
                }
                if ($ready -and $disabled) { $receipt.window_found = $true; $receipt.disabled_install_verified = $true; break }
            } catch [Windows.Automation.ElementNotAvailableException] { }
        }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $until)
    if (-not $receipt.window_found) { throw 'The unsigned Setup window or disabled installation controls were not verified.' }
    $receipt.stage = 'completed'
} catch {
    $receipt.exception_type = $_.Exception.GetType().Name
    # Inspect only this freshly launched executable's managed crash. Never
    # upload event text, paths, stack traces or arbitrary exception messages.
    try {
        $baseName = [IO.Path]::GetFileName($image)
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1026; StartTime = $started } -MaxEvents 10 -ErrorAction Stop)
        $types = @()
        foreach ($event in $events) {
            if (-not $event.Message.Contains($baseName, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $types += [regex]::Matches($event.Message, '\bSystem[.][A-Za-z0-9.]{1,100}Exception\b') | ForEach-Object Value
        }
        $receipt.managed_crash_types = @($types | Select-Object -Unique -First 3)
    } catch { }
} finally {
    if ($null -ne $owned) {
        try {
            if (-not $owned.HasExited) {
                if ($owned.MainModule.FileName -ine $image -or (Get-FileHash -LiteralPath $image).Hash -cne $hash) { throw 'Unsigned Setup cleanup identity changed.' }
                [void]$owned.CloseMainWindow()
                if (-not $owned.WaitForExit(5000)) { $owned.Kill(); [void]$owned.WaitForExit(5000) }
            }
            $receipt.cleanup_confirmed = $owned.HasExited
        } catch { $receipt.exception_type = 'OwnedCleanupFailed' }
        finally { $owned.Dispose() }
    }
    $receipt.passed = $receipt.window_found -and $receipt.disabled_install_verified -and $receipt.cleanup_confirmed
    [IO.File]::WriteAllText($destination, ($receipt | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
}
if (-not $receipt.passed) { throw 'Unsigned Setup window check failed; inspect its sanitized receipt.' }
Write-Output 'Unsigned Setup window verified with installation disabled.'
