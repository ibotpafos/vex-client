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
if ([Runtime.InteropServices.Marshal]::SizeOf([type][Vex.Windows.Smoke.WindowPoint]) -ne 8) {
    throw 'Application smoke native cursor point layout is invalid.'
}

# Execute the actual pure capture helpers, without desktop interaction.
foreach ($functionName in @('Wait-SmokeCondition', 'Wait-SmokeCaptureBounds', 'Get-SmokeCaptureCursorPoint', 'Set-SmokeCaptureFocus')) {
    $functionAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
    }, $true)
    if ($null -eq $functionAst) { throw "Application smoke helper is missing: $functionName" }
    . ([scriptblock]::Create($functionAst.Extent.Text))
}
$desktop = [pscustomobject]@{ Left = -1920; Top = -200; Right = 0; Bottom = 880 }
$bounds = [pscustomobject]@{ Left = -1840; Top = -140; Right = -900; Bottom = 500 }
$point = Get-SmokeCaptureCursorPoint -Desktop $desktop -WindowBounds $bounds
if ($point.X -ne -1918 -or $point.Y -ne -198) {
    throw 'Application smoke cursor selection mishandles negative desktop origins.'
}
$desktop = [pscustomobject]@{ Left = 0; Top = 0; Right = 1024; Bottom = 768 }
$bounds = [pscustomobject]@{ Left = 0; Top = 0; Right = 700; Bottom = 650 }
$point = Get-SmokeCaptureCursorPoint -Desktop $desktop -WindowBounds $bounds
if ($point.X -ne 1021 -or $point.Y -ne 2) {
    throw 'Application smoke cursor selection does not skip an occupied desktop corner.'
}
$noOutsidePointRejected = $false
try { Get-SmokeCaptureCursorPoint -Desktop $desktop -WindowBounds $desktop | Out-Null }
catch { $noOutsidePointRejected = $true }
if (-not $noOutsidePointRejected) { throw 'Application smoke allows a cursor over a full-desktop window.' }

# Capture focus must skip headings, clipped controls and disabled actions.
$script:focusedCaptureControl = $null
function Find-SmokeElement {
    param([string]$AutomationId)
    $element = [pscustomobject]@{
        Current = [pscustomobject]@{
            IsOffscreen = $AutomationId -eq 'Hidden'
            IsEnabled = $AutomationId -ne 'Disabled'
            IsKeyboardFocusable = $AutomationId -ne 'Heading'
            AutomationId = $AutomationId
        }
    }
    $element | Add-Member -MemberType ScriptMethod -Name SetFocus -Value {
        $script:focusedCaptureControl = $this.Current.AutomationId
    }
    return $element
}
$focused = Set-SmokeCaptureFocus -AutomationIds @('Heading', 'Hidden', 'Disabled', 'Action')
if ($focused -ne 'Action' -or $script:focusedCaptureControl -ne 'Action') {
    throw 'Application smoke failed to focus a visible enabled page action.'
}
$noFocusTargetRejected = $false
try { Set-SmokeCaptureFocus -AutomationIds @('Heading', 'Hidden', 'Disabled') | Out-Null }
catch { $noFocusTargetRejected = $true }
if (-not $noFocusTargetRejected) { throw 'Application smoke accepts capture without a safe focus target.' }

# Model a page entering from outside the window and moving before it settles.
$script:captureProbeCalls = 0
function Find-SmokeElement {
    param([string]$AutomationId)
    $script:captureProbeCalls++
    $left = if ($script:captureProbeCalls -lt 5) { 950 }
        elseif ($script:captureProbeCalls -lt 7) { 130 }
        else { 120 }
    [pscustomobject]@{
        Current = [pscustomobject]@{
            IsOffscreen = $script:captureProbeCalls -lt 3
            BoundingRectangle = [pscustomobject]@{
                IsEmpty = $false; Left = $left; Top = 100; Right = $left + 40; Bottom = 130; Width = 40; Height = 30
            }
        }
    }
}
$bounds = [pscustomobject]@{ Left = 50; Top = 50; Right = 960; Bottom = 650 }
$settleStarted = [DateTime]::UtcNow
$elements = @(Wait-SmokeCaptureBounds -AutomationIds @('Heading', 'Action') -WindowBounds $bounds)
if ($elements.Count -ne 2 -or $elements[0].left -ne 120 -or $elements[1].left -ne 120 -or
    ([DateTime]::UtcNow - $settleStarted).TotalMilliseconds -lt 1500) {
    throw 'Application smoke capture did not wait for fully visible stable controls.'
}
Write-Host 'Application smoke capture geometry verification passed.'
Write-Host "Application smoke runtime type verification passed: $($checked.Count) types; Windows-only types deferred: $($deferred.Count)."
