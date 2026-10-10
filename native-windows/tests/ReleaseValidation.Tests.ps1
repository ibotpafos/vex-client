$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path (Join-Path $PSScriptRoot '..') 'packaging/ReleaseValidation.ps1')

function Assert-Throws {
    param([scriptblock]$Action)
    $threw = $false
    try { & $Action } catch { $threw = $true }
    if (-not $threw) { throw 'Expected release validation to reject the fixture.' }
}

foreach ($case in @(
    @{ Value = '1.2'; Expected = '1.2.0.0' },
    @{ Value = '0.1.74'; Expected = '0.1.74.0' },
    @{ Value = '1.2.3.65535'; Expected = '1.2.3.65535' }
)) {
    if ((ConvertTo-WindowsPackageVersion $case.Value) -ne $case.Expected) {
        throw "Incorrect Windows version normalization for '$($case.Value)'."
    }
}
foreach ($version in @('1', '1..2', '1.2.3.4.5', '1.-2', '1.65536', '1.2.99999999999999999999', '1.2;write-host unsafe')) {
    Assert-Throws { ConvertTo-WindowsPackageVersion $version }
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
try {
    foreach ($case in @(
        @{ Architecture = 'x64'; Machine = 0x8664; Other = 'arm64' },
        @{ Architecture = 'arm64'; Machine = 0xAA64; Other = 'x64' }
    )) {
        $bytes = [byte[]]::new(128)
        [BitConverter]::GetBytes([uint16]0x5A4D).CopyTo($bytes, 0)
        [BitConverter]::GetBytes([uint32]64).CopyTo($bytes, 0x3C)
        [BitConverter]::GetBytes([uint32]0x00004550).CopyTo($bytes, 64)
        [BitConverter]::GetBytes([uint16]$case.Machine).CopyTo($bytes, 68)
        $path = Join-Path $temporaryRoot "$($case.Architecture).exe"
        [IO.File]::WriteAllBytes($path, $bytes)
        Assert-WindowsPeArchitecture -Path $path -Architecture $case.Architecture
        Assert-Throws { Assert-WindowsPeArchitecture -Path $path -Architecture $case.Other }
        $bytes[64] = 0
        [IO.File]::WriteAllBytes($path, $bytes)
        Assert-Throws { Assert-WindowsPeArchitecture -Path $path -Architecture $case.Architecture }
        [IO.File]::WriteAllBytes($path, [byte[]]::new(12))
        Assert-Throws { Assert-WindowsPeArchitecture -Path $path -Architecture $case.Architecture }
    }

    $environmentName = "VEX_TEST_RUNTIME_$([Guid]::NewGuid().ToString('N'))"
    try {
        [Environment]::SetEnvironmentVariable($environmentName, 'legacy.exe')
        [Environment]::SetEnvironmentVariable("$($environmentName)_ARM64", 'native-arm64.exe')
        if ((Get-WindowsRuntimeAssetPath -EnvironmentName $environmentName -Architecture 'arm64') -ne 'native-arm64.exe' -or
            (Get-WindowsRuntimeAssetPath -EnvironmentName $environmentName -Architecture 'x64') -ne 'legacy.exe') {
            throw 'Architecture-specific runtime selection failed.'
        }
        [Environment]::SetEnvironmentVariable($environmentName, $null)
        Assert-Throws { Get-WindowsRuntimeAssetPath -EnvironmentName $environmentName -Architecture 'x64' }
    }
    finally {
        [Environment]::SetEnvironmentVariable($environmentName, $null)
        [Environment]::SetEnvironmentVariable("$($environmentName)_ARM64", $null)
    }
}
finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
}

Write-Host 'Windows release version, architecture and runtime selection tests passed.'
