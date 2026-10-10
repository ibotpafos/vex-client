# Execute bounded APPX parsing and dependency admission from the real release
# scripts. Fixture signatures are structural only; release packaging requires
# signtool trust and Windows Add-AppxPackage performs real signature validation.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression.FileSystem
function Assert($condition, $message) { if (-not $condition) { throw $message } }
function Assert-Rejected([scriptblock]$body, $message) {
    $rejected = $false
    try { & $body | Out-Null } catch { $rejected = $true }
    Assert $rejected $message
}
function Import-Functions($path, $names) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    Assert ($errors.Count -eq 0) 'Production dependency script does not parse'
    foreach ($definition in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]}, $false)) {
        if ($definition.Name -in $names) {
            Set-Item ('Function:script:' + $definition.Name) ([scriptblock]::Create($definition.Body.Extent.Text.TrimStart('{').TrimEnd('}')))
        }
    }
}
$bootstrapPath = (Resolve-Path (Join-Path $PSScriptRoot '../scripts/bootstrap-native-windows.ps1')).Path
$packagerPath = (Resolve-Path (Join-Path $PSScriptRoot '../packaging/package-native-windows.ps1')).Path
$temp = Join-Path ([IO.Path]::GetTempPath()) ('vex-vclibs-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temp
$publisher = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
function Write-Fixture($path, $architecture='x64', $name='Microsoft.VCLibs.140.00.UWPDesktop', $version='14.0.33519.0', $framework='true', $fixturePublisher=$publisher, [switch]$NoSignature, [switch]$DuplicateManifest, [switch]$Dtd, [switch]$Oversize) {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    $archive = [IO.Compression.ZipFile]::Open($path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $xml = '<Package><Identity Name="' + $name + '" Publisher="' + $fixturePublisher + '" Version="' + $version + '" ProcessorArchitecture="' + $architecture + '"/><Properties><Framework>' + $framework + '</Framework></Properties></Package>'
        if ($Dtd) { $xml = '<!DOCTYPE Package [<!ENTITY x "true">]>' + $xml.Replace('<Framework>true</Framework>', '<Framework>&x;</Framework>') }
        if ($Oversize) { $xml += (' ' * 1048576) }
        $copies = if ($DuplicateManifest) { 2 } else { 1 }
        for ($i = 0; $i -lt $copies; $i++) {
            $entry = $archive.CreateEntry('AppxManifest.xml')
            $writer = [IO.StreamWriter]::new($entry.Open())
            try { $writer.Write($xml) } finally { $writer.Dispose() }
        }
        if (-not $NoSignature) {
            $writer = [IO.StreamWriter]::new($archive.CreateEntry('AppxSignature.p7x').Open())
            try { $writer.Write('structural fixture, not a trusted signature') } finally { $writer.Dispose() }
        }
    } finally { $archive.Dispose() }
}
try {
    $path = Join-Path $temp 'Microsoft.VCLibs.x64.14.00.Desktop.appx'
    foreach ($source in @($bootstrapPath, $packagerPath)) {
        Import-Functions $source @('Read-VclibsDependencyIdentity')
        Write-Fixture $path
        Assert ((Read-VclibsDependencyIdentity $path x64) -eq '14.0.33519.0') 'Valid Microsoft x64 framework was refused'
        Assert-Rejected { Read-VclibsDependencyIdentity $path arm64 } 'Wrong architecture admitted'
        Write-Fixture $path -architecture arm64
        Assert ((Read-VclibsDependencyIdentity $path arm64) -eq '14.0.33519.0') 'Valid Microsoft ARM64 framework was refused'
        foreach ($arguments in @(
            @{ name='Foreign.Framework' }, @{ fixturePublisher='CN=Foreign Publisher' },
            @{ version='14.0.24216.0' }, @{ version='14.0' }, @{ framework='false' },
            @{ NoSignature=$true }, @{ DuplicateManifest=$true }, @{ Dtd=$true }, @{ Oversize=$true }
        )) {
            Write-Fixture $path @arguments
            Assert-Rejected { Read-VclibsDependencyIdentity $path x64 } ('Malformed framework admitted: ' + ($arguments.Keys -join ','))
        }
    }
    Import-Functions $bootstrapPath @('Read-VclibsDependencyIdentity','Get-VclibsDependencyPath','Assert-Hash','Install-Package')
    Write-Fixture $path
    $script:metadata = [pscustomobject]@{
        architecture='x64'; vclibs_dependency_file=[IO.Path]::GetFileName($path)
        vclibs_dependency_sha256=(Get-FileHash -LiteralPath $path).Hash
        vclibs_dependency_size_bytes=(Get-Item -LiteralPath $path).Length
        vclibs_dependency_version='14.0.33519.0'; package_name='VEX.Fixture'
    }
    $script:installed = $null; $script:queries = 0
    function Get-AppxPackage { param($Name,$ErrorAction) $script:queries++; if ($null -ne $script:installed) { $script:installed } }
    Assert ((Get-VclibsDependencyPath -Metadata $metadata -ScriptsRoot $temp) -eq $path) 'Clean host did not admit pinned dependency'
    $script:installed = [pscustomobject]@{IsFramework=$true; Publisher=$publisher; Architecture='X64'; Version='14.0.40000.0'}
    Assert ($null -eq (Get-VclibsDependencyPath -Metadata $metadata -ScriptsRoot $temp)) 'Newer installed Microsoft runtime would be downgraded'
    $script:installed.Architecture='Arm64'
    Assert ((Get-VclibsDependencyPath -Metadata $metadata -ScriptsRoot $temp) -eq $path) 'Another architecture satisfied dependency'
    $script:installed = $null
    foreach ($field in @('vclibs_dependency_sha256','vclibs_dependency_size_bytes','vclibs_dependency_version')) {
        $old = $metadata.$field
        $metadata.$field = switch ($field) { 'vclibs_dependency_sha256' { '0'*64 } 'vclibs_dependency_size_bytes' { [long]$old+1 } default { '14.0.40000.0' } }
        $before = $script:queries
        Assert-Rejected { Get-VclibsDependencyPath -Metadata $metadata -ScriptsRoot $temp } ('Tampered dependency admitted: '+$field)
        Assert ($script:queries -eq $before) 'Invalid dependency queried installed state before release verification'
        $metadata.$field = $old
    }
    # Clean first installation passes the dependency to the actual production
    # Add-AppxPackage call; tampering never stops the prior controller.
    $script:Action='Install'; $script:mutations=@(); $script:dependencyReceived=$null
    function Assert-OriginalUserContext { }
    function Assert-ReleaseArtifacts { param($Path,$MetadataFile,$ScriptsRoot) $script:metadata }
    function Get-InstalledPackage { param($Name) [pscustomobject]@{InstallLocation='/fixture'; PackageFullName='VEX.Fixture'} }
    function Invoke-ServicePhase { param($ServiceAction,$MetadataFile,$ScriptsRoot,$PackageInstallDirectory) $script:mutations += $ServiceAction }
    function Add-AppxPackage { param($Path,$ForceApplicationShutdown,$ErrorAction,$DependencyPath) $script:mutations += 'Register'; $script:dependencyReceived=$DependencyPath }
    Install-Package -Path '/fixture.msix' -MetadataFile '/fixture.json' -ScriptsRoot $temp
    Assert (($script:mutations -join ',') -eq 'Prepare,Register,Install' -and $script:dependencyReceived.Count -eq 1 -and $script:dependencyReceived[0] -eq $path) 'Real package registration did not receive the verified dependency'
    $script:mutations=@(); $metadata.vclibs_dependency_sha256='0'*64
    Assert-Rejected { Install-Package -Path '/fixture.msix' -MetadataFile '/fixture.json' -ScriptsRoot $temp } 'Tampered dependency reached installation'
    Assert ($script:mutations.Count -eq 0) 'Invalid dependency stopped or mutated an existing installation'
    Write-Output 'VCLibs identity, bounded release pins, architecture and clean-host dependency regressions passed'
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }
