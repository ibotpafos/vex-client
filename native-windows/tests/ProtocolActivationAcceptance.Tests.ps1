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
# The actual predicate runs against an inert UIA surface on every platform.
# It must observe the existing local error, rather than accept any status text.
$script:status = $null
function Find-ProtocolProbeControl([string]$Id) {
    if ($Id -cne 'SignInStatusText') { throw 'The predicate read an unexpected control.' }
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
Write-Output 'Signed-out protocol predicate regression passed; no Windows install or activation executed.'
