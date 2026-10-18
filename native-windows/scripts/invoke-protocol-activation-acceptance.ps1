#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][switch]$DisposableRunner,
    [Parameter(Mandatory = $true)][string]$BundleDirectory,
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-f0-9]{40}$')][string]$ReleaseSourceCommit,
    [Parameter(Mandatory = $true)][ValidateRange(1, 9007199254740991)][long]$ReleaseRunId,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')][string]$ReleaseVersion,
    [Parameter(Mandatory = $true)][string]$ResultDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$explicitDisposable = [bool]$DisposableRunner
. (Join-Path $PSScriptRoot 'invoke-signed-install-acceptance.ps1') -FunctionsOnly
Assert-AcceptanceRunner $explicitDisposable
if ($env:GITHUB_EVENT_NAME -cne 'workflow_dispatch' -or $env:GITHUB_REF -cne 'refs/heads/main' -or
    $env:GITHUB_REPOSITORY -cne 'ibotpafos/vex-client' -or $env:VEX_WINDOWS_PROTOCOL_PROBE -cne '1') {
    throw 'Protocol acceptance requires its explicit protected disposable workflow.'
}
foreach ($name in @('VEX_WINDOWS_TESTER_QA', 'VEX_WINDOWS_SIGN_PFX_BASE64', 'VEX_WINDOWS_SIGN_PFX_PASSWORD',
    'VEX_WINDOWS_UPDATE_PRIVATE_KEY_BASE64', 'VEX_MCP_SERVICE_CLIENT_SECRET', 'VEX_MCP_ADMIN_TOKEN')) {
    if (-not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($name))) {
        throw 'The signed-out protocol probe must not inherit identity or signing credentials.'
    }
}
$bundle = Read-AcceptanceBundle $BundleDirectory
if ($bundle.Metadata.channel -cne 'beta' -or $bundle.Metadata.signing_mode -cne 'tester-ca' -or
    $bundle.Metadata.source_commit -cne $ReleaseSourceCommit -or $bundle.Metadata.version -cne $ReleaseVersion -or $bundle.Metadata.architecture -cne 'x64' -or
    $bundle.Metadata.client_certificate_sha256 -ine $env:VEX_WINDOWS_TEST_CERT_SHA256 -or
    $bundle.Metadata.tester_root_sha256 -ine $env:VEX_WINDOWS_TEST_ROOT_SHA256) {
    throw 'Protocol acceptance requires the admitted signed x64 beta and its pinned authority.'
}
Assert-AcceptanceFreshHost $bundle.Metadata.package_name
$ResultDirectory = [IO.Path]::GetFullPath($ResultDirectory)
if (-not $ResultDirectory.StartsWith(([IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Protocol observations must remain inside the disposable runner.'
}
New-Item -ItemType Directory -Path $ResultDirectory -Force | Out-Null
$null = Assert-AcceptanceRegularPath -Path $ResultDirectory -Directory
$ownerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$evidence = [ordered]@{
    schema = 'vex.windows-protocol-activation-acceptance.v1'; source_commit = $ReleaseSourceCommit
    workflow_commit = $env:GITHUB_SHA; release_run_id = $ReleaseRunId; release_version = $bundle.Metadata.version
    passed = $false; production_qa_passed = $false; no_identity_credentials = $true; inert_callback_only = $true
    local_guard_rejection_observed = $false; cleanup_confirmed = $false; failure_type = $null
    cleanup_failure_type = $null; observation = $null; phases = [Collections.Generic.List[object]]::new()
}
$mutationStarted = $false; $owned = $null; $script:window = $null; $shared = @(); $failure = $null; $cleanupFailure = $null

function Wait-ProtocolProbe([scriptblock]$Condition, [int]$Seconds = 30) {
    $until = [DateTime]::UtcNow.AddSeconds($Seconds)
    do { if (& $Condition) { return }; Start-Sleep -Milliseconds 250 } while ([DateTime]::UtcNow -lt $until)
    throw 'The required signed-out protocol observation did not arrive.'
}
function Find-ProtocolProbeControl([string]$Id) {
    return $script:window.FindFirst([Windows.Automation.TreeScope]::Descendants,
        [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty, $Id))
}
function Test-ProtocolProbeRejection {
    $status = Find-ProtocolProbeControl 'AccountSignInStatus'
    return $null -ne $status -and -not $status.Current.IsOffscreen -and
        $status.Current.Name -ceq 'Сессия входа через сайт устарела. Запустите вход заново.'
}
function Get-ProtocolProbeObservation {
    # Fixed booleans only: no UI text, titles, process arguments, callback values,
    # registry contents, arbitrary desktop trees or exception messages leave CI.
    $processes = @(Get-Process -Name 'Vex.Windows.App' -ErrorAction SilentlyContinue)
    $observation = [ordered]@{
        primary_process_alive = $null -ne $owned -and -not $owned.HasExited
        single_app_process = $processes.Count -eq 1
        additional_app_process = $processes.Count -gt 1
        open_with_process_present = @(Get-Process -Name 'OpenWith' -ErrorAction SilentlyContinue).Count -gt 0
        protocol_user_choice_present = Test-Path -LiteralPath 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\vexguard\UserChoice'
        local_guard_rejection_observed = $false
        auth_status_present = $false
        auth_status_visible = $false
        signed_out_button_visible = $false
        browser_wait_visible = $false
        authenticated_button_visible = $false
        uia_readable = $false
    }
    try {
        $status = Find-ProtocolProbeControl 'AccountSignInStatus'
        $observation.auth_status_present = $null -ne $status
        $observation.auth_status_visible = $null -ne $status -and -not $status.Current.IsOffscreen
        $observation.local_guard_rejection_observed = Test-ProtocolProbeRejection
        foreach ($pair in @(@('WebsiteSignInButton', 'signed_out_button_visible'),
            @('CancelWebsiteAuthButton', 'browser_wait_visible'), @('SignOutButton', 'authenticated_button_visible'))) {
            $control = Find-ProtocolProbeControl $pair[0]
            $observation[$pair[1]] = $null -ne $control -and -not $control.Current.IsOffscreen
        }
        $observation.uia_readable = $true
    } catch [Windows.Automation.ElementNotAvailableException], [Runtime.InteropServices.COMException], [InvalidOperationException] { }
    return $observation
}
try {
    Add-AcceptancePhase 'install_exact_signed_beta' {
        $script:mutationStarted = $true
        Invoke-AcceptanceBootstrap $bundle Install
        Invoke-AcceptanceBootstrap $bundle Verify
        $script:shared = @(Get-AcceptanceSharedDependencies)
    } $evidence
    Add-Type -AssemblyName UIAutomationClient; Add-Type -AssemblyName UIAutomationTypes
    $package = @(Get-AppxPackage -Name $bundle.Metadata.package_name)
    if ($package.Count -ne 1) { throw 'The signed-out probe package ownership is ambiguous.' }
    $manifest = Get-AppxPackageManifest -Package $package[0].PackageFullName
    $protocol = $manifest.SelectNodes("//*[local-name()='Application' and @Id='VexWindowsApp']/*[local-name()='Extensions']/*[local-name()='Extension' and @Category='windows.protocol']/*[local-name()='Protocol' and @Name='vexguard']")
    if ($protocol.Count -ne 1) { throw 'The owned package does not declare its exact callback protocol.' }
    $image = Join-Path $package[0].InstallLocation 'Vex.Windows.App.exe'
    $explorer = Join-Path ([Environment]::GetFolderPath('Windows')) 'explorer.exe'
    $null = Start-Process -FilePath $explorer -ArgumentList ('shell:AppsFolder\' + $package[0].PackageFamilyName + '!VexWindowsApp')
    Wait-ProtocolProbe {
        $processes = @(Get-Process -Name 'Vex.Windows.App' -ErrorAction SilentlyContinue)
        if ($processes.Count -gt 1) { throw 'The signed-out app ownership is ambiguous.' }
        if ($processes.Count -ne 1 -or $processes[0].MainWindowHandle -eq [IntPtr]::Zero) { return $false }
        if ($processes[0].MainModule.FileName -ine $image -or
            (Get-FileHash -LiteralPath $image -Algorithm SHA256).Hash -ine $bundle.Metadata.app_executable_sha256) {
            throw 'The signed-out application changed identity.'
        }
        $script:owned = $processes[0]
        $script:window = [Windows.Automation.AutomationElement]::FromHandle($script:owned.MainWindowHandle)
        return $true
    }
    Add-AcceptancePhase 'signed_out_without_pending_challenge' {
        Wait-ProtocolProbe {
            $login = Find-ProtocolProbeControl 'WebsiteSignInButton'
            return $null -ne $login -and $login.Current.IsEnabled -and -not $login.Current.IsOffscreen
        }
        foreach ($path in @(
            (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'VEX/VPN/pkce-state.bin'),
            (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('Packages/' + $package[0].PackageFamilyName + '/LocalCache/Local/VEX/VPN/pkce-state.bin')))) {
            if (Test-Path -LiteralPath $path) { throw 'The signed-out probe refuses a saved PKCE challenge.' }
        }
        if (Test-ProtocolProbeRejection) { throw 'The local rejection was already visible before activation.' }
    } $evidence
    Add-AcceptancePhase 'warm_shell_callback_local_rejection' {
        # No browser attempt is started. The actual NativeAuthService contract
        # rejects a missing stored challenge before calling any API or saving a
        # session. This tests delivery, not successful authentication.
        $callback = 'vexguard://auth/callback?code=vex-probe-invalid&state=vex-probe-invalid'
        $null = Start-Process -FilePath $explorer -ArgumentList $callback
        Wait-ProtocolProbe { Test-ProtocolProbeRejection } 20
        $evidence.local_guard_rejection_observed = $true
    } $evidence
    $evidence.observation = Get-ProtocolProbeObservation
    if (-not $evidence.observation.primary_process_alive -or -not $evidence.observation.single_app_process -or
        -not $evidence.observation.local_guard_rejection_observed -or $evidence.observation.authenticated_button_visible) {
        throw 'The signed-out protocol observation did not preserve its owned unauthenticated process.'
    }
    $evidence.passed = $true
}
catch {
    $failure = $_
    $evidence.failure_type = $_.Exception.GetType().Name
    if ($null -ne $script:window) { $evidence.observation = Get-ProtocolProbeObservation }
}
finally {
    try {
        if ($mutationStarted) {
            Invoke-AcceptanceOwnedCleanup -MutationStarted $true -Bundles @($bundle) -OwnerSid $ownerSid
            if ($shared.Count -eq 0) { $shared = @(Get-AcceptanceSharedDependencies) }
            Assert-AcceptanceRemoved $bundle.Metadata.package_name $shared
        }
        $evidence.cleanup_confirmed = $true
    }
    catch {
        $cleanupFailure = $_; $evidence.cleanup_failure_type = $_.Exception.GetType().Name; $evidence.passed = $false
    }
    $json = $evidence | ConvertTo-Json -Depth 8
    if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 16384) { throw 'The protocol observation exceeded its fixed evidence budget.' }
    [IO.File]::WriteAllText((Join-Path $ResultDirectory 'result.json'), $json, [Text.UTF8Encoding]::new($false))
}
if ($null -ne $failure -or $null -ne $cleanupFailure) {
    throw 'Signed-out protocol acceptance failed; inspect its fixed sanitized observations.'
}
Write-Output 'Signed-out protocol delivery reached the local rejection guard; production login and VPN remain separate acceptance.'
