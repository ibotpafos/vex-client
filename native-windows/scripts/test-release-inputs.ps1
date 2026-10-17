[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$ResultPath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-ReleaseRequiredInputNames {
    @('VEX_WINDOWS_SIGN_PFX_BASE64', 'VEX_WINDOWS_SIGN_PFX_PASSWORD',
        'VEX_WINDOWS_UPDATE_PUBLIC_KEY_BASE64', 'VEX_WINDOWS_UPDATE_PRIVATE_KEY_BASE64',
        'VEX_WINDOWS_PACKAGE_NAME', 'VEX_WINDOWS_PACKAGE_DISPLAY_NAME', 'VEX_WINDOWS_PACKAGE_PUBLISHER',
        'VEX_WINDOWS_PACKAGE_PUBLISHER_DISPLAY_NAME', 'VEX_WINDOWS_PACKAGE_BASE_URI',
        'VEX_WINDOWS_APPINSTALLER_BASE_URI', 'VEX_WINDOWS_UPDATE_KEY_ID', 'VEX_WINDOWS_UPDATE_ORIGIN')
}

function Get-ReleasePresenceInputNames {
    Get-ReleaseRequiredInputNames
    foreach ($prefix in @('VEX_WINDOWS_SERVICE_AMNEZIAWG', 'VEX_WINDOWS_SERVICE_WINTUN', 'VEX_WINDOWS_VCLIBS')) {
        "$($prefix)_PATH"
        foreach ($architecture in @('X64', 'ARM64')) {
            foreach ($kind in @('PATH', 'URI', 'SHA256')) { "$($prefix)_$($kind)_$architecture" }
        }
    }
    'VEX_WINDOWS_SIGN_TIMESTAMP_URI' # Optional: the packager supplies its default.
    'VEX_WINDOWS_SERVICE_MSI_SOURCE' # Explicit opt-in to the pinned official MSI pair.
}

function Get-ReleaseInputPresenceReport {
    param([Parameter(Mandatory = $true)][hashtable]$Presence)
    $missing = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $invalid = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $known = @{}
    foreach ($name in Get-ReleasePresenceInputNames) {
        if (-not $Presence.ContainsKey($name)) { $known[$name] = $false }
        elseif ($Presence[$name] -is [bool]) { $known[$name] = $Presence[$name] }
        elseif ($Presence[$name] -is [string] -and $Presence[$name] -ceq 'true') { $known[$name] = $true }
        elseif ($Presence[$name] -is [string] -and $Presence[$name] -ceq 'false') { $known[$name] = $false }
        else {
            $known[$name] = $false
            $null = $invalid.Add($name) # Constant name only; never retain its value.
        }
    }
    $required = [ordered]@{}
    foreach ($name in Get-ReleaseRequiredInputNames) {
        $required[$name] = $known[$name]
        if (-not $known[$name]) { $null = $missing.Add($name) }
    }
    $runtime = @()
    foreach ($architecture in @('X64', 'ARM64')) {
        $sources = @{}
        foreach ($prefix in @('VEX_WINDOWS_SERVICE_AMNEZIAWG', 'VEX_WINDOWS_SERVICE_WINTUN', 'VEX_WINDOWS_VCLIBS')) {
            $path = "$($prefix)_PATH_$architecture"
            $genericPath = "$($prefix)_PATH"
            $uri = "$($prefix)_URI_$architecture"
            $hash = "$($prefix)_SHA256_$architecture"
            $hasPath = $known[$path] -or $known[$genericPath]
            $builtin = $false
            # Match stage-runtime-assets.ps1: URI takes priority for AWG/Wintun;
            # VCLibs prefers a path, then a custom URI, then Microsoft's default.
            if ($prefix -ceq 'VEX_WINDOWS_VCLIBS' -and $hasPath) { $ready = $true }
            elseif ($known[$uri]) {
                $ready = $known[$hash]
                if (-not $ready) { $null = $missing.Add($hash) }
            }
            elseif ($hasPath) { $ready = $true }
            elseif ($prefix -cne 'VEX_WINDOWS_VCLIBS' -and $known['VEX_WINDOWS_SERVICE_MSI_SOURCE']) { $ready = $true }
            elseif ($prefix -ceq 'VEX_WINDOWS_VCLIBS') { $ready = $true; $builtin = $true }
            else {
                $ready = $false
                foreach ($alternative in @($path, $uri, $hash)) {
                    if (-not $known[$alternative]) { $null = $missing.Add($alternative) }
                }
            }
            $sources[$prefix] = [bool]$ready
            if ($prefix -ceq 'VEX_WINDOWS_VCLIBS') { $sources['builtin'] = $builtin }
        }
        $runtime += [ordered]@{
            architecture = $architecture.ToLowerInvariant()
            amneziawg_source_configured = $sources['VEX_WINDOWS_SERVICE_AMNEZIAWG']
            wintun_source_configured = $sources['VEX_WINDOWS_SERVICE_WINTUN']
            vclibs_source_configured = $sources['VEX_WINDOWS_VCLIBS']
            vclibs_builtin_source = $sources['builtin']
        }
    }
    [ordered]@{
        configured_inputs_ready = ($missing.Count -eq 0 -and $invalid.Count -eq 0)
        required_inputs_present = $required
        runtime_sources = $runtime
        missing_inputs = @($missing | Sort-Object)
        invalid_presence_bindings = @($invalid | Sort-Object)
        timestamp_override_present = $known['VEX_WINDOWS_SIGN_TIMESTAMP_URI']
    }
}

function Get-ReleasePreflightCheckoutCommit {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)
    $git = @(Get-Command git -CommandType Application)[0].Source
    $start = [Diagnostics.ProcessStartInfo]::new($git)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-C', $RepositoryRoot, 'rev-parse', '--verify', 'HEAD')) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    try {
        if (-not $process.WaitForExit(5000)) { $process.Kill($true); throw 'Checkout commit unavailable.' }
        $output = $process.StandardOutput.ReadToEnd().Trim()
        if ($process.ExitCode -ne 0 -or $output -cnotmatch '^[0-9a-f]{40}$') { throw 'Checkout commit unavailable.' }
        return $output
    }
    finally { $process.Dispose() }
}

function Write-ReleaseInputPreflightReceipt {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Report)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Report | ConvertTo-Json -Depth 6) + "`n")
    if ($bytes.Length -gt 16384) { throw 'Preflight receipt exceeds its fixed bound.' }
    $fullPath = [IO.Path]::GetFullPath($Path)
    $directory = [IO.Path]::GetDirectoryName($fullPath)
    $null = [IO.Directory]::CreateDirectory($directory)
    $file = [IO.FileStream]::new($fullPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $file.Write($bytes, 0, $bytes.Length); $file.Flush($true) }
    finally { $file.Dispose() }
}

$report = [ordered]@{
    schema = 'vex.windows-release-input-preflight.v1'
    source_commit = $null
    observed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    configured_inputs_ready = $false
    presence_only = $true
    values_disclosed = $false
    runtime_uri_and_hash_format_verified = $false
    runtime_files_and_architecture_verified = $false
    signing_verified = $false
    public_vpn_verified = $false
    installed_lifecycle_verified = $false
    failure_code = $null
}
try {
    $presence = @{}
    foreach ($name in Get-ReleasePresenceInputNames) {
        # The workflow passes only true/false expressions. Actual secrets and
        # repository variable values never enter this script or the step header.
        $presence[$name] = [Environment]::GetEnvironmentVariable("$($name)_PRESENT")
    }
    $details = Get-ReleaseInputPresenceReport -Presence $presence
    foreach ($key in $details.Keys) { $report[$key] = $details[$key] }
    $report.source_commit = Get-ReleasePreflightCheckoutCommit -RepositoryRoot (Join-Path $PSScriptRoot '../..')
}
catch {
    $report.configured_inputs_ready = $false
    $report.failure_code = 'preflight_observation_failed'
}
try { Write-ReleaseInputPreflightReceipt -Path $ResultPath -Report $report }
catch {
    Write-Output 'Windows release input preflight could not retain its bounded receipt.'
    exit 1
}
if (-not $report.configured_inputs_ready) {
    Write-Output 'Windows release input preflight is not ready; inspect constant missing input names in the receipt.'
    exit 1
}
Write-Output 'Windows release input presence is configured; signing, runtime content and Windows release qualification remain unverified.'
