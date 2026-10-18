$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../packaging/TesterSigning.ps1')
function Assert($value, $message) { if (-not $value) { throw $message } }
function Reject([scriptblock]$action) {
    $rejected = $false
    try { $null = & $action } catch { $rejected = $true }
    Assert $rejected 'Unsafe tester signing input was accepted.'
}
$directory = Join-Path $PSScriptRoot '../packaging/tester-trust'
$pins = Get-Content -LiteralPath (Join-Path $directory 'identity.json') -Raw | ConvertFrom-Json
$arguments = @{ ExpectedRootSha256 = $pins.root_sha256; ExpectedLeafSha256 = $pins.leaf_sha256; Publisher = $pins.publisher }
$identity = Get-WindowsTesterSigningIdentity @arguments
Assert ($identity.RootSha256 -ieq $pins.root_sha256 -and $identity.LeafSha256 -ieq $pins.leaf_sha256) 'The public code-signing chain must match both pins.'
Reject { Get-WindowsTesterSigningIdentity -ExpectedRootSha256 ('0' * 64) -ExpectedLeafSha256 $pins.leaf_sha256 -Publisher $pins.publisher }
Reject { Get-WindowsTesterSigningIdentity -ExpectedRootSha256 $pins.root_sha256 -ExpectedLeafSha256 $pins.leaf_sha256 -Publisher 'CN=Different publisher' }
Assert-WindowsTesterSigningScope -Channel stable -Mode public-trusted
Assert-WindowsTesterSigningScope -Channel beta -Mode tester-ca -LeafSha256 $pins.leaf_sha256
Reject { Assert-WindowsTesterSigningScope -Channel stable -Mode tester-ca }
Reject { Assert-WindowsTesterSigningScope -Channel beta -Mode public-trusted -LeafSha256 $pins.leaf_sha256 }
Reject { Assert-WindowsTesterSigningScope -Channel beta -Mode tester-ca -LeafSha256 ('0' * 64) }
Reject { Assert-WindowsTesterSigningScope -Channel beta -Mode unknown }

# The authority must not validate a website certificate purpose, even though it
# is an explicit custom root here. No operating-system store is modified.
$root = [Security.Cryptography.X509Certificates.X509Certificate2]::new([IO.File]::ReadAllBytes($identity.RootPath))
$leaf = [Security.Cryptography.X509Certificates.X509Certificate2]::new([IO.File]::ReadAllBytes($identity.LeafPath))
$chain = [Security.Cryptography.X509Certificates.X509Chain]::new()
try {
    $chain.ChainPolicy.TrustMode = [Security.Cryptography.X509Certificates.X509ChainTrustMode]::CustomRootTrust
    $chain.ChainPolicy.RevocationMode = [Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
    [void]$chain.ChainPolicy.CustomTrustStore.Add($root)
    [void]$chain.ChainPolicy.ApplicationPolicy.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.1'))
    Assert (-not $chain.Build($leaf)) 'The tester authority cannot grant TLS server authentication.'
}
finally { $chain.Dispose(); $leaf.Dispose(); $root.Dispose() }

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('vex-tester-public-assets-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temporary)
try {
    $descriptors = @()
    foreach ($name in @('VEX-Tester-Root.cer', 'VEX-Tester-Signing.cer', 'TESTER-INSTALL.txt')) {
        Copy-Item -LiteralPath (Join-Path $directory $name) -Destination (Join-Path $temporary $name)
        $file = Get-Item -LiteralPath (Join-Path $temporary $name)
        $descriptors += [pscustomobject]@{ file = $name; sha256 = (Get-FileHash -LiteralPath $file.FullName).Hash; size_bytes = $file.Length }
    }
    $metadata = [pscustomobject]@{
        channel = 'beta'; signing_mode = 'tester-ca'; client_certificate_sha256 = $pins.leaf_sha256
        tester_root_sha256 = $pins.root_sha256; tester_leaf_sha256 = $pins.leaf_sha256; publisher = $pins.publisher
        tester_trust_files = $descriptors
    }
    Assert (@(Get-WindowsTesterReleaseAssets -Metadata $metadata -Directory $temporary).Count -eq 3) 'The beta bundle must include exactly the reviewed public trust assets.'
    # Exercise the actual archive writer with the verified public assets. This
    # catches a seven-file-only writer before an expensive signed release run.
    $writerPath = Join-Path $PSScriptRoot '../packaging/publish-native-windows.ps1'
    $tokens = $null; $parseErrors = $null
    $writerAst = [Management.Automation.Language.Parser]::ParseFile($writerPath, [ref]$tokens, [ref]$parseErrors)
    Assert ($parseErrors.Count -eq 0) 'Release publisher does not parse.'
    $definition = @($writerAst.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'New-WindowsInstallBundle' }, $false))
    Assert ($definition.Count -eq 1) 'The real archive writer must be unambiguous.'
    Invoke-Expression $definition[0].Extent.Text
    $core = @(1..7 | ForEach-Object {
        $file = Join-Path $temporary "release-$_.bin"
        [IO.File]::WriteAllText($file, "verified release fixture $_")
        $file
    })
    $public = @(Get-WindowsTesterReleaseAssets -Metadata $metadata -Directory $temporary)
    foreach ($withTrust in @($false, $true)) {
        $archivePath = Join-Path $temporary ("bundle-$withTrust.zip")
        $files = @(if ($withTrust) { $public })
        $bundle = New-WindowsInstallBundle -Files $core -Destination $archivePath -TesterFiles $files
        Assert ($bundle.Sha256 -ceq (Get-FileHash -LiteralPath $archivePath).Hash) 'Bundle hash does not bind the actual archive.'
        $archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
        try {
            $wanted = @($core + $files | ForEach-Object { [IO.Path]::GetFileName($_) } | Sort-Object)
            $actual = @($archive.Entries.FullName | Sort-Object)
            Assert (($actual -join '|') -ceq ($wanted -join '|')) 'The archive omitted public trust assets or included unrelated files.'
        } finally { $archive.Dispose() }
    }
    $rejectedArchive = Join-Path $temporary 'rejected.zip'
    Reject { New-WindowsInstallBundle -Files ($core + $public) -Destination $rejectedArchive }
    Reject { New-WindowsInstallBundle -Files $core -Destination $rejectedArchive -TesterFiles @($public[0]) }
    Reject { New-WindowsInstallBundle -Files $core -Destination $rejectedArchive -TesterFiles @($public[0], $public[0], $public[2]) }
    $unrelated = Join-Path $temporary 'private-key.pfx'; [IO.File]::WriteAllText($unrelated, 'never ship unrelated files')
    Reject { New-WindowsInstallBundle -Files $core -Destination $rejectedArchive -TesterFiles @($public[0], $public[1], $unrelated) }
    Assert (-not (Test-Path -LiteralPath $rejectedArchive)) 'Invalid trust inputs created a release archive.'
    $metadata.channel = 'stable'
    Reject { Get-WindowsTesterReleaseAssets -Metadata $metadata -Directory $temporary }
    $metadata.channel = 'beta'; $metadata.tester_trust_files = $descriptors + $descriptors[0]
    Reject { Get-WindowsTesterReleaseAssets -Metadata $metadata -Directory $temporary }
    $metadata.tester_trust_files = $descriptors
    $guide = Join-Path $temporary 'TESTER-INSTALL.txt'
    [IO.File]::AppendAllText($guide, 'Unreviewed trust instructions')
    $descriptors[2].sha256 = (Get-FileHash -LiteralPath $guide).Hash; $descriptors[2].size_bytes = (Get-Item -LiteralPath $guide).Length
    Reject { Get-WindowsTesterReleaseAssets -Metadata $metadata -Directory $temporary }
    $rootPath = Join-Path $temporary 'VEX-Tester-Root.cer'
    $bytes = [IO.File]::ReadAllBytes($rootPath) + [byte]0
    [IO.File]::WriteAllBytes($rootPath, $bytes)
    Reject { Get-WindowsTesterSigningIdentity @arguments -Directory $temporary }
}
finally { Remove-Item -LiteralPath $temporary -Recurse -Force }

$previousMode = $env:VEX_WINDOWS_SIGNING_MODE; $previousChannel = $env:VEX_WINDOWS_RELEASE_CHANNEL
try {
    $env:VEX_WINDOWS_SIGNING_MODE = 'tester-ca'; $env:VEX_WINDOWS_RELEASE_CHANNEL = 'beta'
    Reject { & (Join-Path $PSScriptRoot '../scripts/prepare-tester-signing-trust.ps1') }
}
finally { $env:VEX_WINDOWS_SIGNING_MODE = $previousMode; $env:VEX_WINDOWS_RELEASE_CHANNEL = $previousChannel }
Write-Output 'Tester signing checks passed: pinned public chain, code-only purpose, beta scope, tamper rejection and closed trust gate.'
