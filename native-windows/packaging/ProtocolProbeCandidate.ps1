Set-StrictMode -Version Latest

# Probe expectations come from the operator's content-bound dispatch. Missing
# inputs on older callers fail closed; ordinary production QA keeps its contract.
function Assert-ProtocolProbeCandidate {
    param(
        [Parameter(Mandatory)][object]$Artifacts,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Binding,
        [Parameter(Mandatory)][string]$ReleaseRunId,
        [Parameter(Mandatory)][string]$ReleaseSourceCommit,
        [AllowEmptyString()][string]$ConfiguredRootSha256,
        [AllowEmptyString()][string]$ConfiguredLeafSha256
    )
    $keys = @('expected_artifact_digest', 'expected_artifact_id', 'expected_leaf_sha256', 'expected_root_sha256')
    if ((@($Binding.Keys | Sort-Object) -join ',') -cne ($keys -join ',')) { throw 'The protocol probe requires all four exact candidate expectations.' }
    foreach ($key in $keys) {
        if ($Binding[$key] -isnot [string]) { throw 'Protocol probe expectations must be canonical strings.' }
    }
    if ($Binding.expected_artifact_id -cnotmatch '^[1-9][0-9]{0,15}\z' -or
        $Binding.expected_artifact_digest -cnotmatch '^sha256:[a-f0-9]{64}\z' -or
        $Binding.expected_root_sha256 -cnotmatch '^[a-f0-9]{64}\z' -or
        $Binding.expected_leaf_sha256 -cnotmatch '^[a-f0-9]{64}\z' -or
        $ReleaseRunId -cnotmatch '^[1-9][0-9]{0,15}\z' -or $ReleaseSourceCommit -cnotmatch '^[a-f0-9]{40}\z') {
        throw 'Protocol probe candidate expectations are invalid.'
    }
    if ($ConfiguredRootSha256 -cne $Binding.expected_root_sha256 -or $ConfiguredLeafSha256 -cne $Binding.expected_leaf_sha256) {
        throw 'The configured public authority drifted after protocol probe confirmation.'
    }
    if ($Artifacts.total_count -ne @($Artifacts.artifacts).Count) { throw 'Candidate artifact evidence is incomplete.' }
    $matching = @($Artifacts.artifacts | Where-Object name -CEQ 'vex-native-windows-packaged-release')
    if ($matching.Count -ne 1) { throw 'The expected protocol probe artifact is absent or ambiguous.' }
    $artifact = $matching[0]
    if ([string]$artifact.id -cne $Binding.expected_artifact_id -or $artifact.digest -cne $Binding.expected_artifact_digest -or
        $artifact.expired -isnot [bool] -or $artifact.expired -or $artifact.size_in_bytes -le 0 -or $artifact.size_in_bytes -gt 2GB -or
        [DateTimeOffset]::Parse($artifact.expires_at, [Globalization.CultureInfo]::InvariantCulture) -le [DateTimeOffset]::UtcNow -or
        [string]$artifact.workflow_run.id -cne $ReleaseRunId -or $artifact.workflow_run.head_sha -cne $ReleaseSourceCommit -or
        $artifact.workflow_run.head_branch -cne 'main') {
        throw 'The protocol probe artifact drifted from its confirmed immutable identity.'
    }
    return $artifact
}

function Expand-ExpectedProtocolProbeArtifact {
    param(
        [Parameter(Mandatory)][string]$ArchiveDirectory,
        [Parameter(Mandatory)][string]$DestinationDirectory,
        [Parameter(Mandatory)][string]$ExpectedDigest
    )
    if ($ExpectedDigest -cnotmatch '^sha256:[a-f0-9]{64}\z' -or (Test-Path -LiteralPath $DestinationDirectory)) {
        throw 'Protocol probe extraction requires an exact digest and a fresh destination.'
    }
    $entries = @(Get-ChildItem -LiteralPath $ArchiveDirectory -Force)
    if ($entries.Count -ne 1 -or $entries[0] -isnot [IO.FileInfo] -or $entries[0].Extension -ine '.zip' -or
        ($entries[0].Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Expected exactly one downloaded protocol probe ZIP.' }
    # Retain the same read handle through hashing and extraction. On Windows,
    # FileShare.Read also prevents replacement/writes between these operations.
    $stream = [IO.File]::Open($entries[0].FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($stream.Length -le 0 -or $stream.Length -gt 2GB) { throw 'The protocol probe archive is outside its bound.' }
        $digest = 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant()
        if ($digest -cne $ExpectedDigest) { throw 'Downloaded protocol probe bytes differ from the confirmed digest.' }
        $stream.Position = 0
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Read, $true)
        try { [IO.Compression.ZipFileExtensions]::ExtractToDirectory($archive, $DestinationDirectory) }
        finally { $archive.Dispose() }
    } finally { $stream.Dispose() }
}
