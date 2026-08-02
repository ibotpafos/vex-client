[CmdletBinding()]
param(
    [string[]]$Paths
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($null -eq $Paths -or $Paths.Count -eq 0) {
    $Paths = @(
        (Join-Path $PSScriptRoot 'bootstrap-native-windows.ps1'),
        (Join-Path $PSScriptRoot 'install-vpn-service.ps1'),
        (Join-Path $PSScriptRoot 'uninstall-vpn-service.ps1'),
        (Join-Path (Join-Path (Join-Path $PSScriptRoot '..') 'packaging') 'package-native-windows.ps1'),
        (Join-Path (Join-Path (Join-Path $PSScriptRoot '..') 'packaging') 'publish-native-windows.ps1')
    )
}

$parseFailures = New-Object System.Collections.Generic.List[string]

foreach ($path in $Paths) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $parseFailures.Add("Missing PowerShell script: $path")
        continue
    }

    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $path,
        [ref]$null,
        [ref]$parseErrors)

    foreach ($parseError in @($parseErrors)) {
        $parseFailures.Add(
            ('{0}:{1}:{2}: {3}' -f
                $parseError.Extent.File,
                $parseError.Extent.StartLineNumber,
                $parseError.Extent.StartColumnNumber,
                $parseError.Message))
    }
}

if ($parseFailures.Count -gt 0) {
    foreach ($failure in $parseFailures) {
        Write-Error $failure
    }

    exit 1
}

Write-Host ('PowerShell parse validation passed for {0} file(s).' -f $Paths.Count)
