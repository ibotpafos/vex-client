Set-StrictMode -Version Latest

function ConvertTo-WindowsPackageVersion {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ($Value.Trim() -notmatch '^\d+\.\d+(?:\.\d+){0,2}$') {
        throw "Windows package version '$Value' must have 2-4 numeric parts."
    }

    $parts = @($Value.Trim().Split('.'))
    $normalized = foreach ($part in $parts) {
        $parsed = 0
        if (-not [int]::TryParse($part, [ref]$parsed) -or $parsed -lt 0 -or $parsed -gt 65535) {
            throw "Windows package version '$Value' components must be between 0 and 65535."
        }
        [string]$parsed
    }
    while ($normalized.Count -lt 4) {
        $normalized += '0'
    }
    return ($normalized -join '.')
}

function Get-WindowsRuntimeAssetPath {
    param(
        [Parameter(Mandatory = $true)][string]$EnvironmentName,
        [Parameter(Mandatory = $true)][ValidateSet('x64', 'arm64')][string]$Architecture
    )

    $architectureName = "$($EnvironmentName)_$($Architecture.ToUpperInvariant())"
    foreach ($name in @($architectureName, $EnvironmentName)) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value.Trim()
        }
    }
    throw "Required runtime asset '$architectureName' (or '$EnvironmentName') is missing."
}

function Assert-WindowsPeArchitecture {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('x64', 'arm64')][string]$Architecture
    )

    $stream = [IO.File]::OpenRead($Path)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5A4D) {
            throw "Runtime asset is not a Windows PE file: $Path"
        }
        $stream.Position = 0x3C
        $headerOffset = $reader.ReadUInt32()
        if ($headerOffset -lt 64 -or $headerOffset -gt ($stream.Length - 24)) {
            throw "Runtime asset has an invalid PE header: $Path"
        }
        $stream.Position = $headerOffset
        if ($reader.ReadUInt32() -ne 0x00004550) {
            throw "Runtime asset has an invalid PE signature: $Path"
        }
        $machine = $reader.ReadUInt16()
        $expectedMachine = if ($Architecture -eq 'arm64') { 0xAA64 } else { 0x8664 }
        if ($machine -ne $expectedMachine) {
            throw ("Runtime asset '$Path' targets PE machine 0x{0:X4}; expected {1}." -f $machine, $Architecture)
        }
    }
    finally {
        $reader.Dispose()
    }
}
