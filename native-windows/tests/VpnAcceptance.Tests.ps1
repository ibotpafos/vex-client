# Portable regression for the exact CI fixture tool resolver/process wrapper.
# Import function definitions only; never execute the Windows networking fixture.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../scripts/invoke-vpn-acceptance.ps1'))
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw 'VPN acceptance fixture does not parse.' }
foreach ($name in @('Resolve-FixtureTool', 'Invoke-FixtureProcess')) {
    $functions = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true))
    if ($functions.Count -ne 1) { throw "Fixture production function missing: $name" }
    . ([scriptblock]::Create($functions[0].Extent.Text))
}
$script:expectedTool = Join-Path $PSHOME $(if($IsWindows){'pwsh.exe'}else{'pwsh'})
function Get-Command {
    param($Name, $CommandType)
    if ($Name -notin @('go', 'dotnet') -or $CommandType -ne 'Application') {
        throw 'Unexpected fixture command lookup.'
    }
    # Hosted Windows runners have both setup-action and preinstalled SDKs.
    [pscustomobject]@{Source=$script:expectedTool}
    [pscustomobject]@{Source='missing-preinstalled-sdk'}
}
foreach ($name in @('go', 'dotnet')) {
    $tool = Resolve-FixtureTool -Name $name
    if ($tool -isnot [string] -or $tool -cne $script:expectedTool) {
        throw 'Multiple PATH matches became a concatenated executable path.'
    }
    Invoke-FixtureProcess -FilePath $tool -Arguments @('-NoProfile', '-NonInteractive', '-Command', 'exit 0') -TimeoutSeconds 10
}
Write-Output 'VPN acceptance SDK resolution and actual child-process regression passed.'
