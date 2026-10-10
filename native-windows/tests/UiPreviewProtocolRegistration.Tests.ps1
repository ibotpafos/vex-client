[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../src/Vex.Windows.App/Services/UiPreviewProtocolRegistration.cs') -Raw
$source = $source.Replace('namespace Vex.Windows.App.Services;', 'namespace Vex.Windows.PreviewProtocolTests;')
$scheme = 'vex-ui-preview-test-' + [guid]::NewGuid().ToString('N')
$testSource = @"
#nullable enable
using System;
using System.IO;
using System.Linq;
$source
internal static class UiPreviewContext {
    internal const string ProtocolScheme = "$scheme";
    internal static bool IsEnabled => true;
}
public static class ProtocolTestHarness {
    public static string Scheme => UiPreviewContext.ProtocolScheme;
    public static string Executable => Path.GetFullPath(Environment.ProcessPath!);
    public static string DiagnosticPath => UiPreviewProtocolRegistration.DiagnosticPath;
    public static void Register() => UiPreviewProtocolRegistration.Register();
    public static void Unregister() => UiPreviewProtocolRegistration.Unregister();
    public static void CreateLink(string targetName) {
        using var identity = WindowsIdentity.GetCurrent();
        var target = @"\Registry\User\" + identity.User!.Value + "_Classes\\" + targetName;
        using var parent = Registry.CurrentUser.OpenSubKey(@"Software\Classes", writable: true)!;
        var status = RegCreateKeyEx(parent.Handle, Scheme, 0, null, 2, 0xf003f, 0, out var link, out var disposition);
        using (link) {
            if (status != 0) throw new Win32Exception(status);
            if (disposition != 1) throw new InvalidOperationException("Test link baseline changed.");
            var bytes = System.Text.Encoding.Unicode.GetBytes(target);
            status = RegSetValueEx(link, "SymbolicLinkValue", 0, 6, bytes, bytes.Length);
            if (status != 0) throw new Win32Exception(status);
        }
    }
    public static void DeleteLink() {
        using var parent = Registry.CurrentUser.OpenSubKey(@"Software\Classes", writable: true)!;
        var status = RegOpenKeyEx(parent.Handle, Scheme, 8, 0x10000, out var link);
        using (link) {
            if (status == 2) return;
            if (status != 0) throw new Win32Exception(status);
            if (NtDeleteKey(link) != 0) throw new InvalidOperationException("Test registry link cleanup failed.");
        }
    }
    [DllImport("advapi32.dll", EntryPoint = "RegCreateKeyExW", CharSet = CharSet.Unicode)]
    private static extern int RegCreateKeyEx(SafeRegistryHandle parent, string path, uint reserved,
        string? keyClass, uint options, uint access, nint security, out SafeRegistryHandle key, out uint disposition);
    [DllImport("advapi32.dll", EntryPoint = "RegSetValueExW", CharSet = CharSet.Unicode)]
    private static extern int RegSetValueEx(SafeRegistryHandle key, string name, uint reserved, uint type, byte[] value, int size);
    [DllImport("advapi32.dll", EntryPoint = "RegOpenKeyExW", CharSet = CharSet.Unicode)]
    private static extern int RegOpenKeyEx(SafeRegistryHandle parent, string path, uint options, uint access, out SafeRegistryHandle key);
    [DllImport("ntdll.dll")] private static extern int NtDeleteKey(SafeRegistryHandle key);
}
"@
Add-Type -TypeDefinition $testSource -CompilerOptions '/define:DEBUG'
if (-not $IsWindows) {
    Write-Host 'Actual preview protocol helper compiled; native registration/ownership/link tests require Windows.'
    return
}

$keyPath = 'Registry::HKEY_CURRENT_USER\Software\Classes\' + $scheme
$targetName = $scheme + '-target'
$targetPath = 'Registry::HKEY_CURRENT_USER\Software\Classes\' + $targetName
$diagnosticPath = [Vex.Windows.PreviewProtocolTests.ProtocolTestHarness]::DiagnosticPath
if (Test-Path -LiteralPath $keyPath) { throw 'Native protocol test requires an absent unique scheme.' }
$linkCreated = $false
$marker = [guid]::NewGuid().ToString('N')
function Assert-Rejected {
    param([scriptblock]$Operation, [string]$Failure)
    $rejected = $false
    try { & $Operation } catch { $rejected = $true }
    if (-not $rejected) { throw $Failure }
}
try {
    [Vex.Windows.PreviewProtocolTests.ProtocolTestHarness]::Register()
    if (-not (Test-Path -LiteralPath $keyPath)) { throw 'Native helper did not create its unique shell registration.' }
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(('Software\Classes\' + $scheme), $true)
    if ($null -eq $key) { throw 'Native test could not open its owned registration for mutation.' }
    try {
        $executable = [Vex.Windows.PreviewProtocolTests.ProtocolTestHarness]::Executable
        if ($key.GetValue('VexUiPreviewOwner') -cne $executable) { throw 'Native protocol owner does not match this executable.' }
        $key.SetValue('VexUiPreviewOwner', 'foreign-owner')
        Assert-Rejected { [Vex.Windows.PreviewProtocolTests.ProtocolTestHarness]::Unregister() } 'Native protocol cleanup accepted a foreign owner.'
        if ($key.GetValue('VexUiPreviewOwner') -cne 'foreign-owner') { throw 'Native protocol cleanup mutated foreign ownership.' }
        $key.SetValue('VexUiPreviewOwner', $executable)
    }
    finally { $key.Dispose() }
    [Vex.Windows.PreviewProtocolTests.ProtocolTestHarness]::Unregister()
    if (Test-Path -LiteralPath $keyPath) { throw 'Native protocol cleanup left its owned scheme.' }

    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey(('Software\Classes\' + $scheme), $true)
    try { $key.SetValue('TestMarker', $marker) } finally { $key.Dispose() }
    Assert-Rejected { [Vex.Windows.PreviewProtocolTests.ProtocolTestHarness]::Register() } 'Native protocol registration overwrote an existing scheme.'
    $key = Get-Item -LiteralPath $keyPath
    try {
        if ($key.ValueCount -ne 1 -or $key.GetValue('TestMarker') -cne $marker) { throw 'Native registration changed a foreign baseline.' }
    }
    finally { $key.Dispose() }
    Remove-Item -LiteralPath $keyPath

    $target = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey(('Software\Classes\' + $targetName), $true)
    try { $target.SetValue('TestMarker', $marker) } finally { $target.Dispose() }
    [Vex.Windows.PreviewProtocolTests.ProtocolTestHarness]::CreateLink($targetName)
    $linkCreated = $true
    Assert-Rejected { [Vex.Windows.PreviewProtocolTests.ProtocolTestHarness]::Register() } 'Native registration followed a registry link.'
    $target = Get-Item -LiteralPath $targetPath
    try {
        if ($target.ValueCount -ne 1 -or $target.GetValue('TestMarker') -cne $marker) { throw 'Native registration modified a registry-link target.' }
    }
    finally { $target.Dispose() }
    [Vex.Windows.PreviewProtocolTests.ProtocolTestHarness]::DeleteLink()
    $linkCreated = $false
    Remove-Item -LiteralPath $targetPath
    Write-Host 'Actual native preview protocol register/cleanup, foreign ownership and registry-link refusal passed.'
}
catch {
    if (Test-Path -LiteralPath $diagnosticPath -PathType Leaf) {
        $diagnostic = Get-Content -LiteralPath $diagnosticPath -Raw | ConvertFrom-Json
        Write-Host "Native protocol diagnostic: stage=$($diagnostic.stage); registered=$($diagnostic.registered); type=$($diagnostic.failure_type); native-code=$($diagnostic.native_error_code)."
    }
    throw 'Actual native preview protocol regression failed; see sanitized diagnostic above.'
}
finally {
    if ($linkCreated) { [Vex.Windows.PreviewProtocolTests.ProtocolTestHarness]::DeleteLink() }
    foreach ($path in @($keyPath, $targetPath)) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse }
    }
    if (Test-Path -LiteralPath $diagnosticPath -PathType Leaf) {
        $diagnostic = Get-Content -LiteralPath $diagnosticPath -Raw | ConvertFrom-Json
        if ($diagnostic.process_id -eq $PID -and $diagnostic.scheme -ceq $scheme) {
            Remove-Item -LiteralPath $diagnosticPath
        }
    }
}
