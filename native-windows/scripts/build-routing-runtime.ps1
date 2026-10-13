[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$DestinationRoot)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path (Join-Path $PSScriptRoot '..') 'packaging/ReleaseValidation.ps1')
$sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../native-routing'))
$go = (Get-Command go -ErrorAction Stop).Source
$names = @('GOOS', 'GOARCH', 'CGO_ENABLED', 'GOWORK', 'GOFLAGS')
$previous = @{}
foreach ($name in $names) { $previous[$name] = [Environment]::GetEnvironmentVariable($name) }
try {
    $env:GOOS = 'windows'; $env:CGO_ENABLED = '0'; $env:GOWORK = 'off'; $env:GOFLAGS = '-mod=readonly'
    foreach ($architecture in @('x64', 'arm64')) {
        $env:GOARCH = if ($architecture -eq 'x64') { 'amd64' } else { 'arm64' }
        $directory = Join-Path $DestinationRoot $architecture
        $null = New-Item -ItemType Directory -Path $directory -Force
        $binary = [IO.Path]::GetFullPath((Join-Path $directory 'vex-awg.exe'))
        & $go -C $sourceRoot build -trimpath -o $binary './cmd/vex-awg'
        if ($LASTEXITCODE -ne 0) { throw "Routed runtime build failed on $architecture." }
        Assert-WindowsPeArchitecture -Path $binary -Architecture $architecture
        $variable = "VEX_WINDOWS_SERVICE_ROUTER_PATH_$($architecture.ToUpperInvariant())"
        [Environment]::SetEnvironmentVariable($variable, $binary)
        if ($env:GITHUB_ENV) { "$variable=$binary" | Out-File -LiteralPath $env:GITHUB_ENV -Append -Encoding utf8 }
        Write-Host "Built routing runtime $architecture SHA-256 $((Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash)"
    }
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
}
