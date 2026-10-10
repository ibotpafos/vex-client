# Exercise extracted production functions; package/signature/SCM providers are
# mocked. Native Windows checks use only temporary ACLs and a private HKCU key.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$windowsHost = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$scripts = Join-Path $PSScriptRoot '../scripts'
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('vex-installer-safety-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temporary
$owner = if ($windowsHost) { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
         else { 'S-1-5-21-100-200-300-1001' }

function Assert($condition, $message) { if (-not $condition) { throw $message } }
function Assert-Rejected([scriptblock]$body, [string]$message) {
    $rejected = $false
    try { & $body | Out-Null } catch { $rejected = $true }
    Assert $rejected $message
}
function Import-ProductionFunctions([string]$name) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $scripts $name), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    foreach ($definition in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
        # Dot-source into the caller's scope, never execute a production script.
        Set-Item -Path ('Function:script:' + $definition.Name) -Value ([scriptblock]::Create($definition.Body.Extent.Text.TrimStart('{').TrimEnd('}')))
    }
}

try {
    Import-ProductionFunctions 'bootstrap-native-windows.ps1'
    $script:OwnerSid = $owner; $script:Phase = 'User'; $script:Action = 'Install'
    $releaseRoot = Join-Path $temporary 'release'
    $null = New-Item -ItemType Directory -Path $releaseRoot
    $packagePath = Join-Path $releaseRoot 'fixture.msix'
    $originalPackage = [Text.Encoding]::UTF8.GetBytes('unsigned mocked MSIX payload')
    [IO.File]::WriteAllBytes($packagePath, $originalPackage)
    foreach ($name in @('bootstrap-native-windows.ps1', 'install-vpn-service.ps1', 'uninstall-vpn-service.ps1')) {
        [IO.File]::WriteAllText((Join-Path $releaseRoot $name), 'unsigned fixture ' + $name)
    }
    $metadata = [ordered]@{
        schema = 'vex.windows-package-output.v2'; install_entrypoint = 'elevated_bootstrap'
        service_ownership = 'manual_sc_bootstrap'; raw_msix_provisions_service = $false; raw_appinstaller_provisions_service = $false
        package_name = 'VEX.InstallerFixture'; package_file = 'fixture.msix'
        package_sha256 = (Get-FileHash $packagePath).Hash; client_certificate_sha256 = ('A' * 64)
        app_executable_sha256 = ('B' * 64); service_executable_sha256 = ('C' * 64)
        amneziawg_sha256 = ('D' * 64); wintun_sha256 = ('E' * 64); profile_signing_keyring_sha256 = ('F' * 64)
        bootstrap_file = 'bootstrap-native-windows.ps1'; bootstrap_sha256 = (Get-FileHash (Join-Path $releaseRoot 'bootstrap-native-windows.ps1')).Hash
        install_service_script_file = 'install-vpn-service.ps1'; install_service_script_sha256 = (Get-FileHash (Join-Path $releaseRoot 'install-vpn-service.ps1')).Hash
        uninstall_service_script_file = 'uninstall-vpn-service.ps1'; uninstall_service_script_sha256 = (Get-FileHash (Join-Path $releaseRoot 'uninstall-vpn-service.ps1')).Hash
    }
    $script:MetadataPath = Join-Path $releaseRoot 'package-metadata.json'
    [IO.File]::WriteAllText($script:MetadataPath, ($metadata | ConvertTo-Json))
    function Get-CurrentUserSid { $owner }
    $script:signatures = @()
    function Assert-ScriptSignature { param($Path, $ExpectedCertificateSha256) $script:signatures += $Path }
    $validated = Assert-ReleaseArtifacts -Path $packagePath -MetadataFile $MetadataPath -ScriptsRoot $releaseRoot
    Assert ($validated.package_name -eq $metadata.package_name -and $script:signatures.Count -eq 3) 'Release preflight must verify every helper signer'

    $script:phases = @(); $script:registrations = 0; $script:removals = 0; $script:packageQueries = 0; $script:changedRegistration = $false
    function Get-InstalledPackage {
        param($Name, [switch]$ServiceScope)
        $script:packageQueries++
        [pscustomobject]@{
            PackageFullName = $(if ($script:changedRegistration -and $script:packageQueries -gt 1) { 'different-package' } else { 'previous-package' })
            InstallLocation = (Join-Path $temporary 'installed')
        }
    }
    function Invoke-ServicePhase { param($ServiceAction, $MetadataFile, $ScriptsRoot, $PackageInstallDirectory) $script:phases += $ServiceAction }
    function Add-AppxPackage { param($Path, $ForceApplicationShutdown, $ErrorAction, [switch]$ForceUpdateFromAnyVersion) $script:registrations++; throw 'Mocked package registration failure' }
    function Remove-AppxPackage { param($Package, $ErrorAction) $script:removals++ }
    [IO.File]::WriteAllText($packagePath, 'tampered')
    Assert-Rejected { Install-Package -Path $packagePath -MetadataFile $MetadataPath -ScriptsRoot $releaseRoot } 'Invalid package must be rejected before stopping the old service'
    Assert ($script:phases.Count -eq 0 -and $script:registrations -eq 0) 'Invalid release changed installation state'
    [IO.File]::WriteAllBytes($packagePath, $originalPackage)
    Assert-Rejected { Install-Package -Path $packagePath -MetadataFile $MetadataPath -ScriptsRoot $releaseRoot } 'Registration failure must propagate'
    Assert (($script:phases -join ',') -eq 'Prepare,Restore' -and $script:removals -eq 0) 'Registration failure must restore the unchanged previous service'
    $script:phases = @(); $script:packageQueries = 0; $script:changedRegistration = $true
    Assert-Rejected { Install-Package -Path $packagePath -MetadataFile $MetadataPath -ScriptsRoot $releaseRoot } 'Ambiguous registration failure must propagate'
    Assert (($script:phases -join ',') -eq 'Prepare') 'A changed package must never restore an unrelated service'

    $script:Action = 'Rollback'; $script:RollbackPackagePath = $packagePath; $script:RollbackMetadataPath = $MetadataPath
    $script:RelaunchAfterInstall = $false; $script:rollbackInstalls = 0
    function Uninstall-Package { param($Metadata) throw 'Rollback must not unregister the current package' }
    function Install-Package {
        param($Path, $MetadataFile, $ScriptsRoot, [switch]$ForceUpdate)
        Assert $ForceUpdate 'Rollback must use the explicit in-place downgrade path'
        $script:rollbackInstalls++
    }
    [IO.File]::WriteAllText($packagePath, 'tampered rollback')
    Assert-Rejected { Invoke-PackageRollback } 'Tampered rollback must be refused before installation changes'
    Assert ($script:rollbackInstalls -eq 0) 'Tampered rollback reached replacement'
    [IO.File]::WriteAllBytes($packagePath, $originalPackage)
    Invoke-PackageRollback
    Assert ($script:rollbackInstalls -eq 1 -and $script:removals -eq 0) 'Rollback must preserve existing registration and state'

    Import-ProductionFunctions 'bootstrap-native-windows.ps1'
    $script:dataDirectory = Join-Path $temporary 'VEX/VPN'
    $installDirectory = Join-Path $temporary 'installed'
    $null = New-Item -ItemType Directory -Path $script:dataDirectory -Force
    $null = New-Item -ItemType Directory -Path $installDirectory -Force
    function Get-VexDataDirectory { $script:dataDirectory }
    function Get-CurrentUserSid { $owner }
    function Assert-PrivateStateAcl { param($Path) }
    function Assert-AuthorizationToken { param($Path) }
    function Assert-ScriptSignature { param($Path, $ExpectedCertificateSha256) }
    $pins = [ordered]@{
        'owner-sid' = $owner; 'client-cert-sha256' = $metadata.client_certificate_sha256
        'app-executable-sha256' = $metadata.app_executable_sha256; 'service-executable-sha256' = $metadata.service_executable_sha256
        'amneziawg-sha256' = $metadata.amneziawg_sha256; 'wintun-sha256' = $metadata.wintun_sha256
        'profile-signing-keys-sha256' = $metadata.profile_signing_keyring_sha256
    }
    foreach ($pair in @(@('Vex.Windows.App.exe', 'app_executable_sha256'), @('Vex.Windows.Service.exe', 'service_executable_sha256'),
        @('amneziawg.exe', 'amneziawg_sha256'), @('wintun.dll', 'wintun_sha256'), @('profile-signing-keys.json', 'profile_signing_keyring_sha256'))) {
        $path = Join-Path $installDirectory $pair[0]
        [IO.File]::WriteAllText($path, 'fixture ' + $pair[0])
        $metadata[$pair[1]] = (Get-FileHash $path).Hash
    }
    $pins['app-executable-sha256'] = $metadata.app_executable_sha256; $pins['service-executable-sha256'] = $metadata.service_executable_sha256
    $pins['amneziawg-sha256'] = $metadata.amneziawg_sha256; $pins['wintun-sha256'] = $metadata.wintun_sha256
    $pins['profile-signing-keys-sha256'] = $metadata.profile_signing_keyring_sha256
    foreach ($name in $pins.Keys) { [IO.File]::WriteAllText((Join-Path $script:dataDirectory $name), $pins[$name]) }
    [IO.File]::WriteAllBytes((Join-Path $script:dataDirectory 'ipc-token.bin'), [byte[]]::new(32))
    $stored = @{} + $metadata; $stored.schema = 'vex.windows-service-bootstrap.v1'; $stored.owner_sid = $owner
    [IO.File]::WriteAllText((Join-Path $script:dataDirectory 'bootstrap-state.json'), ($stored | ConvertTo-Json))
    $script:configuration = [pscustomobject]@{ ImagePath = '"' + (Join-Path $installDirectory 'Vex.Windows.Service.exe') + '"'; ObjectName = 'LocalSystem'; Start = 2; DelayedAutoStart = 1; Type = 16; FailureActionsOnNonCrashFailures = 1 }
    $script:machinePins = [pscustomobject]@{ ClientCertificateSha256 = $metadata.client_certificate_sha256; ServiceExecutableSha256 = $metadata.service_executable_sha256 }
    function Get-ItemProperty { param($LiteralPath, $ErrorAction) if ($LiteralPath -match 'CurrentControlSet') { $script:configuration } else { $script:machinePins } }
    $script:disposed = 0
    function Get-Service {
        param($Name, $ErrorAction)
        $service = [pscustomobject]@{ Status = [ServiceProcess.ServiceControllerStatus]::Running }
        $service | Add-Member ScriptMethod Dispose { $script:disposed++ }
        $service
    }
    Assert-InstalledState -Metadata ([pscustomobject]$metadata) -InstallDirectory $installDirectory
    foreach ($name in $pins.Keys) {
        [IO.File]::WriteAllText((Join-Path $script:dataDirectory $name), 'wrong')
        Assert-Rejected { Assert-InstalledState -Metadata ([pscustomobject]$metadata) -InstallDirectory $installDirectory } "Verify accepted a wrong $name"
        [IO.File]::WriteAllText((Join-Path $script:dataDirectory $name), $pins[$name])
    }
    $script:configuration.ImagePath += ' --foreign'
    Assert-Rejected { Assert-InstalledState -Metadata ([pscustomobject]$metadata) -InstallDirectory $installDirectory } 'Verify accepted unexpected SCM arguments'
    $script:configuration.ImagePath = '"' + (Join-Path $installDirectory 'Vex.Windows.Service.exe') + '"'
    $script:machinePins.ServiceExecutableSha256 = 'wrong'
    Assert-Rejected { Assert-InstalledState -Metadata ([pscustomobject]$metadata) -InstallDirectory $installDirectory } 'Verify accepted incorrect machine attestation pins'
    $script:machinePins.ServiceExecutableSha256 = $metadata.service_executable_sha256
    Assert ($script:disposed -eq 1) 'Successful Verify must dispose its service handle'

    Import-ProductionFunctions 'install-vpn-service.ps1'
    $script:serviceName = 'Fixture SCM Provider'
    $script:stopCalls = 0; $script:waitMilliseconds = 0; $script:disposed = 0
    function Stop-Service { param($Name, $ErrorAction) $script:stopCalls++ }
    function Get-Service {
        param($Name, $ErrorAction)
        $service = [pscustomobject]@{ Status = [ServiceProcess.ServiceControllerStatus]::Running }
        $service | Add-Member ScriptMethod WaitForStatus { param($Status,$Timeout) $script:waitMilliseconds = $Timeout.TotalMilliseconds }
        $service | Add-Member ScriptMethod Dispose { $script:disposed++ }
        $service
    }
    Stop-ServiceBeforeProvisioning
    Assert ($script:stopCalls -eq 1 -and $script:waitMilliseconds -eq 30000 -and $script:disposed -eq 1) 'Repair must wait for controller stop with a bounded disposed handle'
    function Stop-Service { param($Name,$ErrorAction) throw 'Mock stop failure' }
    Assert-Rejected { Stop-ServiceBeforeProvisioning } 'A failed stop must prevent authorization replacement'
    Assert ($script:disposed -eq 2) 'Failed stop leaked a service handle'

    # Execute the actual production mutation tail with harmless providers.
    $installSource = [IO.File]::ReadAllText((Join-Path $scripts 'install-vpn-service.ps1'))
    $tail = [scriptblock]::Create($installSource.Substring($installSource.LastIndexOf("`nAssert-Administrator")))
    $script:mutationOrder = @()
    function Assert-Administrator { }
    function Assert-InstallPayload { }
    function Get-PrivateStateItems { }
    function Stop-ServiceBeforeProvisioning { $script:mutationOrder += 'stop' }
    function Set-PrivateDirectoryAcl { }
    function Assert-PrivateDirectoryAcl { }
    function Write-ProtectedAuthorization { $script:mutationOrder += 'authorization' }
    function Write-Pin { param($Name,$Value) $script:mutationOrder += 'pin' }
    function Write-ClientAttestationPins { }
    function Install-Service { $script:mutationOrder += 'start' }
    $script:ClientCertificateSha256 = $metadata.client_certificate_sha256; $script:AppExecutableSha256 = $metadata.app_executable_sha256
    $script:ServiceExecutableSha256 = $metadata.service_executable_sha256; $script:AmneziaExecutableSha256 = $metadata.amneziawg_sha256
    $script:WintunSha256 = $metadata.wintun_sha256; $script:ProfileSigningKeyringSha256 = $metadata.profile_signing_keyring_sha256
    & $tail
    Assert ($script:mutationOrder[0] -eq 'stop' -and $script:mutationOrder[1] -eq 'authorization' -and $script:mutationOrder[-1] -eq 'start') 'Live authorization changed before stopping the controller'
    $script:mutationOrder = @()
    function Stop-ServiceBeforeProvisioning { throw 'Mock stop failure' }
    Assert-Rejected { & $tail } 'Provisioning must fail when the old controller cannot stop'
    Assert ($script:mutationOrder.Count -eq 0) 'Failed stop changed authorization or restarted service'

    Import-ProductionFunctions 'uninstall-vpn-service.ps1'
    $script:serviceProbes = 0; $script:disposed = 0
    function Get-Service {
        param($Name,$ErrorAction)
        $script:serviceProbes++
        if ($script:serviceProbes -gt 1) { return }
        $service = [pscustomobject]@{}
        $service | Add-Member ScriptMethod Dispose { $script:disposed++ }
        $service
    }
    Wait-ServiceRemoved -Name 'private vendor fixture'
    Assert ($script:serviceProbes -eq 2 -and $script:disposed -eq 1) 'Vendor cleanup must wait for actual service absence'
    $script:serviceProbes = 0
    Assert-Rejected { Wait-ServiceRemoved -Name 'private vendor fixture' -TimeoutSeconds 0 } 'An undeleted service must not report cleanup success'
    $script:timedOut = $false; $script:vendorExit = 0; $script:vendorWaits = @(); $script:vendorKills = 0; $script:vendorDisposed = 0
    function Start-Process {
        param($FilePath, $ArgumentList, [switch]$PassThru, $WindowStyle, $ErrorAction)
        Assert ($ArgumentList -eq '/uninstalltunnelservice vex') 'Vendor removal must target only the owned tunnel'
        $process = [pscustomobject]@{ ExitCode = $script:vendorExit }
        $process | Add-Member ScriptMethod WaitForExit { param($Milliseconds) $script:vendorWaits += $Milliseconds; return -not $script:timedOut }
        $process | Add-Member ScriptMethod Kill { $script:vendorKills++ }
        $process | Add-Member ScriptMethod Dispose { $script:vendorDisposed++ }
        $process
    }
    Invoke-VendorRemoval -Executable 'isolated-vendor-fixture.exe'
    Assert ($script:vendorWaits[0] -eq 30000 -and $script:vendorDisposed -eq 1) 'Vendor process wait must be bounded and disposed'
    $script:timedOut = $true
    Assert-Rejected { Invoke-VendorRemoval -Executable 'isolated-vendor-fixture.exe' } 'Hung vendor removal must fail rather than deleting cleanup state'
    Assert ($script:vendorKills -eq 1 -and $script:vendorWaits[-1] -eq 5000 -and $script:vendorDisposed -eq 2) 'Timed-out owned vendor process must be terminated with a bounded wait'
    $script:timedOut = $false; $script:vendorExit = 1
    Assert-Rejected { Invoke-VendorRemoval -Executable 'isolated-vendor-fixture.exe' } 'Failed vendor removal must not report success'

    if ($windowsHost) {
        # Re-import actual ACL and DPAPI functions; no mock may stand in for these.
        Import-ProductionFunctions 'install-vpn-service.ps1'
        $privateDirectory = Join-Path $script:dataDirectory 'Private'
        $null = New-Item -ItemType Directory -Path $privateDirectory
        $privateConfig = Join-Path $privateDirectory 'vex.conf'
        [IO.File]::WriteAllText($privateConfig, 'fixture-private-material')
        Set-PrivateDirectoryAcl
        Assert-PrivateDirectoryAcl
        foreach ($path in @($privateDirectory, $privateConfig)) {
            $privateRules = @((Get-Acl -LiteralPath $path).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
            Assert ($privateRules.Count -eq 2 -and $owner -notin @($privateRules | ForEach-Object { $_.IdentityReference.Value })) 'Private tunnel material must remain readable only by SYSTEM and Administrators'
        }
        $privateAcl = Get-Acl -LiteralPath $privateConfig
        $privateAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($owner, 'ReadAndExecute', [Security.AccessControl.AccessControlType]::Allow))
        Set-Acl -LiteralPath $privateConfig -AclObject $privateAcl
        Assert-Rejected { Assert-PrivateDirectoryAcl } 'Owning-user access to private tunnel material must be rejected'
        Set-PrivateDirectoryAcl
        Assert-PrivateDirectoryAcl
        $extra = [Security.AccessControl.FileSystemAccessRule]::new('Everyone', 'FullControl', [Security.AccessControl.AccessControlType]::Allow)
        $file = Join-Path $script:dataDirectory 'ipc-token.bin'
        $acl = Get-Acl $file; $acl.AddAccessRule($extra); Set-Acl $file $acl
        Assert-Rejected { Assert-PrivateDirectoryAcl } 'An explicit broad child ACL must be rejected'
        Set-PrivateDirectoryAcl
        Assert-PrivateDirectoryAcl
        $outside = Join-Path $temporary 'outside'; $null = New-Item -ItemType Directory $outside
        $link = Join-Path $script:dataDirectory 'redirect'; $null = New-Item -ItemType Junction -Path $link -Target $outside
        try { Assert-Rejected { Set-PrivateDirectoryAcl } 'A redirected state child must be rejected before ACL mutation' }
        finally { [IO.Directory]::Delete($link) }

        Import-ProductionFunctions 'bootstrap-native-windows.ps1'
        $validToken = [Security.Cryptography.ProtectedData]::Protect([byte[]]::new(32), [Text.Encoding]::UTF8.GetBytes('VEX VPN IPC v1'), [Security.Cryptography.DataProtectionScope]::LocalMachine)
        [IO.File]::WriteAllBytes($file, $validToken)
        Assert-AuthorizationToken -Path $file
        [IO.File]::WriteAllBytes($file, [byte[]]::new(3))
        Assert-Rejected { Assert-AuthorizationToken -Path $file } 'Corrupt machine DPAPI authorization must be rejected'

        Import-ProductionFunctions 'uninstall-vpn-service.ps1'
        $script:registryFixture = 'Software\VexInstallerSafety\' + [guid]::NewGuid().ToString('N')
        function Open-MachinePinRegistry { [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryView]::Registry64) }
        function Get-MachinePinRegistryPath { $script:registryFixture }
        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($script:registryFixture)
        try {
            $key.SetValue('ClientCertificateSha256', $metadata.client_certificate_sha256)
            $key.SetValue('ServiceExecutableSha256', 'foreign')
            $key.SetValue('UnrelatedValue', 'preserve')
            Assert-Rejected { Get-OwnedMachinePins -Remove } 'Foreign machine pins must be preserved'
            Assert ($key.GetValue('ClientCertificateSha256') -eq $metadata.client_certificate_sha256) 'Foreign-pin rejection partially deleted an owned value'
            $key.SetValue('ServiceExecutableSha256', $metadata.service_executable_sha256)
            Get-OwnedMachinePins -Remove
            Assert ($null -eq $key.GetValue('ClientCertificateSha256') -and $null -eq $key.GetValue('ServiceExecutableSha256') -and
                $key.GetValue('UnrelatedValue') -eq 'preserve') 'Uninstall must remove only exact owned attestation values'
        }
        finally { $key.Dispose(); [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($script:registryFixture, $false) }
        Write-Host 'Native isolated Windows ACL, DPAPI and registry checks passed.'
    }
    else { Write-Host 'Native ACL, DPAPI and registry checks deferred to the disposable Windows CI host.' }
    Write-Host 'Installer safety regressions passed: rollback, failed registration recovery, release preflight, truthful Verify, stop-before-pins and bounded vendor cleanup.'
}
finally { Remove-Item -LiteralPath $temporary -Recurse -Force }
