# Portable regression for the exact CI fixture tool resolver/process wrapper.
# Import function definitions only; never execute the Windows networking fixture.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../scripts/invoke-vpn-acceptance.ps1'))
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw 'VPN acceptance fixture does not parse.' }
foreach ($name in @('Resolve-FixtureTool', 'Invoke-FixtureProcess')) {
    $functions = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true))
    if ($functions.Count -ne 1) { throw "Fixture production function missing: $name" }
    . ([scriptblock]::Create($functions[0].Extent.Text))
}
$script:expectedTool = Join-Path $PSHOME $(if($IsWindows){'pwsh.exe'}else{'pwsh'})
function Get-Command {
    param($Name, $CommandType)
    if ($Name -notin @('go', 'dotnet') -or $CommandType -ne 'Application') {
        throw 'Unexpected fixture command lookup.'
    }
    # Hosted Windows runners have both setup-action and preinstalled SDKs.
    [pscustomobject]@{Source=$script:expectedTool}
    [pscustomobject]@{Source='missing-preinstalled-sdk'}
}
foreach ($name in @('go', 'dotnet')) {
    $tool = Resolve-FixtureTool -Name $name
    if ($tool -isnot [string] -or $tool -cne $script:expectedTool) {
        throw 'Multiple PATH matches became a concatenated executable path.'
    }
    Invoke-FixtureProcess -FilePath $tool -Arguments @('-NoProfile', '-NonInteractive', '-Command', 'exit 0') -TimeoutSeconds 10
}
Write-Output 'VPN acceptance SDK resolution and actual child-process regression passed.'

# Exercise the exact C# DNS query/retransmission/parser against an ephemeral
# loopback UDP server. Substitute only socket binding and destination port;
# this portable test never creates a tunnel or touches any host network state.
$probeSource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../scripts/Vex.Windows.VpnAcceptance/Program.cs'))
$start = $probeSource.IndexOf('    private static async Task<int> ProbeDnsAsync(')
$end = $probeSource.IndexOf('    private static async Task ProbeHttpsAsync(', $start)
if ($start -lt 0 -or $end -le $start) { throw 'Fixture DNS production methods missing.' }
$probeMethods = $probeSource.Substring($start, $end - $start).Replace('), 53)', '), _port)')
$regression = @'
using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
public static class VexFixtureDnsRegression
{
    private const string ServerIp = "127.0.0.1";
    private const string Host = "fixture.vex.invalid";
    private static int _port;
    private static Socket TunnelSocket(SocketType type, ProtocolType protocol, int index)
    {
        var socket = new Socket(AddressFamily.InterNetwork, type, protocol);
        socket.Bind(new IPEndPoint(IPAddress.Loopback, 0));
        return socket;
    }
    private static void Require(bool condition, string code)
    { if (!condition) { throw new InvalidOperationException(code); } }
    public static void Run() { RunAsync().GetAwaiter().GetResult(); }
    private static async Task RunAsync()
    {
        await AnswerAsync(dropFirst: true, invalidAddress: false);
        await AnswerAsync(dropFirst: false, invalidAddress: true);
        using var server = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
        server.Bind(new IPEndPoint(IPAddress.Loopback, 0));
        _port = ((IPEndPoint)server.LocalEndPoint).Port;
        using var cancellation = new CancellationTokenSource(TimeSpan.FromMilliseconds(250));
        var started = DateTime.UtcNow;
        try { await ProbeDnsAsync(1, cancellation.Token); throw new Exception("Missing DNS cancellation"); }
        catch (OperationCanceledException) { }
        Require(DateTime.UtcNow - started < TimeSpan.FromSeconds(3), "DNS cancellation exceeded deadline");
    }
    private static async Task AnswerAsync(bool dropFirst, bool invalidAddress)
    {
        using var server = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
        server.Bind(new IPEndPoint(IPAddress.Loopback, 0));
        _port = ((IPEndPoint)server.LocalEndPoint).Port;
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        var answer = Task.Run(async () =>
        {
            var packet = new byte[1232];
            var received = await server.ReceiveFromAsync(packet, SocketFlags.None, new IPEndPoint(IPAddress.Any, 0), deadline.Token);
            if (dropFirst)
            {
                received = await server.ReceiveFromAsync(packet, SocketFlags.None, new IPEndPoint(IPAddress.Any, 0), deadline.Token);
            }
            var response = new byte[received.ReceivedBytes + 16];
            Array.Copy(packet, response, received.ReceivedBytes);
            response[2] = 0x81; response[3] = 0x80; response[7] = 1;
            byte[] resource = [0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 0, 0, 4, 127, 0, 0, (byte)(invalidAddress ? 9 : 1)];
            Array.Copy(resource, 0, response, received.ReceivedBytes, resource.Length);
            await server.SendToAsync(response, SocketFlags.None, received.RemoteEndPoint, deadline.Token);
        });
        try
        {
            var attempts = await ProbeDnsAsync(1, deadline.Token);
            Require(!invalidAddress, "Incorrect DNS answer accepted");
            Require(!dropFirst || attempts >= 2, "Lost DNS request was not retransmitted");
        }
        catch (InvalidOperationException exception) when (invalidAddress && exception.Message == "fixture_dns_answer_invalid") { }
        await answer;
    }
'@
Add-Type -TypeDefinition ($regression + $probeMethods + '}')
[VexFixtureDnsRegression]::Run()
Write-Output 'VPN acceptance actual DNS dropped-datagram retry, strict answer and cancellation regressions passed.'
