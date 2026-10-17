#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][switch]$DisposableRunner,
    [Parameter(Mandatory = $true)][ValidateSet('x64', 'arm64')][string]$Architecture,
    [Parameter(Mandatory = $true)][string]$ApplicationPath,
    [Parameter(Mandatory = $true)][string]$ResultPath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../packaging/ReleaseValidation.ps1')
if (-not $DisposableRunner -or -not $IsWindows -or $env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted') {
    throw 'The native SDK schema probe requires an explicit disposable Windows runner.'
}
$temporary = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\') + '\'
foreach ($path in @($ApplicationPath, $ResultPath)) {
    if (-not [IO.Path]::GetFullPath($path).StartsWith($temporary, [StringComparison]::OrdinalIgnoreCase)) { throw 'SDK probe inputs and outputs must stay in this runner.' }
}
Assert-WindowsPeArchitecture -Path $ApplicationPath -Architecture $Architecture
$root = Split-Path -Parent ([IO.Path]::GetFullPath($ApplicationPath))
$manifestPath = Join-Path $root 'AppxManifest.xml'
if (Test-Path -LiteralPath $manifestPath) { throw 'The schema probe refuses an existing app manifest.' }
$package = Join-Path $temporary ('vex-msix-schema-' + [Guid]::NewGuid().ToString('N') + '.msix')
$created = [Collections.Generic.List[string]]::new()
try {
    foreach ($name in @('StoreLogo.png', 'Square150x150Logo.png', 'Square44x44Logo.png')) {
        $source = Join-Path $PSScriptRoot "../src/Vex.Windows.App/Assets/$name"
        $destination = Join-Path $root "Assets/$name"
        if (Test-Path -LiteralPath $destination) {
            if ((Get-FileHash -LiteralPath $destination).Hash -cne (Get-FileHash -LiteralPath $source).Hash) { throw 'A schema probe asset differs from the release source.' }
        } else {
            Copy-Item -LiteralPath $source -Destination $destination
            $created.Add($destination)
        }
    }
    $template = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../packaging/AppxManifest.xml.template') -Raw
    $manifest = New-WindowsPackageManifest -Template $template -PackageName 'VEX.Native.Windows.SchemaProbe' -Version '0.0.0.1' `
        -Publisher 'CN=VEX Schema Probe' -Architecture $Architecture -VclibsVersion '14.0.24217.0' `
        -DisplayName 'VEX schema probe' -PublisherDisplayName 'VEX'
    [IO.File]::WriteAllText($manifestPath, $manifest, [Text.UTF8Encoding]::new($false))
    $created.Add($manifestPath)
    $makeappx = Resolve-WindowsSdkTool 'makeappx.exe'
    # Full semantic validation stays enabled against the real published app.
    # Nothing is signed, registered, installed, launched or changed in networking.
    & $makeappx pack /d $root /p $package /h SHA256 /o
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $package -PathType Leaf)) { throw 'The Windows SDK rejected the actual package manifest.' }
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($ResultPath), (@{ schema = 'vex.windows-msix-schema.v1'; architecture = $Architecture;
        full_sdk_validation = $true; package_created = $true; installed = $false } | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
} finally {
    foreach ($file in $created) { if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force } }
    if (Test-Path -LiteralPath $package) { Remove-Item -LiteralPath $package -Force }
}
