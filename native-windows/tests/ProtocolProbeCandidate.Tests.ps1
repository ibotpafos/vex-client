$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../packaging/ProtocolProbeCandidate.ps1')
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Rejected([scriptblock]$Action) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert $rejected 'Changed or missing confirmed candidate evidence was admitted.'
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('vex-probe-binding-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$workflow = Get-Content -LiteralPath (Join-Path $repo '.github/workflows/native-windows-production-acceptance.yml') -Raw
$match = [regex]::Match($workflow, '(?s)- name: Admit only the exact successful signed main candidate.*?        run: \|\r?\n(?<body>.*?)(?=      - name:)')
Assert $match.Success 'The real workflow admission script was not found.'
$admission = [scriptblock]::Create(($match.Groups['body'].Value -replace '(?m)^          ', ''))
$names = @('GH_TOKEN','RELEASE_RUN_ID','RELEASE_SOURCE_COMMIT','RELEASE_VERSION','QA_PAYLOAD_SHA256','PROTOCOL_PROBE',
    'EXPECTED_ARTIFACT_ID','EXPECTED_ARTIFACT_DIGEST','EXPECTED_ROOT_SHA256','EXPECTED_LEAF_SHA256',
    'VEX_WINDOWS_TEST_ROOT_SHA256','VEX_WINDOWS_TEST_CERT_SHA256','GITHUB_OUTPUT','GITHUB_ENV')
$saved = @{}; foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
$location = Get-Location
$script:originalArtifact = @{ id=87654; name='vex-native-windows-packaged-release'; size_in_bytes=1000
    digest=('sha256:' + ('e' * 64)); expired=$false; expires_at='2099-01-01T00:00:00Z'
    workflow_run=@{id=54321; head_sha=('b' * 40); head_branch='main'} } | ConvertTo-Json -Depth 5
# These strings represent the immutable POST inputs; later observations mutate
# independently. All REST calls below are local stubs, never GitHub requests.
$dispatched = @{ expected_artifact_id='87654'; expected_artifact_digest=('sha256:' + ('e' * 64))
    expected_root_sha256=('a' * 64); expected_leaf_sha256=('c' * 64) }
function Reset-Observation {
    $script:artifact = $script:originalArtifact | ConvertFrom-Json
    $env:GH_TOKEN='inert-test-token'; $env:RELEASE_RUN_ID='54321'; $env:RELEASE_SOURCE_COMMIT=('b' * 40)
    $env:RELEASE_VERSION='0.1.76.0'; $env:QA_PAYLOAD_SHA256=''; $env:PROTOCOL_PROBE='true'
    foreach ($key in $dispatched.Keys) { [Environment]::SetEnvironmentVariable($key.ToUpperInvariant(), $dispatched[$key]) }
    $env:VEX_WINDOWS_TEST_ROOT_SHA256=$dispatched.expected_root_sha256
    $env:VEX_WINDOWS_TEST_CERT_SHA256=$dispatched.expected_leaf_sha256
    $env:GITHUB_OUTPUT=Join-Path $root 'output'; $env:GITHUB_ENV=Join-Path $root 'environment'
    [IO.File]::WriteAllText($env:GITHUB_OUTPUT, ''); [IO.File]::WriteAllText($env:GITHUB_ENV, '')
}
function Invoke-RestMethod {
    param($Uri, $Headers)
    if ($Uri -ceq 'https://api.github.com/repos/ibotpafos/vex-client/actions/runs/54321') {
        return [pscustomobject]@{head_sha=('b' * 40); head_branch='main'; event='workflow_dispatch'
            path='.github/workflows/native-windows-ci.yml'; status='completed'; conclusion='success'}
    }
    if ($Uri -clike '*/54321/jobs?per_page=100') {
        $jobs = @('Portable client and release contracts', 'Windows x64 application and VPN service',
            'Windows arm64 application and VPN service', 'Capture actual macOS interface reference',
            'Windows x64 real encrypted tunnel acceptance', 'Prepare signed Windows release artifacts') |
            ForEach-Object { [pscustomobject]@{name=$_; status='completed'; conclusion='success'} }
        return [pscustomobject]@{total_count=6; jobs=@($jobs)}
    }
    if ($Uri -clike '*/54321/artifacts?per_page=100') { return [pscustomobject]@{total_count=1; artifacts=@($script:artifact)} }
    throw 'Unexpected transport in inert candidate test.'
}
try {
    Set-Location $repo
    foreach ($key in $dispatched.Keys) {
        $mapping = $key.ToUpperInvariant() + ': ${{ inputs.' + $key + ' }}'
        Assert ($workflow.Contains($mapping)) 'A dispatch expectation is not wired into actual workflow admission.'
    }
    Assert ($workflow.Contains('skip-decompress: ${{ inputs.protocol_probe }}')) 'Probes must hash the raw ZIP before extraction.'
    Assert ($workflow.IndexOf('Expand-ExpectedProtocolProbeArtifact') -lt $workflow.IndexOf('- name: Prepare the pinned public beta authority')) 'Exact-byte verification must precede trust installation.'
    Assert ($workflow.Contains('-ExpectedDigest $env:EXPECTED_ARTIFACT_DIGEST')) 'Extraction must consume the dispatch digest.'
    Assert ($workflow.Contains('artifact-ids: ${{ steps.candidate.outputs.artifact_id }}')) 'Download must use the admitted exact ID.'
    Reset-Observation; & $admission
    Assert ((Get-Content $env:GITHUB_OUTPUT -Raw).Trim() -ceq 'artifact_id=87654') 'The workflow selected another artifact.'
    Assert ((Get-Content $env:GITHUB_ENV -Raw).Contains('VEX_WINDOWS_TEST_ROOT_SHA256=' + $dispatched.expected_root_sha256)) 'Trust lost the confirmed root pin.'
    Assert ((Get-Content $env:GITHUB_ENV -Raw).Contains('VEX_WINDOWS_TEST_CERT_SHA256=' + $dispatched.expected_leaf_sha256)) 'Trust lost the confirmed leaf pin.'
    $changes = @(
        { $script:artifact.id=87655 }, { $script:artifact.digest='sha256:' + ('f' * 64) },
        { $env:VEX_WINDOWS_TEST_ROOT_SHA256=('f' * 64) }, { $env:VEX_WINDOWS_TEST_CERT_SHA256=('f' * 64) },
        { $script:artifact.workflow_run.id=54322 }, { $script:artifact.workflow_run.head_sha=('f' * 40) },
        { $script:artifact.expired=$true }, { $script:artifact.expires_at='2000-01-01T00:00:00Z' },
        { $script:artifact.size_in_bytes=0 }, { $script:artifact.size_in_bytes=2GB+1 },
        { $env:EXPECTED_ARTIFACT_ID='' }, { $env:EXPECTED_ARTIFACT_DIGEST='' },
        { $env:EXPECTED_ROOT_SHA256='' }, { $env:EXPECTED_LEAF_SHA256='' },
        { $env:EXPECTED_ROOT_SHA256=('a' * 64) + "`n" }
    )
    foreach ($change in $changes) {
        Reset-Observation; & $change; Assert-Rejected { & $admission }
        Assert ((Get-Item $env:GITHUB_OUTPUT).Length -eq 0 -and (Get-Item $env:GITHUB_ENV).Length -eq 0) 'Failed admission emitted a download ID or trust pins.'
    }
    # Legacy ordinary QA still accepts its existing inputs and never inherits
    # the probe-only expectation requirement or overrides its configured pins.
    Reset-Observation; $env:PROTOCOL_PROBE='false'; $env:QA_PAYLOAD_SHA256=('d' * 64)
    foreach ($key in $dispatched.Keys) { [Environment]::SetEnvironmentVariable($key.ToUpperInvariant(), '') }
    & $admission
    Assert ((Get-Content $env:GITHUB_OUTPUT -Raw).Trim() -ceq 'artifact_id=87654') 'Ordinary QA contract changed.'
    Assert ((Get-Item $env:GITHUB_ENV).Length -eq 0) 'Ordinary QA unexpectedly replaced trust pins.'

    $download = Join-Path $root 'download'; $null = New-Item -ItemType Directory -Path $download
    $zip = Join-Path $download 'candidate.zip'; $payload = Join-Path $root 'source'; $null = New-Item -ItemType Directory -Path $payload
    [IO.File]::WriteAllText((Join-Path $payload 'proof.txt'), 'confirmed bytes')
    [IO.Compression.ZipFile]::CreateFromDirectory($payload, $zip)
    $expected = 'sha256:' + (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    $destination = Join-Path $root 'verified'
    Expand-ExpectedProtocolProbeArtifact -ArchiveDirectory $download -DestinationDirectory $destination -ExpectedDigest $expected
    Assert ((Get-Content (Join-Path $destination 'proof.txt') -Raw) -ceq 'confirmed bytes') 'Exact archive extraction failed.'
    # Simulate replacement after metadata admission: even a valid, newly
    # downloaded ZIP with fresh matching server metadata cannot use the old POST.
    Remove-Item -LiteralPath $zip
    [IO.File]::WriteAllText((Join-Path $payload 'proof.txt'), 'unconfirmed replacement')
    [IO.Compression.ZipFile]::CreateFromDirectory($payload, $zip)
    $refused = Join-Path $root 'refused'
    Assert-Rejected { Expand-ExpectedProtocolProbeArtifact -ArchiveDirectory $download -DestinationDirectory $refused -ExpectedDigest $expected }
    Assert (-not (Test-Path -LiteralPath $refused)) 'Unconfirmed bytes were extracted before digest validation.'
    Write-Host 'Protocol probe candidate contracts passed: actual admission, post-dispatch artifact/pin drift, exact ZIP bytes and legacy QA.'
} finally {
    Set-Location $location
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    Remove-Item -LiteralPath $root -Recurse -Force
}
