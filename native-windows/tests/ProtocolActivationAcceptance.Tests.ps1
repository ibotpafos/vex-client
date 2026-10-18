$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$source = Join-Path $PSScriptRoot '../scripts/invoke-protocol-activation-acceptance.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if (@($errors).Count -ne 0) { throw 'Protocol acceptance must parse before its isolated predicate regression.' }
$guard = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Assert-AcceptanceRunner'
}, $true))
if ($guard.Count -ne 1) { throw 'The actual disposable runner admission is unavailable or ambiguous.' }
$sourceText = [IO.File]::ReadAllText((Resolve-Path $source).Path)
$start = $ast.EndBlock.Statements[0].Extent.StartOffset
$prefixText = $sourceText.Substring($start, $guard[0].Extent.StartOffset - $start)
# Execute the real initialization and FunctionsOnly import. Rebind only its
# source directory because this extracted block runs from the tests directory.
# The real installer entrypoint and Windows admission are never executed.
$prefix = [scriptblock]::Create($prefixText.Replace('$PSScriptRoot', '$probeScriptDirectory'))
$admission = [scriptblock]::Create($guard[0].Extent.Text)
$directory = Split-Path -Parent (Resolve-Path $source).Path
foreach ($requested in @($true, $false)) {
    $observed = @(& {
        param($prefix, $admission, $probeScriptDirectory, [bool]$requested)
        [switch]$DisposableRunner = $requested
        . $prefix
        function Assert-AcceptanceRunner([bool]$ExplicitlyDisposable) { return $ExplicitlyDisposable }
        & $admission
    } $prefix $admission $directory $requested)
    if ($observed.Count -ne 1 -or $observed[0] -isnot [bool] -or $observed[0] -cne $requested) {
        throw 'The FunctionsOnly import changed the explicit disposable runner decision.'
    }
}
$function = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Test-ProtocolProbeRejection'
}, $true))
if ($function.Count -ne 1) { throw 'The production rejection predicate is unavailable or ambiguous.' }
Invoke-Expression $function[0].Extent.Text
# Derive the public peer identity from the actual product XAML. A control's
# x:Name can differ from its explicit AutomationId and is not a UIA selector.
$accountSource = Join-Path $PSScriptRoot '../src/Vex.Windows.App/Views/AccountPage.xaml'
$accountXaml = [xml][IO.File]::ReadAllText((Resolve-Path $accountSource).Path)
$statusPeer = $accountXaml.SelectSingleNode("//*[local-name()='TextBlock' and @*[local-name()='Name']='SignInStatusText']")
if ($null -eq $statusPeer) { throw 'The actual account status peer is unavailable.' }
$script:statusAutomationId = $statusPeer.GetAttribute('AutomationProperties.AutomationId')
if ([string]::IsNullOrWhiteSpace($script:statusAutomationId)) { throw 'The account status peer has no explicit AutomationId.' }
# The actual predicate runs against an inert UIA surface on every platform.
# It must observe the existing local error, rather than accept any status text.
$script:status = $null
function Find-ProtocolProbeControl([string]$Id) {
    if ($Id -cne $script:statusAutomationId) { throw 'The predicate did not select the actual XAML status peer.' }
    return $script:status
}
if (Test-ProtocolProbeRejection) { throw 'Missing UI was accepted as callback delivery.' }
$script:status = [pscustomobject]@{ Current = [pscustomobject]@{ IsOffscreen = $false; Name = 'A different authentication error' } }
if (Test-ProtocolProbeRejection) { throw 'An unrelated authentication result was accepted.' }
$script:status.Current.Name = 'Сессия входа через сайт устарела. Запустите вход заново.'
$script:status.Current.IsOffscreen = $true
if (Test-ProtocolProbeRejection) { throw 'A hidden stale control was accepted as visible delivery.' }
$script:status.Current.IsOffscreen = $false
if (-not (Test-ProtocolProbeRejection)) { throw 'The actual visible local rejection was not recognized.' }
# Exercise the real production observation too, retaining its existing JSON key.
$qaTokens = $null; $qaErrors = $null
$qaSource = Join-Path $PSScriptRoot '../scripts/invoke-production-tester-acceptance.ps1'
$qaAst = [Management.Automation.Language.Parser]::ParseFile($qaSource, [ref]$qaTokens, [ref]$qaErrors)
if (@($qaErrors).Count -ne 0) { throw 'Production tester acceptance must parse before the isolated observation regression.' }
$qaFunction = @($qaAst.FindAll({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-QASignInObservation'
}, $true))
if ($qaFunction.Count -ne 1) { throw 'The actual production sign-in observation is unavailable or ambiguous.' }
Invoke-Expression $qaFunction[0].Extent.Text
function Find-QAControl([string]$Id) {
    if ($Id -cne $script:statusAutomationId) { return $null }
    return [pscustomobject]@{ Current = [pscustomobject]@{ IsOffscreen = $false; IsEnabled = $true } }
}
$observation = Get-QASignInObservation
if (-not $observation['SignInStatusText'].readable -or -not $observation['SignInStatusText'].present -or
    -not $observation['SignInStatusText'].enabled -or $observation['SignInStatusText'].offscreen) {
    throw 'The production observation lost the actual XAML status peer or changed its legacy report key.'
}
Write-Output 'Signed-out protocol oracle regressions passed; no Windows install or activation executed.'

# Exercise the actual Shell transport with an inert COM constructor and receiver.
$transportTokens = $null; $transportErrors = $null
$transportSource = Join-Path $PSScriptRoot '../scripts/ProtocolCallback.ps1'
$transportAst = [Management.Automation.Language.Parser]::ParseFile($transportSource, [ref]$transportTokens, [ref]$transportErrors)
if (@($transportErrors).Count -ne 0) { throw 'The shared Shell callback transport must parse.' }
$transport = @($transportAst.FindAll({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-AcceptanceProtocolCallback'
}, $true))
if ($transport.Count -ne 1) { throw 'The actual shared callback transport is unavailable or ambiguous.' }
& {
    param($definition)
    $script:constructorCalls = 0
    $script:fakeShell = [pscustomobject]@{ Calls = [Collections.Generic.List[object]]::new() }
    $script:fakeShell | Add-Member -MemberType ScriptMethod -Name ShellExecute -Value {
        param($Target, $Parameters, $Directory, $Operation, $Show)
        $this.Calls.Add([pscustomobject]@{ Target = $Target; Parameters = $Parameters;
            Directory = $Directory; Operation = $Operation; Show = $Show })
    }
    function New-Object([string]$ComObject) {
        if ($ComObject -cne 'Shell.Application') { throw 'The transport selected an unexpected COM class.' }
        $script:constructorCalls++
        return $script:fakeShell
    }
    Invoke-Expression $definition
    foreach ($uri in @('vexguard://auth/callback?code=vex-probe-invalid&state=vex-probe-invalid',
        'vexguard://auth/callback?code=abc%2Bdef%2Fghi%3D&state=inert-state')) {
        Invoke-AcceptanceProtocolCallback ([Uri]$uri)
        $call = $script:fakeShell.Calls[$script:fakeShell.Calls.Count - 1]
        if ($call.Target -cne $uri -or $call.Parameters -cne '' -or $call.Directory -cne '' -or
            $call.Operation -cne 'open' -or $call.Show -ne 1) {
            throw 'The actual Shell transport changed the URI or its fixed association operation.'
        }
    }
    foreach ($uri in @('https://example.invalid/callback?code=inert', 'file:///C:/Windows/notepad.exe',
        'vexguard://other/callback?code=inert', 'vexguard://auth/other?code=inert',
        'vexguard://user@auth/callback?code=inert', 'vexguard://auth:99/callback?code=inert',
        'vexguard://auth/callback?code=inert#fragment', 'vexguard://auth/callback')) {
        $rejected = $false
        try { Invoke-AcceptanceProtocolCallback ([Uri]$uri) } catch { $rejected = $true }
        if (-not $rejected -or $script:constructorCalls -ne 2 -or $script:fakeShell.Calls.Count -ne 2) {
            throw 'A foreign callback reached the Shell constructor or receiver.'
        }
    }
} $transport[0].Extent.Text

$completion = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Test-ProtocolProbeComplete'
}, $true))
if ($completion.Count -ne 1) { throw 'The actual warm/cold acceptance decision is unavailable or ambiguous.' }
Invoke-Expression $completion[0].Extent.Text
function New-InertProtocolEvidence {
    return @{ local_guard_rejection_observed = $true; cold_start_observed = $true;
        cold_local_guard_rejection_observed = $true;
        observation = @{ primary_process_alive = $true; single_app_process = $true; authenticated_button_visible = $false };
        cold_observation = @{ primary_process_alive = $true; single_app_process = $true; authenticated_button_visible = $false } }
}
if (-not (Test-ProtocolProbeComplete (New-InertProtocolEvidence))) { throw 'Both actual local observations were rejected.' }
foreach ($flag in @('local_guard_rejection_observed', 'cold_start_observed', 'cold_local_guard_rejection_observed')) {
    $candidate = New-InertProtocolEvidence; $candidate[$flag] = $false
    if (Test-ProtocolProbeComplete $candidate) { throw 'An incomplete warm/cold observation passed.' }
}
foreach ($route in @('observation', 'cold_observation')) {
    $candidate = New-InertProtocolEvidence; $candidate[$route] = $null
    if (Test-ProtocolProbeComplete $candidate) { throw 'An absent route observation passed.' }
    foreach ($flag in @('primary_process_alive', 'single_app_process', 'authenticated_button_visible')) {
        $candidate = New-InertProtocolEvidence
        $candidate[$route][$flag] = $flag -ceq 'authenticated_button_visible'
        if (Test-ProtocolProbeComplete $candidate) { throw 'An unowned or authenticated route observation passed.' }
    }
}
Write-Output 'Actual Shell arguments, origin guard and warm/cold acceptance regressions passed without COM activation.'
