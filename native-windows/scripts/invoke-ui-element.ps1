[CmdletBinding(DefaultParameterSetName = 'AutomationId')]
param(
    [string]$ProcessName = 'Vex.Windows.App',

    [Parameter(Mandatory = $true, ParameterSetName = 'AutomationId')]
    [string]$AutomationId,

    [Parameter(Mandatory = $true, ParameterSetName = 'Name')]
    [string]$Name,

    [string]$ResultPath,

    [ValidateRange(1, 60)]
    [int]$TimeoutSeconds = 20
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

function Write-Result {
    param([Parameter(Mandatory = $true)][string]$Value)

    if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
        [IO.File]::WriteAllText($ResultPath, $Value)
    }
    Write-Host $Value
}

$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$root = $null
while ([DateTime]::UtcNow -lt $deadline) {
    $process = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
        Where-Object MainWindowHandle -ne 0 |
        Select-Object -First 1
    if ($null -ne $process) {
        $root = [Windows.Automation.AutomationElement]::FromHandle(
            $process.MainWindowHandle)
        if ($null -ne $root) {
            break
        }
    }
    Start-Sleep -Milliseconds 250
}

if ($null -eq $root) {
    throw "Unable to find a visible $ProcessName window."
}

$property = if ($PSCmdlet.ParameterSetName -eq 'AutomationId') {
    [Windows.Automation.AutomationElement]::AutomationIdProperty
}
else {
    [Windows.Automation.AutomationElement]::NameProperty
}
$value = if ($PSCmdlet.ParameterSetName -eq 'AutomationId') {
    $AutomationId
}
else {
    $Name
}
$condition = [Windows.Automation.PropertyCondition]::new(
    $property,
    $value)
$element = $root.FindFirst(
    [Windows.Automation.TreeScope]::Descendants,
    $condition)
if ($null -eq $element) {
    throw "Unable to find UI element '$value'."
}

$pattern = $null
if ($element.TryGetCurrentPattern(
    [Windows.Automation.InvokePattern]::Pattern,
    [ref]$pattern)) {
    ([Windows.Automation.InvokePattern]$pattern).Invoke()
}
elseif ($element.TryGetCurrentPattern(
    [Windows.Automation.SelectionItemPattern]::Pattern,
    [ref]$pattern)) {
    ([Windows.Automation.SelectionItemPattern]$pattern).Select()
}
else {
    throw "UI element '$value' does not expose an invokable pattern."
}

Write-Result "Invoked UI element '$value'."
