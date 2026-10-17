#requires -Version 7
# Import production functions from the AST; never run the Windows-only entrypoint.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$sourcePath = Join-Path $PSScriptRoot '../scripts/invoke-signed-install-acceptance.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path $sourcePath), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($function in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    Invoke-Expression $function.Extent.Text
}
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Rejected([scriptblock]$Operation, [string]$Message) {
    $rejected = $false
    try { & $Operation | Out-Null } catch { $rejected = $true }
    Assert $rejected $Message
}

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('vex-signed-install-tests-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temporary) | Out-Null
$realInvokeProcess = (Get-Item Function:Invoke-AcceptanceProcess).ScriptBlock
$realInvokeBootstrap = (Get-Item Function:Invoke-AcceptanceBootstrap).ScriptBlock
$realOwnedBundle = (Get-Item Function:Get-AcceptanceOwnedBundle).ScriptBlock
$realRemoveDirectory = (Get-Item Function:Remove-AcceptancePrivateDirectory).ScriptBlock
$realOpenLocks = (Get-Item Function:Open-AcceptanceBundleLocks).ScriptBlock
$realNativeInstall = (Get-Item Function:Invoke-AcceptanceNativeInstall).ScriptBlock
$realReadBundle = (Get-Item Function:Read-AcceptanceBundle).ScriptBlock
try {
    $root = Join-Path $temporary 'bundle'
    [IO.Directory]::CreateDirectory($root) | Out-Null
    $metadata = [ordered]@{
        schema = 'vex.windows-package-output.v2'; architecture = 'x64'; version = '1.2.3.4'
        package_name = 'VEX.Acceptance'; publisher = 'CN=Acceptance Fixture'
        install_entrypoint = 'elevated_bootstrap'; service_ownership = 'manual_sc_bootstrap'
        raw_msix_provisions_service = $false; raw_appinstaller_provisions_service = $false
        package_file = 'fixture.msix'; package_sha256 = ('A' * 64); client_certificate_sha256 = ('B' * 64)
        app_executable_sha256 = ('C' * 64); service_executable_sha256 = ('D' * 64)
        amneziawg_sha256 = ('E' * 64); wintun_sha256 = ('F' * 64); profile_signing_keyring_sha256 = ('0' * 64)
        bootstrap_file = 'bootstrap-native-windows.ps1'; bootstrap_sha256 = ('1' * 64)
        install_service_script_file = 'install-vpn-service.ps1'; install_service_script_sha256 = ('2' * 64)
        uninstall_service_script_file = 'uninstall-vpn-service.ps1'; uninstall_service_script_sha256 = ('3' * 64)
        vclibs_dependency_file = 'Microsoft.VCLibs.x64.14.00.Desktop.appx'; vclibs_dependency_sha256 = ('4' * 64)
        vclibs_dependency_version = '14.0.33728.0'; vclibs_dependency_size_bytes = 123
    }
    $metadataPath = Join-Path $root 'package-metadata.json'
    function Write-TestMetadata { $metadata | ConvertTo-Json | Set-Content -LiteralPath $metadataPath }
    Write-TestMetadata
    $parsed = Read-AcceptanceMetadata $metadataPath
    Assert ($parsed.version -eq '1.2.3.4') 'Valid release metadata was rejected.'
    foreach ($change in @(@('raw_msix_provisions_service', 'false'), @('bootstrap_file', '../bootstrap-native-windows.ps1'),
        @('package_sha256', 'not-a-hash'), @('architecture', 'arm64'), @('version', '1.2.70000.4'))) {
        $original = $metadata[$change[0]]
        $metadata[$change[0]] = $change[1]; Write-TestMetadata
        Assert-Rejected { Read-AcceptanceMetadata $metadataPath } 'Invalid metadata was admitted before script execution.'
        $metadata[$change[0]] = $original
    }
    Write-TestMetadata

    # Use a real bounded ZIP/manifest and hash check, while signature validation
    # is mocked: portable tests cannot manufacture a trusted production signer.
    $package = Join-Path $root $metadata.package_file
    $zip = [IO.Compression.ZipFile]::Open($package, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $entry = $zip.CreateEntry('AppxManifest.xml')
        $writer = [IO.StreamWriter]::new($entry.Open())
        $writer.Write('<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"><Identity Name="VEX.Acceptance" Publisher="CN=Acceptance Fixture" Version="1.2.3.4" ProcessorArchitecture="x64" /></Package>')
        $writer.Dispose()
        $entry = $zip.CreateEntry('AppxSignature.p7x')
        $writer = [IO.StreamWriter]::new($entry.Open()); $writer.Write('portable-test-marker'); $writer.Dispose()
    }
    finally { $zip.Dispose() }
    foreach ($pair in @(@('bootstrap_file', 'bootstrap_sha256'), @('install_service_script_file', 'install_service_script_sha256'),
        @('uninstall_service_script_file', 'uninstall_service_script_sha256'), @('vclibs_dependency_file', 'vclibs_dependency_sha256'))) {
        $path = Join-Path $root $metadata[$pair[0]]
        [IO.File]::WriteAllText($path, 'fixture bytes; never execute')
        $metadata[$pair[1]] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
    $metadata.package_sha256 = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash
    Write-TestMetadata
    $script:signatureChecks = 0
    function Assert-AcceptanceSignature { param($Path, $CertificateSha256) $script:signatureChecks++ }
    $bundle = Read-AcceptanceBundle $root
    Assert ($signatureChecks -eq 4) 'Scripts and MSIX were not all checked before admission.'
    $metadata.publisher = 'CN=Different Publisher'; Write-TestMetadata
    Assert-Rejected { Read-AcceptanceBundle $root } 'Metadata admitted a mismatched actual MSIX publisher.'
    $metadata.publisher = 'CN=Acceptance Fixture'; Write-TestMetadata
    [IO.File]::AppendAllText((Join-Path $root $metadata.bootstrap_file), 'changed after validation')
    Assert-Rejected { Read-AcceptanceBundle $root } 'Modified bootstrap bytes were not rejected.'
    [IO.File]::WriteAllText((Join-Path $root $metadata.bootstrap_file), 'fixture bytes; never execute')

    $candidate = [pscustomobject]@{Metadata = [pscustomobject]@{package_name='VEX.Acceptance';publisher='CN=Acceptance Fixture';client_certificate_sha256=('B'*64);version='1.2.3.5'}}
    $preceding = [pscustomobject]@{Metadata = [pscustomobject]@{package_name='VEX.Acceptance';publisher='CN=Acceptance Fixture';client_certificate_sha256=('B'*64);version='1.2.3.4'}}
    Assert-AcceptanceBundlePair $candidate $preceding
    $preceding.Metadata.version = '1.2.3.5'
    Assert-Rejected { Assert-AcceptanceBundlePair $candidate $preceding } 'Identical versions cannot qualify rollback.'
    $preceding.Metadata.version = '1.2.3.4'; $preceding.Metadata.client_certificate_sha256 = ('C'*64)
    Assert-Rejected { Assert-AcceptanceBundlePair $candidate $preceding } 'A different signer cannot be adopted.'

    # The actual bootstrap argument function revalidates before a fixed system
    # Windows PowerShell User-phase launch, with no preview/relaunch credentials.
    $script:validated = $bundle
    function Read-AcceptanceBundle { param($Directory) $script:validated }
    function Get-AcceptanceSystemPowerShellPath { '/trusted-system/WindowsPowerShell/v1.0/powershell.exe' }
    $script:heldLocks = @()
    function Open-AcceptanceBundleLocks { param($Bundle) $script:heldLocks = @(& $realOpenLocks $Bundle); return $script:heldLocks }
    $script:launch = $null
    function Invoke-AcceptanceProcess {
        param($Executable, $Arguments, $TimeoutSeconds)
        Assert ($heldLocks.Count -eq 6 -and @($heldLocks | Where-Object { $_.SafeFileHandle.IsClosed }).Count -eq 0) 'Metadata and signed input handles were not held through execution.'
        $script:launch = [pscustomobject]@{Executable=$Executable;Arguments=$Arguments}
    }
    & $realInvokeBootstrap -Bundle $bundle -Action Install
    Assert ($launch.Executable -match 'WindowsPowerShell[\\/]v1\.0[\\/]powershell.exe$' -and
        $launch.Arguments -contains 'Bypass' -and $launch.Arguments -contains 'User' -and
        $launch.Arguments -notcontains '-RelaunchAfterInstall') 'Installer did not use verified system PowerShell with original-user registration.'
    Assert (@($heldLocks | Where-Object { -not $_.SafeFileHandle.IsClosed }).Count -eq 0) 'Successful bootstrap leaked input locks.'
    $script:validated = [pscustomobject]@{Metadata=[pscustomobject]@{package_sha256=('0'*64);bootstrap_sha256=$bundle.Metadata.bootstrap_sha256;client_certificate_sha256=$bundle.Metadata.client_certificate_sha256}}
    $script:launch = $null
    Assert-Rejected { & $realInvokeBootstrap -Bundle $bundle -Action Repair } 'Changed inputs were executed.'
    Assert ($null -eq $launch) 'Input mutation launched a child process.'
    Assert (@($heldLocks | Where-Object { -not $_.SafeFileHandle.IsClosed }).Count -eq 0) 'Rejected inputs leaked metadata/script locks.'

    $nativeResult = [pscustomobject]@{
        schema = 'vex.windows-setup-verification.v1'; passed = $true; embedded_metadata_present = $true
        metadata_matches_embedded = $true; bundle_hashes_verified = $true; bootstrap_signature_verified = $true
        setup_signature_verified = $true; architecture = 'x64'; version = '1.2.3.4'; failure_code = $null
    }
    Assert-AcceptanceNativeVerification $nativeResult $bundle.Metadata
    foreach ($flag in @('passed', 'embedded_metadata_present', 'metadata_matches_embedded', 'bundle_hashes_verified',
        'bootstrap_signature_verified', 'setup_signature_verified')) {
        $nativeResult.$flag = $false
        Assert-Rejected { Assert-AcceptanceNativeVerification $nativeResult $bundle.Metadata } 'Unsigned or unbound native setup was admitted.'
        $nativeResult.$flag = $true
    }
    $nativeResult.passed = 'true'
    Assert-Rejected { Assert-AcceptanceNativeVerification $nativeResult $bundle.Metadata } 'A non-boolean verification flag was accepted.'
    $nativeResult.passed = $true; $nativeResult.version = '9.9.9.9'
    Assert-Rejected { Assert-AcceptanceNativeVerification $nativeResult $bundle.Metadata } 'Native verification accepted another package version.'
    $nativeResult.version = '1.2.3.4'
    $setupPath = Join-Path $root 'VEX.Setup.x64.exe'
    [IO.File]::WriteAllText($setupPath, 'portable native setup marker; never execute')
    function Invoke-AcceptanceProcess {
        param($Executable, $Arguments, $TimeoutSeconds)
        Assert ($Executable -ceq $setupPath -and $Arguments[0] -ceq '--verify-bundle' -and
            $Arguments[1] -ceq '--result-path' -and $TimeoutSeconds -eq 180) 'Native verification launched an install action or used an unbounded call.'
        [IO.File]::WriteAllText($Arguments[2], ($nativeResult | ConvertTo-Json))
    }
    $nativeEvidence = Invoke-AcceptanceNativeVerification -Bundle $bundle -PrivateDirectory $temporary
    Assert ($nativeEvidence.bundle_verified -eq $true -and $nativeEvidence.sha256 -ceq
        (Get-FileHash -LiteralPath $setupPath -Algorithm SHA256).Hash -and $nativeEvidence.metadata_sha256 -ceq
        (Get-FileHash -LiteralPath $metadataPath -Algorithm SHA256).Hash) 'Native setup evidence lost the actual image and metadata binding.'
    $nativeResult.metadata_matches_embedded = $false
    Assert-Rejected { Invoke-AcceptanceNativeVerification -Bundle $bundle -PrivateDirectory $temporary } 'A native metadata mismatch was ignored after a zero child exit code.'
    $nativeResult.metadata_matches_embedded = $true

    # UI automation uses the qualified Core host; bootstrap compatibility still
    # uses the fixed system Windows PowerShell asserted above.
    if ($IsWindows) {
        Assert ((Get-AcceptanceUiPowerShellPath) -ceq (Join-Path $PSHOME 'pwsh.exe')) 'The UI probe selected a different or unqualified host.'
    } else {
        Assert-Rejected { Get-AcceptanceUiPowerShellPath } 'The Windows UI host was admitted on another operating system.'
    }
    Assert-Rejected { Invoke-AcceptanceNativeSetupUi -Bundle $bundle -Install -ObserveDownloadedLaunch } 'An observed Shell refusal was admitted as an Install action.'

    # Admission is tested against actual metadata/image hashes with only the
    # existing portable signature boundary mocked. No file is unblocked here.
    $savedRootPin = $env:VEX_WINDOWS_TEST_ROOT_SHA256
    $savedLeafPin = $env:VEX_WINDOWS_TEST_CERT_SHA256
    $originalMetadataBytes = [IO.File]::ReadAllText($metadataPath)
    try {
        $env:VEX_WINDOWS_TEST_ROOT_SHA256 = '5' * 64
        $env:VEX_WINDOWS_TEST_CERT_SHA256 = ('B' * 64).ToLowerInvariant()
        $metadata.channel = 'beta'; $metadata.signing_mode = 'tester-ca'; $metadata.tester_root_sha256 = '5' * 64
        Write-TestMetadata
        $proof = [pscustomobject]@{ bundle_verified = $true; sha256 = (Get-FileHash $setupPath).Hash; metadata_sha256 = (Get-FileHash $metadataPath).Hash }
        $admitted = Get-AcceptanceVerifiedTesterSetup -Bundle $bundle -NativeVerification $proof
        Assert ($admitted.Path -ceq $setupPath) 'The exact verified beta Setup was not admitted.'
        foreach ($change in @(@('sha256', '0' * 64), @('metadata_sha256', '0' * 64), @('bundle_verified', 'true'))) {
            $original = $proof.($change[0]); $proof.($change[0]) = $change[1]
            Assert-Rejected { Get-AcceptanceVerifiedTesterSetup -Bundle $bundle -NativeVerification $proof } 'Unbound or nonboolean beta verification admitted download trust.'
            $proof.($change[0]) = $original
        }
        foreach ($change in @(@('channel', 'stable'), @('signing_mode', 'public-ca'), @('tester_root_sha256', '0' * 64))) {
            $original = $metadata[$change[0]]; $metadata[$change[0]] = $change[1]; Write-TestMetadata
            Assert-Rejected { Get-AcceptanceVerifiedTesterSetup -Bundle $bundle -NativeVerification $proof } 'Stable, foreign or unpinned metadata admitted beta file trust.'
            $metadata[$change[0]] = $original; Write-TestMetadata
        }
        $script:unblockCalls = 0
        function Unblock-File { param($LiteralPath) $script:unblockCalls++; throw 'No portable test may unblock a file.' }
        $guardDenied = $false
        try { Confirm-AcceptanceBetaSetupDownloadTrust -Bundle $bundle -NativeVerification $proof -ExplicitlyDisposable $false }
        catch {
            if ($_.Exception.Message -cne 'Signed install acceptance requires an explicitly disposable GitHub-hosted Windows x64 runner.') { throw }
            $guardDenied = $true
        }
        Assert ($guardDenied -and $unblockCalls -eq 0) 'The explicit disposable-runner guard did not precede beta file trust.'
    } finally {
        Remove-Item Function:Unblock-File -ErrorAction SilentlyContinue
        $env:VEX_WINDOWS_TEST_ROOT_SHA256 = $savedRootPin; $env:VEX_WINDOWS_TEST_CERT_SHA256 = $savedLeafPin
        foreach ($key in @('channel', 'signing_mode', 'tester_root_sha256')) { $metadata.Remove($key) }
        [IO.File]::WriteAllText($metadataPath, $originalMetadataBytes)
    }
    $ownedId = 'a' * 32
    $ownedRoot = Join-Path $temporary ('vex-signed-install-' + $ownedId)
    $ownedCandidate = Join-Path $ownedRoot 'candidate'
    [IO.Directory]::CreateDirectory($ownedCandidate) | Out-Null
    $ownedMarker = Join-Path $ownedRoot 'owned-fixture'
    [IO.File]::WriteAllText($ownedMarker, $ownedId)
    Assert-AcceptanceOwnedCandidate -CandidateRoot $ownedCandidate -RunnerTemp $temporary
    Assert-Rejected { Assert-AcceptanceOwnedCandidate -CandidateRoot $root -RunnerTemp $temporary } 'An ordinary bundle directory was admitted for explicit beta file trust.'
    Assert-Rejected { Assert-AcceptanceOwnedCandidate -CandidateRoot $ownedCandidate -RunnerTemp $root } 'A candidate outside the runner root was admitted.'
    [IO.File]::WriteAllText($ownedMarker, 'b' * 32)
    Assert-Rejected { Assert-AcceptanceOwnedCandidate -CandidateRoot $ownedCandidate -RunnerTemp $temporary } 'A foreign candidate ownership marker was adopted.'
    [IO.File]::WriteAllText($ownedMarker, $ownedId + 'extra')
    Assert-Rejected { Assert-AcceptanceOwnedCandidate -CandidateRoot $ownedCandidate -RunnerTemp $temporary } 'An unbounded ownership marker was admitted.'

    # Real descriptors, byte hashes and ownership guards exercise the complete
    # trust-copy boundary. Mock only Windows admission, ADS and directory ACLs.
    # No installer, Unblock-File, certificate store or Mac quarantine is touched.
    $savedFunctions = @{}
    foreach ($name in @('Assert-AcceptanceRunner', 'New-AcceptancePrivateDirectory',
        'Get-AcceptanceInternetMarker', 'Set-AcceptanceInternetMarker')) {
        $savedFunctions[$name] = (Get-Item ('Function:' + $name)).ScriptBlock
    }
    $savedRunnerTemp = $env:RUNNER_TEMP
    $savedRootPin = $env:VEX_WINDOWS_TEST_ROOT_SHA256; $savedLeafPin = $env:VEX_WINDOWS_TEST_CERT_SHA256
    $originalMetadataBytes = [IO.File]::ReadAllText($metadataPath)
    $savedReadBundle = (Get-Item Function:Read-AcceptanceBundle).ScriptBlock
    Set-Item Function:Read-AcceptanceBundle $realReadBundle
    $script:unblockCalls = 0
    function Unblock-File { param($LiteralPath) $script:unblockCalls++; throw 'Trust must never remove an ADS by path.' }
    function Assert-AcceptanceRunner {
        param([bool]$ExplicitlyDisposable)
        if (-not $ExplicitlyDisposable) { throw 'The test requires explicit disposable admission.' }
    }
    function New-AcceptancePrivateDirectory {
        param([string]$FixtureId)
        $path = Join-Path $env:RUNNER_TEMP ('vex-signed-install-' + $FixtureId)
        if (Test-Path -LiteralPath $path) { throw 'Test private-directory collision.' }
        [IO.Directory]::CreateDirectory($path) | Out-Null
        [IO.File]::WriteAllText((Join-Path $path 'owned-fixture'), $FixtureId)
        return $path
    }
    function Get-AcceptanceInternetMarker {
        param([string]$Path)
        if ($script:trustRace -ceq 'source') {
            $script:trustRaceAttempted = $true
            # Windows denies this writer while the verified source is held. On
            # other hosts, altered bytes must fail the descriptor-copy digest.
            try { [IO.File]::WriteAllText($Path, 'unverified replacement; never execute') } catch {}
        }
        return "[ZoneTransfer]`r`nZoneId=3"
    }
    function Set-AcceptanceInternetMarker {
        param([string]$Path)
        $script:markedCopies.Add($Path)
        if ($script:trustRace -ceq 'destination') {
            $script:trustRaceAttempted = $true
            [IO.File]::WriteAllText((Join-Path (Split-Path $Path -Parent) 'VEX.Setup.x64.exe'), 'unverified destination replacement')
        }
    }
    try {
        $env:RUNNER_TEMP = $temporary
        $env:VEX_WINDOWS_TEST_ROOT_SHA256 = '5' * 64
        $env:VEX_WINDOWS_TEST_CERT_SHA256 = ('B' * 64).ToLowerInvariant()
        $metadata.channel = 'beta'; $metadata.signing_mode = 'tester-ca'; $metadata.tester_root_sha256 = '5' * 64
        Write-TestMetadata
        foreach ($race in @('none', 'source', 'destination')) {
            $sourceId = [Guid]::NewGuid().ToString('N')
            $sourceRoot = New-AcceptancePrivateDirectory $sourceId
            $sourceCandidate = Join-Path $sourceRoot 'candidate'
            [IO.Directory]::CreateDirectory($sourceCandidate) | Out-Null
            foreach ($file in @(Get-ChildItem -LiteralPath $root -File)) {
                Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $sourceCandidate $file.Name)
            }
            $sourceBundle = Read-AcceptanceBundle $sourceCandidate
            $proof = [pscustomobject]@{ bundle_verified=$true
                sha256=(Get-FileHash (Join-Path $sourceCandidate 'VEX.Setup.x64.exe')).Hash
                metadata_sha256=(Get-FileHash $sourceBundle.MetadataPath).Hash }
            $script:trustRace = $race; $script:trustRaceAttempted = $false
            $script:markedCopies = [Collections.Generic.List[string]]::new()
            $copy = $null; $rejected = $false
            try {
                $copy = Confirm-AcceptanceBetaSetupDownloadTrust -Bundle $sourceBundle -NativeVerification $proof -ExplicitlyDisposable $true
                Assert ($race -cne 'destination') 'A replaced destination crossed the trust boundary.'
                Assert ($copy.Bundle.Root -cne $sourceCandidate -and $copy.Handles.Count -eq 7) 'Trust did not retain a separate seven-file owned copy.'
                Assert ((Get-FileHash (Join-Path $copy.Bundle.Root 'VEX.Setup.x64.exe')).Hash -ceq $proof.sha256) 'Unverified replacement bytes became trusted.'
                Assert ($script:markedCopies.Count -eq 6 -and
                    @($script:markedCopies | Where-Object { [IO.Path]::GetFileName($_) -ceq 'VEX.Setup.x64.exe' }).Count -eq 0) 'Trust changed the wrong file markers.'
                Assert ((Get-FileHash (Join-Path $sourceCandidate 'VEX.Setup.x64.exe')).Hash -ceq $proof.sha256) 'Positive trust rewrote the downloaded source.'
            }
            catch {
                if ($race -ceq 'none') { throw }
                $rejected = $true
            }
            finally {
                if ($null -ne $copy) { Close-AcceptanceTrustedCopy $copy }
                Remove-AcceptancePrivateDirectory -Path $sourceRoot -FixtureId $sourceId
            }
            Assert ($race -ceq 'none' -or $script:trustRaceAttempted) 'The injected replacement race did not execute.'
            Assert ($race -cne 'destination' -or $rejected) 'Destination replacement was not rejected before execution.'
        }
        Assert ($script:unblockCalls -eq 0) 'Trust still performs a path-based unblock.'
    }
    finally {
        foreach ($name in $savedFunctions.Keys) { Set-Item ('Function:' + $name) $savedFunctions[$name] }
        Set-Item Function:Read-AcceptanceBundle $savedReadBundle
        Remove-Item Function:Unblock-File -ErrorAction SilentlyContinue
        $env:RUNNER_TEMP = $savedRunnerTemp
        $env:VEX_WINDOWS_TEST_ROOT_SHA256 = $savedRootPin; $env:VEX_WINDOWS_TEST_CERT_SHA256 = $savedLeafPin
        foreach ($key in @('channel', 'signing_mode', 'tester_root_sha256')) { $metadata.Remove($key) }
        [IO.File]::WriteAllText($metadataPath, $originalMetadataBytes)
    }

    # Production cleanup rejects a foreign registered publisher before touching
    # the service or state. An unowned/no-mutation run never invokes uninstall.
    function Get-AppxPackage { param($Name) [pscustomobject]@{Name='VEX.Acceptance';Publisher='CN=Foreign';Version=[version]'1.2.3.4'} }
    Assert-Rejected { & $realOwnedBundle -Bundles @($bundle) -OwnerSid 'S-1-5-21-1-2-3-1001' } 'Foreign package ownership was adopted.'
    $script:ownershipQueries = 0; $script:uninstalls = 0
    function Get-AcceptanceOwnedBundle { param($Bundles, $OwnerSid) $script:ownershipQueries++; return $null }
    function Invoke-AcceptanceBootstrap { param($Bundle, $Action, $RollbackBundle) $script:uninstalls++ }
    Invoke-AcceptanceOwnedCleanup -MutationStarted $false -Bundles @($bundle) -OwnerSid 'owner'
    Assert ($ownershipQueries -eq 0 -and $uninstalls -eq 0) 'No-mutation cleanup touched another installation.'
    Invoke-AcceptanceOwnedCleanup -MutationStarted $true -Bundles @($bundle) -OwnerSid 'owner'
    Assert ($ownershipQueries -eq 1 -and $uninstalls -eq 0) 'Unowned cleanup invoked uninstall.'
    function Get-AcceptanceOwnedBundle { param($Bundles, $OwnerSid) return $bundle }
    function Stop-AcceptanceInstalledApplication { param($Bundle, $OwnerSid) }
    function Invoke-AcceptanceBootstrap { param($Bundle, $Action, $RollbackBundle) Assert ($Action -ceq 'Uninstall') 'Cleanup invoked repair/adoption.'; $script:uninstalls++ }

    # Run the real process deadline against an actual sleeping child, then the
    # independent guarded cleanup function. No Windows installer is executed.
    $executable = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Assert-Rejected { & $realInvokeProcess -Executable $executable -Arguments @('-NoLogo','-NoProfile','-Command','Start-Sleep -Seconds 30') -TimeoutSeconds 1 } 'A stalled phase exceeded its bounded deadline.'
    Invoke-AcceptanceOwnedCleanup -MutationStarted $true -Bundles @($bundle) -OwnerSid 'owner'
    Assert ($watch.Elapsed -lt [TimeSpan]::FromSeconds(8) -and $uninstalls -eq 1) 'A process timeout prevented independent owned cleanup.'

    # A failed real child may emit arbitrary private content. Only the fixed
    # probe marker can reach diagnostics, and a forged suffix must be rejected.
    $marker = 'VEX_SETUP_UI_FAILURE stage=locate_controls exception=RuntimeException native_exit=running'
    $numeric = 'VEX_SETUP_UI_ERROR win32=32 hresult=-2147467259'
    $child = "[Console]::Error.WriteLine('private-child-content-never-upload');[Console]::Error.WriteLine('$marker');[Console]::Error.WriteLine('$marker private=never-upload');[Console]::Error.WriteLine('$numeric');[Console]::Error.WriteLine('$numeric private=never-upload');exit 7"
    $encodedChild = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($child))
    $originalOutput = [Console]::Out
    $captured = [IO.StringWriter]::new()
    try {
        [Console]::SetOut($captured)
        Assert-Rejected { & $realInvokeProcess -Executable $executable -Arguments @('-NoLogo','-NoProfile','-EncodedCommand',$encodedChild) -TimeoutSeconds 5 } 'A failed child was accepted after emitting diagnostics.'
    } finally { [Console]::SetOut($originalOutput) }
    Assert ($captured.ToString().Trim() -ceq ($marker + [Environment]::NewLine + $numeric)) 'Private child output or a forged diagnostic marker escaped.'
    $captured.Dispose()

    # Record OS cancellation only in an explicit non-installing observation.
    # A real Install path/default failure and a possibly running image still fail.
    $shellMarker = 'VEX_SETUP_UI_FAILURE stage=launch exception=Win32Exception native_exit=unknown'
    $shellCode = 'VEX_SETUP_UI_ERROR win32=1223 hresult=-2147467259'
    $shellChild = "[Console]::Error.WriteLine('private-shell-output');[Console]::Error.WriteLine('$shellMarker');[Console]::Error.WriteLine('$shellCode');exit 7"
    $shellEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($shellChild))
    $captured = [IO.StringWriter]::new()
    try {
        [Console]::SetOut($captured)
        Assert-Rejected { & $realInvokeProcess -Executable $executable -Arguments @('-NoLogo','-NoProfile','-EncodedCommand',$shellEncoded) -TimeoutSeconds 5 } 'A cancelled Install child became success by default.'
        $observation = & $realInvokeProcess -Executable $executable -Arguments @('-NoLogo','-NoProfile','-EncodedCommand',$shellEncoded) -TimeoutSeconds 5 -ObserveShellRefusal
        Assert ($observation.ShellRefused -and $observation.Win32Error -eq 1223) 'A bounded window-only OS cancellation was not recorded.'
        $runningChild = $shellChild.Replace('native_exit=unknown', 'native_exit=running')
        $runningEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($runningChild))
        Assert-Rejected { & $realInvokeProcess -Executable $executable -Arguments @('-NoLogo','-NoProfile','-EncodedCommand',$runningEncoded) -TimeoutSeconds 5 -ObserveShellRefusal } 'A possibly running image was adopted as an OS-cancelled launch.'
    } finally { [Console]::SetOut($originalOutput) }
    Assert (-not $captured.ToString().Contains('private-shell-output')) 'Private Shell output escaped diagnostics.'
    $captured.Dispose()

    # Execute the production native lifecycle with UI/install boundaries mocked.
    # Only the actual Install invocation plus independent verification, app and
    # cleanup success can commit consumer-install evidence.
    $script:nativeInstalls = 0; $script:failNativeVerify = $false; $script:failNativeCleanup = $false
    function Invoke-AcceptanceNativeSetupUi {
        param($Bundle, [switch]$Install)
        Assert ([bool]$Install) 'Window-only inspection was mistaken for a native Install action.'
        $script:nativeInstalls++
    }
    function Invoke-AcceptanceBootstrap {
        param($Bundle, $Action, $RollbackBundle)
        if ($Action -ceq 'Verify' -and $script:failNativeVerify) { throw 'Injected independent signature/state verification failure.' }
        Assert ($Action -in @('Verify','Uninstall')) 'Native lifecycle escaped its verified install/cleanup scope.'
    }
    function Invoke-AcceptanceInstalledUi { param($Bundle) }
    function Get-AcceptanceSharedDependencies { 'Microsoft.VCLibs.shared-fixture' }
    function Assert-AcceptanceRemoved {
        param($PackageName, $SharedDependencies)
        if ($script:failNativeCleanup) { throw 'Injected remaining service/state.' }
        Assert ($SharedDependencies -contains 'Microsoft.VCLibs.shared-fixture') 'Native cleanup did not preserve its observed Microsoft framework.'
    }
    function New-NativeEvidence {
        [ordered]@{ phases=[Collections.Generic.List[object]]::new(); native_setup_window_verified=$false
            native_consumer_installation_verified=$false; native_double_click_installer_acceptance=$false }
    }
    $script:failNativeVerify = $true; $proof = New-NativeEvidence
    Assert-Rejected { & $realNativeInstall -Bundle $bundle -OwnerSid 'owner' -Evidence $proof } 'A failed independent Verify was ignored.'
    Assert (-not $proof.native_consumer_installation_verified -and -not $proof.native_double_click_installer_acceptance) 'Native window/action prematurely claimed consumer acceptance.'
    $script:failNativeVerify = $false; $script:failNativeCleanup = $true; $proof = New-NativeEvidence
    Assert-Rejected { & $realNativeInstall -Bundle $bundle -OwnerSid 'owner' -Evidence $proof } 'A failed baseline cleanup was ignored.'
    Assert (-not $proof.native_consumer_installation_verified -and -not $proof.native_double_click_installer_acceptance) 'Remaining service/state falsely qualified native installation.'
    $script:failNativeCleanup = $false; $proof = New-NativeEvidence
    & $realNativeInstall -Bundle $bundle -OwnerSid 'owner' -Evidence $proof
    Assert ($proof.native_consumer_installation_verified -and $proof.native_double_click_installer_acceptance -and
        $proof.native_setup_window_verified -and $proof.phases.Count -eq 5 -and $nativeInstalls -eq 3) 'Complete native consumer installation was not distinguished from window-only smoke.'

    $fixtureId = [Guid]::NewGuid().ToString('N')
    $private = Join-Path $temporary ('vex-signed-install-'+$fixtureId)
    [IO.Directory]::CreateDirectory($private) | Out-Null
    [IO.File]::WriteAllText((Join-Path $private 'owned-fixture'), 'someone-else')
    Assert-Rejected { & $realRemoveDirectory -Path $private -FixtureId $fixtureId } 'An unowned private directory was deleted.'
    Assert (Test-Path -LiteralPath $private) 'Foreign private state was removed.'
    [IO.File]::WriteAllText((Join-Path $private 'owned-fixture'), $fixtureId)
    & $realRemoveDirectory -Path $private -FixtureId $fixtureId
    Assert (-not (Test-Path -LiteralPath $private)) 'Owned input copies were not removed.'

    # Parse the actual Release UI child body as well as the containing wrapper.
    $hereStrings = @($ast.FindAll({param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.Contains('Add-Type -AssemblyName UIAutomationClient')}, $true))
    Assert ($hereStrings.Count -eq 2) 'Installed app and native Setup UI probes are missing or ambiguous.'
    foreach ($probe in $hereStrings) {
        $uiTokens = $null; $uiErrors = $null
        [Management.Automation.Language.Parser]::ParseInput($probe.Value, [ref]$uiTokens, [ref]$uiErrors) | Out-Null
        Assert ($uiErrors.Count -eq 0) 'Actual signed UI probe does not parse.'
    }
    Assert ($ast.Extent.Text -notmatch 'Remove-AppxPackage|\bsc\.exe\b|--signed-out-ui-preview|--focus-pulse-ui-preview') 'Fixture deletes foreign packages/services or launches a Debug preview.'
    Write-Output 'Signed install acceptance metadata, ownership, deadline and cleanup regressions passed'
}
finally { Remove-Item -LiteralPath $temporary -Recurse -Force }
