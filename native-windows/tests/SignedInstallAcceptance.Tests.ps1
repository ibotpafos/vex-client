# Import production functions from the AST; never run the Windows-only entrypoint.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
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
