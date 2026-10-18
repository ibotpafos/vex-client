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
Write-Output 'Limited Windows tester validation passed: exact release/hash, ordinary namespace, TTL, public exits, and inert helper import.'
