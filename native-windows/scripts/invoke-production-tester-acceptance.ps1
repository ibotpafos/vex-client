#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][switch]$DisposableRunner,
    [Parameter(Mandatory = $true)][string]$BundleDirectory,
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-f0-9]{40}$')][string]$ReleaseSourceCommit,
    [Parameter(Mandatory = $true)][long]$ReleaseRunId,
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedQaPayloadSha256,
    [Parameter(Mandatory = $true)][string]$ResultDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$explicitDisposable = [bool]$DisposableRunner
. (Join-Path $PSScriptRoot 'invoke-signed-install-acceptance.ps1') -FunctionsOnly
Assert-AcceptanceRunner $explicitDisposable
if ($env:GITHUB_EVENT_NAME -cne 'workflow_dispatch' -or $env:GITHUB_REF -cne 'refs/heads/main' -or
    $env:GITHUB_REPOSITORY -cne 'ibotpafos/vex-client') { throw 'Production QA requires the reviewed main workflow on a disposable host.' }
foreach ($name in @('VEX_WINDOWS_SIGN_PFX_BASE64', 'VEX_WINDOWS_SIGN_PFX_PASSWORD', 'VEX_WINDOWS_UPDATE_PRIVATE_KEY_BASE64')) {
    if (-not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($name))) { throw 'Production QA must not inherit signing credentials.' }
}
$raw = [Environment]::GetEnvironmentVariable('VEX_WINDOWS_TESTER_QA')
[Environment]::SetEnvironmentVariable('VEX_WINDOWS_TESTER_QA', $null)
if ([string]::IsNullOrEmpty($raw) -or [Text.Encoding]::UTF8.GetByteCount($raw) -gt 16384) { throw 'A bounded limited tester identity is required.' }
$digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($raw))).ToLowerInvariant()
if ($digest -cne $ExpectedQaPayloadSha256) { throw 'The limited tester identity changed after its approved plan.' }
. (Join-Path $PSScriptRoot 'ProductionTesterValidation.ps1')
$qa = Read-WindowsProductionQaPayload -Raw $raw -ExpectedSha256 $ExpectedQaPayloadSha256 -ReleaseSourceCommit $ReleaseSourceCommit -ReleaseRunId $ReleaseRunId
$raw = $null
foreach ($private in @($qa.token, $qa.email, $qa.user_id)) { Write-Output ('::add-mask::' + $private) }
$bundle = Read-AcceptanceBundle $BundleDirectory
if ($bundle.Metadata.channel -cne 'beta' -or $bundle.Metadata.signing_mode -cne 'tester-ca' -or
    $bundle.Metadata.source_commit -cne $ReleaseSourceCommit -or $bundle.Metadata.version -cne $qa.release_version -or
    $bundle.Metadata.architecture -cne 'x64' -or $bundle.Metadata.client_certificate_sha256 -ine $env:VEX_WINDOWS_TEST_CERT_SHA256 -or
    $bundle.Metadata.tester_root_sha256 -ine $env:VEX_WINDOWS_TEST_ROOT_SHA256) { throw 'Production QA requires the exact signed x64 beta.' }
Assert-AcceptanceFreshHost $bundle.Metadata.package_name
$ResultDirectory = [IO.Path]::GetFullPath($ResultDirectory)
if (-not $ResultDirectory.StartsWith(([IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Production QA evidence must stay inside this disposable runner.'
}
New-Item -ItemType Directory -Path $ResultDirectory -Force | Out-Null
$null = Assert-AcceptanceRegularPath -Path $ResultDirectory -Directory
$handler = [Net.Http.HttpClientHandler]::new(); $handler.AllowAutoRedirect = $false; $handler.UseCookies = $false
$http = [Net.Http.HttpClient]::new($handler); $http.Timeout = [TimeSpan]::FromSeconds(15); $http.MaxResponseContentBufferSize = 256KB
$evidence = [ordered]@{ schema = 'vex.windows-production-tester-acceptance.v1'; source_commit = $ReleaseSourceCommit;
    qa_workflow_commit = $env:GITHUB_SHA; release_version = $qa.release_version; qa_payload_sha256 = $digest;
    passed = $false; normal_pkce_callback = $false; free_tester_access = $false; public_vpn_verified = $false;
    restored_baseline_egress_verified = $false; feedback_saved = $false; cleanup_confirmed = $false;
    physical_arm64_verified = $false; reboot_verified = $false; phases = [Collections.Generic.List[object]]::new(); failure_type = $null;
    sign_in_stage = 'not_started'; sign_in_observation = $null }
$baseline = Join-Path $ResultDirectory 'baseline.json'; $connected = Join-Path $ResultDirectory 'connected.json'; $restored = Join-Path $ResultDirectory 'restored.json'
$ownerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$mutationStarted = $false; $owned = $null; $shared = @(); $failure = $null

function Invoke-QAApi([string]$Method, [string]$Path, $Body = $null, [int[]]$Expected = @(200), [string]$IdempotencyKey = '') {
    if (-not $Path.StartsWith('/v1/', [StringComparison]::Ordinal) -or $Path.Contains('://')) { throw 'QA API path is invalid.' }
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), ('https://vexguard.app' + $Path))
    $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $qa.token)
    if ($IdempotencyKey) { $request.Headers.Add('Idempotency-Key', $IdempotencyKey) }
    if ($null -ne $Body) { $request.Content = [Net.Http.StringContent]::new(($Body | ConvertTo-Json -Depth 6 -Compress), [Text.Encoding]::UTF8, 'application/json') }
    $response = $null
    try {
        $response = $http.SendAsync($request).GetAwaiter().GetResult()
        if ([int]$response.StatusCode -notin $Expected) { throw 'The production QA API rejected a required step.' }
        $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        try { return ($text | ConvertFrom-Json) } catch { throw 'The production QA API returned invalid JSON.' }
    } finally { if ($null -ne $response) { $response.Dispose() }; $request.Dispose() }
}
function Wait-QA([scriptblock]$Condition, [int]$Seconds = 30) {
    $until = [DateTime]::UtcNow.AddSeconds($Seconds)
    do { if (& $Condition) { return }; Start-Sleep -Milliseconds 250 } while ([DateTime]::UtcNow -lt $until)
    throw 'A required production QA UI state did not arrive before its deadline.'
}
function Find-QAControl([string]$Id) {
    return $script:window.FindFirst([Windows.Automation.TreeScope]::Descendants,
        [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty, $Id))
}
function Invoke-QAControl([string]$Id) {
    Wait-QA { $item = Find-QAControl $Id; $null -ne $item -and $item.Current.IsEnabled -and -not $item.Current.IsOffscreen }
    $item = Find-QAControl $Id
    Invoke-AcceptanceUiControl $item
}
function Get-QASignInObservation {
    # Fixed identifiers and booleans only. Never serialize UI text, callback
    # arguments, account identity, exception messages or the desktop tree.
    $observation = [ordered]@{}
    foreach ($id in @('WebsiteSignInButton', 'CancelWebsiteAuthButton', 'AccountNavigationButton', 'PowerButton', 'SignOutButton', 'SignInStatusText')) {
        try {
            $item = Find-QAControl $id
            $observation[$id] = [ordered]@{ readable = $true; present = $null -ne $item;
                enabled = $null -ne $item -and $item.Current.IsEnabled;
                offscreen = $null -ne $item -and $item.Current.IsOffscreen }
        }
        catch { $observation[$id] = [ordered]@{ readable = $false; present = $false; enabled = $false; offscreen = $false } }
    }
    return $observation
}
function Get-QABrowserControlValue($Element) {
    try {
        $pattern = $null
        if (-not $Element.TryGetCurrentPattern([Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) { return $null }
        $value = [string]$pattern.Current.Value
        if ($value.StartsWith('vexguard.app/', [StringComparison]::Ordinal)) {
            # Focusing the browser edit reveals its complete address. Never
            # invent HTTPS for an elided value; the parser checks the reread.
            $Element.SetFocus()
            $pattern = $null
            if (-not $Element.TryGetCurrentPattern([Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) { return $null }
            $value = [string]$pattern.Current.Value
        }
        return $value
    }
    catch [Windows.Automation.ElementNotAvailableException], [Runtime.InteropServices.COMException], [InvalidOperationException] { return $null }
}
function Get-QABrowserRequest {
    foreach ($browser in @(Get-Process -Name 'msedge', 'chrome' -ErrorAction SilentlyContinue)) {
        try {
            if ($browser.MainWindowHandle -eq [IntPtr]::Zero) { continue }
            $root = [Windows.Automation.AutomationElement]::FromHandle($browser.MainWindowHandle)
            $edits = $root.FindAll([Windows.Automation.TreeScope]::Descendants,
                [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Edit))
        }
        catch [Windows.Automation.ElementNotAvailableException], [Runtime.InteropServices.COMException], [InvalidOperationException] { continue }
        foreach ($edit in $edits) {
            $value = Get-QABrowserControlValue $edit
            if ($null -eq $value) { continue }
            # Permanent URL-validation errors escape. Only transient UIA reads
            # are retried, within the existing single Wait-QA deadline.
            $query = Read-WindowsProductionBrowserRequest $value
            if ($null -ne $query) { return ,$query }
        }
    }
    return $null
}
try {
    Add-AcceptancePhase 'approved_free_tester' {
        $workspace = Invoke-QAApi 'GET' '/v1/testing/me'
        $access = Invoke-QAApi 'GET' '/v1/billing/entitlement'
        if ($workspace.active -ne $true -or $workspace.membership.user_id -cne $qa.user_id -or $workspace.membership.status -cne 'approved' -or
            $access.active -ne $true -or $access.source -cne 'tester_program' -or $access.device_limit -ne 5 -or
            @($workspace.campaigns | Where-Object { $_.id -ceq $qa.campaign_id -and $_.platform -ceq 'windows' }).Count -ne 1) { throw 'The exact approved free Windows tester was not verified.' }
        $evidence.free_tester_access = $true
    } $evidence
    Add-AcceptancePhase 'public_baseline' { & (Join-Path $PSScriptRoot 'verify-public-vpn.ps1') -Phase Baseline -ResultPath $baseline -ExpectedVpnExitIpv4 @($qa.expected_exit_ipv4) | Out-Null } $evidence
    $mutationStarted = $true
    Add-AcceptancePhase 'install_exact_signed_beta' {
        Invoke-AcceptanceBootstrap $bundle Install
        Invoke-AcceptanceBootstrap $bundle Verify
        $script:shared = @(Get-AcceptanceSharedDependencies)
    } $evidence
    Add-Type -AssemblyName UIAutomationClient; Add-Type -AssemblyName UIAutomationTypes
    $package = @(Get-AppxPackage -Name $bundle.Metadata.package_name)
    if ($package.Count -ne 1) { throw 'Installed QA package ownership is ambiguous.' }
    $image = Join-Path $package[0].InstallLocation 'Vex.Windows.App.exe'
    $null = Start-Process -FilePath (Join-Path ([Environment]::GetFolderPath('Windows')) 'explorer.exe') -ArgumentList ('shell:AppsFolder\' + $package[0].PackageFamilyName + '!VexWindowsApp')
    Wait-QA {
        $processes = @(Get-Process -Name 'Vex.Windows.App' -ErrorAction SilentlyContinue)
        if ($processes.Count -gt 1) { throw 'Installed QA application ownership is ambiguous.' }
        if ($processes.Count -ne 1 -or $processes[0].MainWindowHandle -eq [IntPtr]::Zero) { return $false }
        if ($processes[0].MainModule.FileName -ine $image -or
            (Get-FileHash -LiteralPath $image -Algorithm SHA256).Hash -ine $bundle.Metadata.app_executable_sha256) { throw 'Installed QA application changed identity.' }
        $script:owned = $processes[0]; $script:window = [Windows.Automation.AutomationElement]::FromHandle($script:owned.MainWindowHandle); return $true
    }
    Add-AcceptancePhase 'normal_native_pkce_sign_in' {
        $evidence.sign_in_stage = 'open_browser'
        $edge = Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'Microsoft/Edge/Application/msedge.exe'
        if (Test-Path -LiteralPath $edge -PathType Leaf) { $null = Start-Process -FilePath $edge -ArgumentList @('--no-first-run', '--no-default-browser-check', '--new-window', 'about:blank') }
        Invoke-QAControl 'WebsiteSignInButton'
        $evidence.sign_in_stage = 'browser_request'
        $script:browserRequest = $null
        Wait-QA { $script:browserRequest = Get-QABrowserRequest; return $null -ne $script:browserRequest } 45
        $q = $script:browserRequest; $state = $q.Get('state')
        $evidence.sign_in_stage = 'server_state'
        $details = Invoke-QAApi 'GET' ('/v1/auth/app?state=' + [Uri]::EscapeDataString($state)) $null @(200, 404)
        if ($details.PSObject.Properties.Name -notcontains 'state') {
            $init = @{ state = $state; code_challenge = $q.Get('code_challenge'); device_id = $q.Get('device_id'); device_name = $q.Get('device_name'); platform = 'windows' }
            try { $details = Invoke-QAApi 'POST' '/v1/auth/app' $init @(201) }
            catch { $details = Invoke-QAApi 'GET' ('/v1/auth/app?state=' + [Uri]::EscapeDataString($state)) }
        }
        if ($details.state -cne $state -or $details.platform -cne 'windows' -or $details.code_challenge -cne $q.Get('code_challenge') -or
            $details.device_id -cne $q.Get('device_id') -or [DateTimeOffset]::Parse($details.expires_at) -le [DateTimeOffset]::UtcNow) { throw 'The native PKCE server state changed.' }
        $evidence.sign_in_stage = 'approve_callback'
        $approval = Invoke-QAApi 'POST' '/v1/auth/app/approve' @{ state = $state }
        $redirect = [Uri]$approval.redirect_url
        if (-not (($redirect.Scheme -ceq 'vexguard' -and $redirect.Host -ceq 'auth' -and $redirect.AbsolutePath -ceq '/callback') -or
            ($redirect.Scheme -ceq 'https' -and $redirect.Host -ceq 'vexguard.app' -and $redirect.AbsolutePath -ceq '/app/callback'))) { throw 'The native callback left its approved origin.' }
        $parameters = [Web.HttpUtility]::ParseQueryString($redirect.Query)
        if (@($parameters.GetValues('code')).Count -ne 1 -or @($parameters.GetValues('state')).Count -ne 1 -or
            $parameters.Get('state') -cne $state -or [string]::IsNullOrWhiteSpace($parameters.Get('code'))) { throw 'The native callback is ambiguous.' }
        # Phase output is discarded; host output must still register this mask.
        Write-Host ('::add-mask::' + $parameters.Get('code'))
        $callback = 'vexguard://auth/callback?code=' + [Uri]::EscapeDataString($parameters.Get('code')) + '&state=' + [Uri]::EscapeDataString($state)
        $evidence.sign_in_stage = 'protocol_callback'
        $null = Start-Process -FilePath $callback
        Wait-QA {
            $signOut = Find-QAControl 'SignOutButton'; $power = Find-QAControl 'PowerButton'
            return ($null -ne $signOut -and -not $signOut.Current.IsOffscreen) -or ($null -ne $power -and $power.Current.IsEnabled)
        } 60
        $evidence.sign_in_stage = 'open_account'
        Invoke-QAControl 'AccountNavigationButton'
        $evidence.sign_in_stage = 'account_status'
        Wait-QA { $signOut = Find-QAControl 'SignOutButton'; return $null -ne $signOut -and -not $signOut.Current.IsOffscreen }
        $evidence.normal_pkce_callback = $true
        $evidence.sign_in_stage = 'completed'
    } $evidence
    Add-AcceptancePhase 'select_full_traffic' {
        Invoke-QAControl 'SettingsNavigationButton'
        Wait-QA { return $null -ne (Find-QAControl 'SmartRoutingToggle') }
        $toggle = Find-QAControl 'SmartRoutingToggle'
        $pattern = [Windows.Automation.TogglePattern]$toggle.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
        if ($pattern.Current.ToggleState -ne [Windows.Automation.ToggleState]::Off) { $pattern.Toggle() }
        Wait-QA { return $pattern.Current.ToggleState -eq [Windows.Automation.ToggleState]::Off }
        Invoke-QAControl 'HomeNavigationButton'
    } $evidence
    Add-AcceptancePhase 'connect_real_vex_vpn' {
        Invoke-QAControl 'PowerButton'
        Wait-QA { $button = Find-QAControl 'PowerButton'; return $null -ne $button -and $button.Current.Name -match 'Отключить|Disconnect' } 90
        & (Join-Path $PSScriptRoot 'verify-public-vpn.ps1') -Phase Connected -ResultPath $connected -ExpectedVpnExitIpv4 @($qa.expected_exit_ipv4) -BaselinePath $baseline | Out-Null
        $proof = Get-Content -LiteralPath $connected -Raw | ConvertFrom-Json
        if ($proof.passed -ne $true -or $proof.actual_public_internet_vpn_egress_verified -ne $true) { throw 'Actual production VPN egress was not verified.' }
        $evidence.public_vpn_verified = $true
    } $evidence
    Add-AcceptancePhase 'disconnect_and_restore_egress' {
        Invoke-QAControl 'PowerButton'
        Wait-QA { return @(Get-NetAdapter -IncludeHidden | Where-Object { $_.Name -ieq 'vex' -and $_.Status -eq 'Up' }).Count -eq 0 } 30
        & (Join-Path $PSScriptRoot 'verify-public-vpn.ps1') -Phase Restored -ResultPath $restored -ExpectedVpnExitIpv4 @($qa.expected_exit_ipv4) -BaselinePath $baseline -ConnectedPath $connected | Out-Null
        $evidence.restored_baseline_egress_verified = $true
    } $evidence
    Add-AcceptancePhase 'persist_tester_feedback' {
        $body = @{ campaign_id = $qa.campaign_id; platform = 'windows'; outcome = 'works'; summary = 'Windows beta: установка и реальный VPN проверены';
            details = 'На отдельном Windows x64 host проверены подписанная установка, обычный PKCE callback, бесплатный доступ программы, реальный выход через VEX и восстановление исходного выхода после отключения.';
            os_version = [Environment]::OSVersion.Version.ToString(); app_version = $qa.release_version; build_number = $qa.release_build }
        $key = 'windows-production-' + $qa.namespace
        $first = Invoke-QAApi 'POST' '/v1/testing/feedback' $body @(201) $key
        $replay = Invoke-QAApi 'POST' '/v1/testing/feedback' $body @(201) $key
        if ([string]::IsNullOrWhiteSpace($first.id) -or [string]::IsNullOrWhiteSpace($first.ticket_id) -or $first.id -cne $replay.id -or $first.ticket_id -cne $replay.ticket_id) { throw 'Tester feedback was not idempotently persisted.' }
        $workspace = Invoke-QAApi 'GET' '/v1/testing/me'
        if (@($workspace.feedback | Where-Object { $_.id -ceq $first.id }).Count -ne 1) { throw 'Tester feedback did not appear in its account.' }
        $evidence.feedback_saved = $true
    } $evidence
} catch {
    $failure = $_.Exception.GetType().Name; $evidence.failure_type = $failure
    $evidence.sign_in_observation = Get-QASignInObservation
}
finally {
    try {
        if ($mutationStarted) {
            Invoke-AcceptanceOwnedCleanup -MutationStarted:$mutationStarted -Bundles @($bundle) -OwnerSid $ownerSid
            Assert-AcceptanceRemoved -PackageName $bundle.Metadata.package_name -SharedDependencies $shared
        }
        $evidence.cleanup_confirmed = $true
    } catch { $failure = 'OwnedCleanupFailed'; $evidence.failure_type = $failure }
    $http.Dispose(); $qa = $null
    $evidence.passed = $null -eq $failure -and $evidence.normal_pkce_callback -and $evidence.free_tester_access -and $evidence.public_vpn_verified -and
        $evidence.restored_baseline_egress_verified -and $evidence.feedback_saved -and $evidence.cleanup_confirmed
    [IO.File]::WriteAllText((Join-Path $ResultDirectory 'result.json'), ($evidence | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
}
if (-not $evidence.passed) { throw 'Windows production tester acceptance failed; inspect only its sanitized phase receipts.' }
Write-Output 'Windows production tester acceptance passed.'
