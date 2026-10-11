using System.Diagnostics;
using System.Security.Principal;
using System.Text;
using System.Text.Json;

namespace Vex.Windows.Setup;

internal sealed record SetupOperationResult(bool Passed, string FailureCode, bool OperationMayStillBeRunning = false);

internal static class WindowsBootstrapLauncher
{
    private static string SystemPowerShell => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");

    internal static void AssertSignature(string path, string expectedCertificateSha256, CancellationToken cancellationToken = default)
    {
        WindowsPathGuard.AssertFile(path);
        var input = JsonSerializer.SerializeToUtf8Bytes(new { Path = path, CertificateSha256 = expectedCertificateSha256 });
        var command = SignatureCommand.Replace("__INPUT__", Convert.ToBase64String(input), StringComparison.Ordinal);
        var result = InvokeAsync(command, TimeSpan.FromSeconds(30), cancellationToken).GetAwaiter().GetResult();
        if (!result.Passed) throw new InvalidDataException("The release signature is not valid or trusted.");
    }

    internal static Task<SetupOperationResult> InvokeBootstrapAsync(SetupBundle bundle, string action)
    {
        if (action is not ("Install" or "Repair" or "Uninstall")) throw new ArgumentOutOfRangeException(nameof(action));
        using var owner = WindowsIdentity.GetCurrent();
        var ownerSid = owner.User?.Value ?? throw new InvalidDataException("The original Windows owner cannot be identified.");
        var input = JsonSerializer.SerializeToUtf8Bytes(new
        {
            BootstrapPath = bundle.BootstrapPath, MetadataPath = bundle.MetadataPath,
            PackagePath = bundle.PackagePath, BootstrapSha256 = bundle.BootstrapSha256,
            MetadataSha256 = bundle.MetadataSha256, CertificateSha256 = bundle.CertificateSha256,
            SetupPath = Environment.ProcessPath, OwnerSid = ownerSid, Action = action,
            HeldPaths = bundle.LockedPaths,
        });
        var command = BootstrapCommand.Replace("__INPUT__", Convert.ToBase64String(input), StringComparison.Ordinal);
        // Existing package replacement can require two independent UAC phases.
        return InvokeAsync(command, TimeSpan.FromMinutes(10));
    }

    private static async Task<SetupOperationResult> InvokeAsync(string command, TimeSpan deadline, CancellationToken cancellationToken = default)
    {
        var start = new ProcessStartInfo
        {
            FileName = SystemPowerShell, UseShellExecute = false, CreateNoWindow = true,
            WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.System),
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
        };
        start.Environment["PSModulePath"] = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "Modules");
        foreach (var argument in new[] { "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand",
            Convert.ToBase64String(Encoding.Unicode.GetBytes(command)) }) start.ArgumentList.Add(argument);
        using var childJob = new WindowsChildProcessJob();
        using var process = Process.Start(start) ?? throw new InvalidOperationException("The verified bootstrap could not be started.");
        try
        {
            childJob.Attach(process);
            // The literal child's first instruction waits for this token. A
            // parent crash or failed job assignment produces EOF, never UAC.
            await process.StandardInput.WriteLineAsync("vex-setup-job-ready-v1").ConfigureAwait(false);
            process.StandardInput.Close();
        }
        catch
        {
            try { process.Kill(entireProcessTree: true); process.WaitForExit(5000); }
            catch (System.ComponentModel.Win32Exception) { }
            throw;
        }
        var stdout = DrainAsync(process.StandardOutput, 8192);
        var stderr = DrainAsync(process.StandardError, 0);
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        cancellation.CancelAfter(deadline);
        try { await process.WaitForExitAsync(cancellation.Token).ConfigureAwait(false); }
        catch (OperationCanceledException)
        {
            var stopped = false;
            try { process.Kill(entireProcessTree: true); stopped = process.WaitForExit(5000); }
            catch (System.ComponentModel.Win32Exception) { }
            catch (InvalidOperationException) { stopped = process.HasExited; }
            // An elevated UAC operation may outlive the user-token process. Do
            // not offer another action or claim that installation was undone.
            return new(false, "timeout", OperationMayStillBeRunning: !stopped);
        }
        var drains = Task.WhenAll(stdout, stderr);
        if (await Task.WhenAny(drains, Task.Delay(5000)).ConfigureAwait(false) != drains)
            return new(false, "process_output_timeout", OperationMayStillBeRunning: true);
        var output = await stdout.ConfigureAwait(false);
        try
        {
            using var result = JsonDocument.Parse(output.Trim());
            var passed = process.ExitCode == 0 && result.RootElement.GetProperty("passed").GetBoolean();
            var code = result.RootElement.TryGetProperty("failure_code", out var field) ? field.GetString() : null;
            return new(passed, code is "uac_cancelled" or "verification_failed" or "bootstrap_failed" ? code : "bootstrap_failed");
        }
        catch (JsonException) { return new(false, "bootstrap_failed"); }
        catch (InvalidOperationException) { return new(false, "bootstrap_failed"); }
        catch (KeyNotFoundException) { return new(false, "bootstrap_failed"); }
    }

    private static async Task<string> DrainAsync(StreamReader reader, int maximumCapturedCharacters)
    {
        var captured = new StringBuilder();
        var buffer = new char[1024];
        while (true)
        {
            var read = await reader.ReadAsync(buffer.AsMemory()).ConfigureAwait(false);
            if (read == 0) break;
            var keep = Math.Min(read, maximumCapturedCharacters - captured.Length);
            if (keep > 0) captured.Append(buffer, 0, keep);
        }
        return captured.ToString();
    }

    private const string SignatureCommand = """
        if ([Console]::In.ReadLine() -cne 'vex-setup-job-ready-v1') { exit 23 }
        $ErrorActionPreference = 'Stop'
        Set-StrictMode -Version Latest
        # VEX_TRUSTED_POWERSHELL_MODULES_BEGIN
        $systemModules = [IO.Path]::Combine([Environment]::GetFolderPath([Environment+SpecialFolder]::System), 'WindowsPowerShell', 'v1.0', 'Modules')
        $env:PSModulePath = $systemModules
        $requiredCommands = @{'Microsoft.PowerShell.Utility'='Get-FileHash';'Microsoft.PowerShell.Security'='Get-AuthenticodeSignature';'Microsoft.PowerShell.Management'='Get-Content'}
        foreach ($module in $requiredCommands.Keys) {
            $provider = Microsoft.PowerShell.Core\Get-Command -Name ($module + '\' + $requiredCommands[$module]) -CommandType Cmdlet -ListImported -ErrorAction SilentlyContinue
            if ($null -eq $provider) {
                $manifest = [IO.Path]::Combine($systemModules, $module, ($module + '.psd1'))
                if (-not [IO.File]::Exists($manifest)) { $manifest = [IO.Path]::Combine([IO.Path]::GetDirectoryName($systemModules), ($module + '.psd1')) }
                Microsoft.PowerShell.Core\Import-Module -Name $manifest -Force -ErrorAction Stop
            }
        }
        # VEX_TRUSTED_POWERSHELL_MODULES_END
        $inputData = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__INPUT__')) | Microsoft.PowerShell.Utility\ConvertFrom-Json
        try {
            $signature = Microsoft.PowerShell.Security\Get-AuthenticodeSignature -LiteralPath $inputData.Path
            if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or $null -eq $signature.SignerCertificate) { throw 'Invalid signature.' }
            $sha256 = [Security.Cryptography.SHA256]::Create()
            try { $pin = [BitConverter]::ToString($sha256.ComputeHash($signature.SignerCertificate.RawData)).Replace('-', '') }
            finally { $sha256.Dispose() }
            if ($inputData.CertificateSha256 -notmatch '^[a-fA-F0-9]{64}$' -or $pin -ine $inputData.CertificateSha256) { throw 'Invalid signer.' }
            [Console]::Out.WriteLine('{"passed":true,"failure_code":null}')
        }
        catch { [Console]::Out.WriteLine('{"passed":false,"failure_code":"verification_failed"}'); exit 3 }
        """;

    private const string BootstrapCommand = """
        if ([Console]::In.ReadLine() -cne 'vex-setup-job-ready-v1') { exit 23 }
        $ErrorActionPreference = 'Stop'
        Set-StrictMode -Version Latest
        # VEX_TRUSTED_POWERSHELL_MODULES_BEGIN
        $systemModules = [IO.Path]::Combine([Environment]::GetFolderPath([Environment+SpecialFolder]::System), 'WindowsPowerShell', 'v1.0', 'Modules')
        $env:PSModulePath = $systemModules
        $requiredCommands = @{'Microsoft.PowerShell.Utility'='Get-FileHash';'Microsoft.PowerShell.Security'='Get-AuthenticodeSignature';'Microsoft.PowerShell.Management'='Get-Content'}
        foreach ($module in $requiredCommands.Keys) {
            $provider = Microsoft.PowerShell.Core\Get-Command -Name ($module + '\' + $requiredCommands[$module]) -CommandType Cmdlet -ListImported -ErrorAction SilentlyContinue
            if ($null -eq $provider) {
                $manifest = [IO.Path]::Combine($systemModules, $module, ($module + '.psd1'))
                if (-not [IO.File]::Exists($manifest)) { $manifest = [IO.Path]::Combine([IO.Path]::GetDirectoryName($systemModules), ($module + '.psd1')) }
                Microsoft.PowerShell.Core\Import-Module -Name $manifest -Force -ErrorAction Stop
            }
        }
        # VEX_TRUSTED_POWERSHELL_MODULES_END
        $inputData = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__INPUT__')) | Microsoft.PowerShell.Utility\ConvertFrom-Json
        $heldFiles = [Collections.Generic.List[IDisposable]]::new()
        $phase = 'verification'
        try {
            foreach ($path in $inputData.HeldPaths) { $heldFiles.Add([IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)) }
            foreach ($pair in @(@($inputData.BootstrapPath, $inputData.BootstrapSha256), @($inputData.MetadataPath, $inputData.MetadataSha256))) {
                if ([string]$pair[1] -notmatch '^[a-fA-F0-9]{64}$' -or (Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath ([string]$pair[0]) -Algorithm SHA256).Hash -ine [string]$pair[1]) { throw 'Invalid pinned bytes.' }
            }
            foreach ($path in @($inputData.SetupPath, $inputData.BootstrapPath)) {
                $signature = Microsoft.PowerShell.Security\Get-AuthenticodeSignature -LiteralPath $path
                if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or $null -eq $signature.SignerCertificate) { throw 'Invalid signature.' }
                $sha256 = [Security.Cryptography.SHA256]::Create()
                try { $pin = [BitConverter]::ToString($sha256.ComputeHash($signature.SignerCertificate.RawData)).Replace('-', '') }
                finally { $sha256.Dispose() }
                if ($pin -ine $inputData.CertificateSha256) { throw 'Invalid signer.' }
            }
            if ($inputData.Action -notin @('Install','Repair','Uninstall') -or $inputData.OwnerSid -notmatch '^S-1-(?:5-21|12-1)-(\d+-){3}\d+$') { throw 'Invalid action owner.' }
            $phase = 'bootstrap'
            $parameters = @{Phase='User';Action=$inputData.Action;PackagePath=$inputData.PackagePath;MetadataPath=$inputData.MetadataPath;OwnerSid=$inputData.OwnerSid}
            if ($inputData.Action -ne 'Uninstall') { $parameters.RelaunchAfterInstall = $true }
            & $inputData.BootstrapPath @parameters *> $null
            if (-not $?) { throw 'The verified bootstrap failed.' }
            [Console]::Out.WriteLine('{"passed":true,"failure_code":null}')
        }
        catch {
            $code = if ($phase -eq 'verification') { 'verification_failed' } else { 'bootstrap_failed' }
            $exception = $_.Exception
            while ($null -ne $exception) {
                if ($exception -is [ComponentModel.Win32Exception] -and $exception.NativeErrorCode -eq 1223) { $code = 'uac_cancelled'; break }
                $exception = $exception.InnerException
            }
            [Console]::Out.WriteLine(('{"passed":false,"failure_code":"' + $code + '"}'))
            exit 3
        }
        finally { foreach ($heldFile in $heldFiles) { $heldFile.Dispose() } }
        """;
}
