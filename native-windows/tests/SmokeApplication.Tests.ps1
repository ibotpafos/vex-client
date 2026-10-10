[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$path = Join-Path $PSScriptRoot '../scripts/smoke-application.ps1'
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$parseErrors)
if (@($parseErrors).Count -ne 0) { throw 'Application smoke has PowerShell parse errors.' }

# Compile the exact interop definitions used by the smoke; no native calls run here.
$nativeSource = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
        $node.Value.Contains('namespace Vex.Windows.Smoke')
}, $true)
if ($null -eq $nativeSource) { throw 'Application smoke interop definitions are missing.' }
if (-not ('Vex.Windows.Smoke.NativeMethods' -as [type])) {
    Add-Type -TypeDefinition $nativeSource.Value
}

if ($IsWindows) {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Windows.Forms
}

$typeNodes = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.TypeExpressionAst] -or
        $node -is [System.Management.Automation.Language.TypeConstraintAst]
}, $true))
$deferred = [Collections.Generic.HashSet[string]]::new()
$checked = [Collections.Generic.HashSet[string]]::new()
foreach ($node in $typeNodes) {
    $name = $node.TypeName.FullName
    if (-not $IsWindows -and $name -match '^Windows\.(Automation|Forms)\.') {
        [void]$deferred.Add($name)
        continue
    }
    if ($null -eq $node.TypeName.GetReflectionType()) {
        throw "Application smoke uses an unresolved runtime type: $name"
    }
    [void]$checked.Add($name)
}

# These casts execute, unlike AST parsing; a C# alias such as [nint] cannot substitute.
if ([System.IntPtr]::Zero.ToInt64() -ne 0 -or ([System.IntPtr](-4)).ToInt64() -ne -4) {
    throw 'Application smoke native pointer conversion is invalid.'
}
if ([Runtime.InteropServices.Marshal]::SizeOf([type][Vex.Windows.Smoke.WindowRect]) -ne 16) {
    throw 'Application smoke native window rectangle layout is invalid.'
}
Write-Host "Application smoke runtime type verification passed: $($checked.Count) types; Windows-only types deferred: $($deferred.Count)."
