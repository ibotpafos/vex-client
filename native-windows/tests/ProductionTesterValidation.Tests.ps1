$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../scripts/ProductionTesterValidation.ps1')
function Assert($value, $message) { if (-not $value) { throw $message } }
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$source = 'a' * 40
$payload = @{ schema = 'vex.windows-tester-qa.v1'; namespace = 'b' * 32; user_id = 'usr_' + ('b' * 32)
    email = 'tester-acceptance-' + ('b' * 32) + '@example.test'; token = 'c' * 64; expires_at_unix = $now + 3600
    release_source_commit = $source; release_run_id = 12345; release_version = '0.1.75.0'; release_build = 1792253320
    campaign_id = 'tcamp_fixture'; expected_exit_ipv4 = @('1.1.1.1') }
function Read-Fixture($value, [string]$Hash = '') {
    $raw = $value | ConvertTo-Json -Compress
    if (-not $Hash) { $Hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($raw))).ToLowerInvariant() }
    Read-WindowsProductionQaPayload -Raw $raw -ExpectedSha256 $Hash -ReleaseSourceCommit $source -ReleaseRunId 12345 -NowUnix $now
}
Assert ((Read-Fixture $payload).user_id -ceq $payload.user_id) 'The exact limited tester was rejected.'
foreach ($change in @(
    @{ user_id = 'usr_real_customer' }, @{ email = 'owner@example.test' }, @{ token = 'short' },
    @{ expires_at_unix = $now }, @{ expires_at_unix = $now + 7201 }, @{ expires_at_unix = 'future' },
    @{ release_source_commit = 'd' * 40 }, @{ release_run_id = 12346 }, @{ release_version = '0.01.75.0' },
    @{ release_version = '1.2.3.65536' }, @{ release_build = 0 }, @{ release_build = 1.5 },
    @{ campaign_id = '../foreign' }, @{ expected_exit_ipv4 = @() }, @{ expected_exit_ipv4 = @('127.0.0.1') },
    @{ expected_exit_ipv4 = @('192.0.2.1') }, @{ expected_exit_ipv4 = @('1.1.1.1', '1.1.1.1') },
    @{ expected_exit_ipv4 = '1.1.1.1' }, @{ admin_token = 'unrelated credential' }
)) {
    $changed = $payload.Clone()
    foreach ($key in $change.Keys) { $changed[$key] = $change[$key] }
    $rejected = $false
    try { $null = Read-Fixture $changed } catch { $rejected = $true }
    Assert $rejected ('An unbound, expired, privileged or invalid tester payload was admitted: ' + ($change.Keys -join ','))
}
$rejected = $false
try { $null = Read-Fixture $payload ('0' * 64) } catch { $rejected = $true }
Assert $rejected 'A different approved payload hash was admitted.'
$workflow = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../../.github/workflows/native-windows-production-acceptance.yml'))
$references = @([regex]::Matches($workflow, '\$\{\{\s*secrets[.]([A-Za-z_][A-Za-z0-9_]*)\s*\}\}') | ForEach-Object { $_.Groups[1].Value })
Assert ($references.Count -eq 1 -and $references[0] -ceq 'VEX_WINDOWS_TESTER_QA') 'Production QA can receive only its one statically named ordinary tester secret.'
Assert ($workflow -notmatch 'secrets\s*\[|toJSON\s*\(\s*secrets\s*\)|secrets\s*:\s*inherit') 'Dynamic or inherited secret context can expose signing/admin credentials.'
# Importing lifecycle helpers must not execute its administrator/install path.
. (Join-Path $PSScriptRoot '../scripts/invoke-signed-install-acceptance.ps1') -FunctionsOnly
Assert ($null -ne (Get-Command Read-AcceptanceBundle -CommandType Function)) 'Lifecycle helpers were not imported.'
# Import only the observation definition: never run the production script or
# discover a real window, process, account or certificate during unit tests.
$tokens = $null; $errors = $null
$driver = Join-Path $PSScriptRoot '../scripts/invoke-production-tester-acceptance.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($driver, [ref]$tokens, [ref]$errors)
Assert ($errors.Count -eq 0) 'Production tester driver has invalid PowerShell syntax.'
$definitions = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $n.Name -ceq 'Get-QASignInObservation' }, $false))
Assert ($definitions.Count -eq 1) 'Production sign-in observation definition is ambiguous.'
Invoke-Expression $definitions[0].Extent.Text
$privateCanary = 'private-token-callback-account-never-upload'
$script:observationFixture = @{
    WebsiteSignInButton = [pscustomobject]@{ Current = [pscustomobject]@{ IsEnabled = $true; IsOffscreen = $false; Name = $privateCanary } }
    CancelWebsiteAuthButton = [pscustomobject]@{ Current = [pscustomobject]@{ IsEnabled = $false; IsOffscreen = $true; Name = $privateCanary } }
    PowerButton = [pscustomobject]@{ Current = [pscustomobject]@{ IsEnabled = $true; IsOffscreen = $true; Name = $privateCanary } }
}
function Find-QAControl([string]$Id) {
    if ($Id -ceq 'AccountNavigationButton') { throw $privateCanary }
    return $script:observationFixture[$Id]
}
$observation = Get-QASignInObservation
Assert ($observation.Count -eq 6 -and $observation.WebsiteSignInButton.readable -and
    $observation.WebsiteSignInButton.present -and $observation.WebsiteSignInButton.enabled -and
    -not $observation.WebsiteSignInButton.offscreen) 'Visible, enabled sign-in observation was lost.'
Assert ($observation.CancelWebsiteAuthButton.present -and -not $observation.CancelWebsiteAuthButton.enabled -and
    $observation.CancelWebsiteAuthButton.offscreen -and $observation.PowerButton.offscreen) 'Disabled and offscreen states were conflated with absence.'
Assert (-not $observation.AccountNavigationButton.readable -and -not $observation.SignOutButton.present -and
    $observation.SignOutButton.readable) 'An unreadable UI provider was confused with an absent control.'
foreach ($control in $observation.Values) {
    Assert ($control.Count -eq 4) 'An observation contains unexpected private fields.'
    foreach ($key in @('readable', 'present', 'enabled', 'offscreen')) {
        Assert ($control[$key] -is [bool]) 'Only boolean UI state may enter an observation.'
    }
}
Assert (-not (($observation | ConvertTo-Json -Depth 4 -Compress).Contains($privateCanary))) 'UI or exception text leaked into the observation.'

function New-BrowserRequestValue([hashtable]$Fields) {
    return 'https://vexguard.app/auth/app?' + (($Fields.GetEnumerator() | ForEach-Object {
        [Uri]::EscapeDataString($_.Key) + '=' + [Uri]::EscapeDataString($_.Value)
    }) -join '&')
}
function Assert-BrowserRequestRejected([string]$Value) {
    $rejected = $false
    try { $null = Read-WindowsProductionBrowserRequest $Value }
    catch [InvalidOperationException] {
        $rejected = $true
        Assert (-not $_.Exception.Message.Contains($privateCanary)) 'Browser validation disclosed private input.'
    }
    Assert $rejected 'A malformed native browser request was admitted.'
}
$browserFields = @{ state = (('a' * 14) + '.~'); code_challenge = 'A' * 43;
    device_id = 'installation-fixture'; device_name = 'Windows'; platform = 'windows'; client_id = 'vex_app'; mode = 'login' }
# Match the actual native generator's URI-unreserved alphabet. In particular,
# state is not restricted to the separately validated base64url challenge.
foreach ($testState in @(('a' * 16), (('a' * 14) + '.~'), 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~')) {
    $fields = $browserFields.Clone(); $fields.state = $testState
    $value = New-BrowserRequestValue $fields
    Assert ((Read-WindowsProductionBrowserRequest $value).Get('state') -ceq $testState) 'A native-generated state was rejected.'
    Assert ($null -eq (Read-WindowsProductionBrowserRequest $value.Substring('https://'.Length))) 'An elided browser display was assumed to use HTTPS.'
    $relative = $value.Substring('https://vexguard.app'.Length)
    $login = 'https://vexguard.app/sign-in?callbackUrl=' + [Uri]::EscapeDataString($relative)
    Assert ((Read-WindowsProductionBrowserRequest $login).Get('state') -ceq $testState) 'The normal sign-in redirect changed its native state.'
    Assert-BrowserRequestRejected ($login + '&callbackUrl=' + [Uri]::EscapeDataString($relative))
}
$browserValue = New-BrowserRequestValue $browserFields
foreach ($value in @('', 'http://vexguard.app/auth/app', 'https://foreign.example.test/auth/app',
    'https://vexguard.app:8443/auth/app', 'https://user@vexguard.app/auth/app', 'https://vexguard.app/auth/app-other',
    'https://vexguard.app/sign-in', 'https://vexguard.app/sign-in?callbackUrl=https%3A%2F%2Fforeign.example.test%2Fauth%2Fapp',
    ('https://vexguard.app/auth/app?' + ('x' * 8192)))) {
    Assert ($null -eq (Read-WindowsProductionBrowserRequest $value)) 'An unrelated or unbounded browser URL became a native request.'
}
foreach ($key in @('state', 'code_challenge', 'device_id', 'device_name', 'platform')) {
    $fields = $browserFields.Clone(); $fields.Remove($key)
    Assert-BrowserRequestRejected (New-BrowserRequestValue $fields)
    $fields = $browserFields.Clone(); $fields[$key] = ' '
    Assert-BrowserRequestRejected (New-BrowserRequestValue $fields)
    Assert-BrowserRequestRejected ($browserValue + '&' + $key + '=' + [Uri]::EscapeDataString($browserFields[$key]))
}
foreach ($change in @(@{ state = 'a' * 15 }, @{ state = 'a' * 129 }, @{ state = 'state/with/slashes' },
    @{ state = 'state+with+pluses' }, @{ state = $privateCanary + '%' }, @{ platform = 'android' },
    @{ code_challenge = 'A' * 42 }, @{ code_challenge = ('A' * 42) + '.' }, @{ code_challenge = ('A' * 42) + '~' })) {
    $fields = $browserFields.Clone()
    foreach ($key in $change.Keys) { $fields[$key] = $change[$key] }
    Assert-BrowserRequestRejected (New-BrowserRequestValue $fields)
}
if ($IsWindows) {
    Add-Type -AssemblyName UIAutomationClient; Add-Type -AssemblyName UIAutomationTypes
    $readers = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $n.Name -ceq 'Get-QABrowserControlValue' }, $false))
    Assert ($readers.Count -eq 1) 'Browser control reader is ambiguous.'
    Invoke-Expression $readers[0].Extent.Text
    # Use real .NET method calls: a PowerShell ScriptMethod adds a separate
    # ParentContainsErrorRecordException wrapper that UIA does not produce.
    Add-Type -TypeDefinition @'
public sealed class VexBrowserControlFixture {
    public bool Supported = true;
    public object Pattern;
    public object FocusedPattern;
    public System.Exception Failure;
    public int FocusCalls;
    public bool TryGetCurrentPattern(object id, ref object pattern) {
        if (Failure != null) throw Failure;
        pattern = FocusCalls > 0 && FocusedPattern != null ? FocusedPattern : Pattern;
        return Supported;
    }
    public void SetFocus() { FocusCalls++; }
}
'@
    $element = [VexBrowserControlFixture]::new()
    $element.Pattern = [pscustomobject]@{ Current = [pscustomobject]@{ Value = $browserValue } }
    foreach ($browserReadCase in @('value', 'unsupported', 'stale', 'com', 'inactive')) {
        $element.Supported = $browserReadCase -cne 'unsupported'
        $element.Failure = switch ($browserReadCase) {
            'stale' { [Windows.Automation.ElementNotAvailableException]::new($privateCanary) }
            'com' { [Runtime.InteropServices.COMException]::new($privateCanary) }
            'inactive' { [InvalidOperationException]::new($privateCanary) }
            default { $null }
        }
        $value = Get-QABrowserControlValue $element
        if ($browserReadCase -ceq 'value') { Assert ($value -ceq $browserValue) 'The UIA value was lost.' }
        else { Assert ($null -eq $value) 'A transient provider failure escaped as browser input.' }
    }
    $element.Supported = $true; $element.Failure = $null
    foreach ($browserReadCase in @('hidden_https', 'hidden_still', 'hidden_http')) {
        $element.FocusCalls = 0
        $element.Pattern.Current.Value = $browserValue.Substring('https://'.Length)
        $expandedValue = switch ($browserReadCase) {
            'hidden_https' { $browserValue }
            'hidden_http' { $browserValue.Replace('https://', 'http://') }
            default { $element.Pattern.Current.Value }
        }
        $element.FocusedPattern = [pscustomobject]@{ Current = [pscustomobject]@{ Value = $expandedValue } }
        $value = Get-QABrowserControlValue $element
        Assert ($element.FocusCalls -eq 1) 'An elided address was not reread after browser focus.'
        if ($browserReadCase -ceq 'hidden_https') { Assert ((Read-WindowsProductionBrowserRequest $value).Get('state') -ceq $browserFields.state) 'The actual expanded HTTPS address was lost.' }
        else { Assert ($null -eq (Read-WindowsProductionBrowserRequest $value)) 'A hidden or actual HTTP address was silently upgraded to HTTPS.' }
    }
    $element.Failure = [IO.IOException]::new($privateCanary); $rejected = $false
    try { $null = Get-QABrowserControlValue $element } catch [IO.IOException] { $rejected = $true }
    Assert $rejected 'An unexpected browser reader failure was silently retried.'
}
Write-Output 'Limited Windows tester validation passed: exact release/hash, ordinary namespace, TTL, public exits, and inert helper import.'
