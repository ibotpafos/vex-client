using System.Reflection;
using System.Runtime.ExceptionServices;
using System.Text.Json;
using Vex.Windows.Service.Runtime;

namespace Vex.Windows.VpnAcceptance;

// No traffic is sent to this documentation address. On the already-qualified
// disposable host, exercise the actual route creator, durable receipt and
// fingerprint-checked cleanup that the host-local encrypted peer does not use.
internal static class NativeRouteOwnershipFixture
{
    private const string Address = "192.0.2.253";
    private const string Prefix = Address + "/32";
    private static readonly Type ControllerType = typeof(AmneziaServiceTunnelRuntime).Assembly
        .GetType("Vex.Windows.Service.Runtime.NetworkSafetyController", throwOnError: true)!;

    internal static async Task RunAsync(string directory, string runtimeDirectory,
        string publicKey, Dictionary<string, object?> result, CancellationToken token)
    {
        result["native_owned_route_cleanup_verified"] = false;
        var before = await ReadRoutesAsync(token);
        Require(before.Length == 0, "fixture_owned_route_prefix_already_present");
        var dataDirectory = Path.Combine(directory, "native-owned-route-state");
        Require(!Directory.Exists(dataDirectory) && !File.Exists(dataDirectory),
            "fixture_owned_route_state_already_present");
        Directory.CreateDirectory(dataDirectory);
        var options = Program.FixtureOptions(directory, runtimeDirectory, Address + ":443") with
        {
            DataDirectory = dataDirectory,
            ControlPlaneBypassHosts = [],
            NativeLocalEndpointAddresses = [],
        };
        var constructor = ControllerType.GetConstructors(BindingFlags.Public | BindingFlags.Instance).Single();
        var arguments = constructor.GetParameters().Select((parameter, index) =>
            index == 0 ? (object?)options : parameter.DefaultValue).ToArray();
        var controller = constructor.Invoke(arguments);
        try
        {
            await InvokeAsync(controller, "ApplyControlPlaneBypassAsync",
                [Address + ":443", token, publicKey, DateTimeOffset.UtcNow.AddMinutes(5)]);
            using var journal = JsonDocument.Parse(File.ReadAllText(Path.Combine(dataDirectory, "bypass-routes.json")));
            Require(journal.RootElement.GetProperty("Version").GetInt32() == 2,
                "fixture_owned_route_journal_version_invalid");
            var entries = journal.RootElement.GetProperty("Entries").EnumerateArray().ToArray();
            Require(entries.Length == 1, "fixture_owned_route_journal_count_invalid");
            var entry = entries[0];
            var creationId = entry.GetProperty("CreationId").GetString();
            Require(entry.GetProperty("Confirmed").GetBoolean() && creationId is { Length: 32 } &&
                Guid.TryParseExact(creationId, "N", out _), "fixture_owned_route_unconfirmed");
            var metric = entry.GetProperty("RouteMetric").GetInt32();
            Require(metric is >= 128 and <= 65535 && entry.GetProperty("Address").GetString() == Address,
                "fixture_owned_route_fingerprint_invalid");
            using var receipt = JsonDocument.Parse(File.ReadAllText(Path.Combine(dataDirectory,
                "bypass-route-confirmations", creationId + ".json")));
            var proof = receipt.RootElement;
            foreach (var property in new[] { "CreationId", "Address", "InterfaceIndex", "NextHop", "RouteMetric" })
            {
                Require(proof.GetProperty(property).ToString() == entry.GetProperty(property).ToString(),
                    "fixture_owned_route_receipt_mismatch");
            }
            Require(proof.GetProperty("Protocol").GetString() == "NetMgmt",
                "fixture_owned_route_receipt_protocol_invalid");
            var actual = await ReadRoutesAsync(token);
            Require(actual.Length == 1 && actual[0].InterfaceIndex == entry.GetProperty("InterfaceIndex").GetInt32() &&
                actual[0].NextHop == entry.GetProperty("NextHop").GetString() &&
                actual[0].RouteMetric == metric && actual[0].Protocol == "NetMgmt",
                "fixture_owned_route_actual_metadata_invalid");
            await InvokeAsync(controller, "RollbackAsync", [token]);
            Require((await ReadRoutesAsync(token)).Length == before.Length &&
                !File.Exists(Path.Combine(dataDirectory, "bypass-routes.json")) &&
                (!Directory.Exists(Path.Combine(dataDirectory, "bypass-route-confirmations")) ||
                    !Directory.EnumerateFileSystemEntries(Path.Combine(dataDirectory, "bypass-route-confirmations")).Any()),
                "fixture_owned_route_cleanup_incomplete");
            result["native_owned_route_cleanup_verified"] = true;
        }
        finally
        {
            // A caller timeout must not cancel rollback. The production remover
            // still checks its creation receipt and exact effective metadata.
            using var cleanup = new CancellationTokenSource(TimeSpan.FromSeconds(40));
            await InvokeAsync(controller, "RollbackAsync", [cleanup.Token]);
            Require((await ReadRoutesAsync(cleanup.Token)).Length == before.Length,
                "fixture_owned_route_cleanup_incomplete");
        }
    }

    private static async Task<RouteRow[]> ReadRoutesAsync(CancellationToken token)
    {
        const string script = """
            $ErrorActionPreference='Stop';$prefix=$args[0]
            $rows=@(Get-NetRoute -AddressFamily IPv4 -PolicyStore ActiveStore -ErrorAction Stop | Where-Object {$_.DestinationPrefix -ceq $prefix} | ForEach-Object {
                [pscustomobject]@{InterfaceIndex=[int]$_.InterfaceIndex;NextHop=$_.NextHop;RouteMetric=[int]$_.RouteMetric;Protocol=$_.Protocol.ToString()}
            })
            ConvertTo-Json -InputObject $rows -Compress
            """;
        var method = ControllerType.GetMethod("RunPowerShellAsync", BindingFlags.NonPublic | BindingFlags.Static)!;
        var task = (Task<string>)Invoke(method, null, [script, new[] { Prefix }, token])!;
        return JsonSerializer.Deserialize<RouteRow[]>(await task) ?? throw new Program.FixtureException(
            "fixture_owned_route_query_invalid");
    }

    private static async Task InvokeAsync(object controller, string name, object?[] arguments)
    {
        var method = ControllerType.GetMethod(name, BindingFlags.Public | BindingFlags.Instance)!;
        await (Task)Invoke(method, controller, arguments)!;
    }

    private static object? Invoke(MethodInfo method, object? target, object?[] arguments)
    {
        try { return method.Invoke(target, arguments); }
        catch (TargetInvocationException error) when (error.InnerException is not null)
        {
            ExceptionDispatchInfo.Capture(error.InnerException).Throw();
            throw;
        }
    }

    private static void Require(bool condition, string code)
    {
        if (!condition) throw new Program.FixtureException(code);
    }

    private sealed record RouteRow(int InterfaceIndex, string NextHop, int RouteMetric, string Protocol);
}
