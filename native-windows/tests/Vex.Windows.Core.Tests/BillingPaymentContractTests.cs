using System.Net;
using System.Reflection;
using System.Runtime.Loader;
using System.Text;
using System.Text.Json;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;
using Vex.Windows.Client.Api;

internal static class BillingPaymentContractTests
{
    public static void Run()
    {
        // Payment storage and the server's 64-bit Go DTO permit values beyond
        // Int32. Read actual HTTP responses, including legacy omitted refunds.
        foreach (var amount in new[] { 0L, 49900L, int.MaxValue, (long)int.MaxValue + 1, long.MaxValue })
        {
            foreach (var refund in new long?[] { null, 0L, amount })
            {
                var refundField = refund is { } value ? ",\"refunded_amount_minor\":" +
                    value.ToString(System.Globalization.CultureInfo.InvariantCulture) : "";
                var body = "[{\"id\":\"payment-fixture\",\"provider\":\"manual\",\"amount_minor\":" +
                    amount.ToString(System.Globalization.CultureInfo.InvariantCulture) +
                    ",\"currency\":\"RUB\",\"method\":\"manual\",\"status\":\"paid\"," +
                    "\"created_at\":\"2026-10-21T00:00:00Z\"" + refundField + "}]";
                using var handler = new PaymentHandler(body);
                using var http = new HttpClient(handler) { BaseAddress = new Uri("https://api.example.test") };
                var payments = new VexApiClient(http).GetBillingPaymentsAsync("fixture-token", 24, default)
                    .GetAwaiter().GetResult();
                var payment = payments.Single();
                Check((long)payment.AmountMinor == amount, "Payment amount lost precision.");
                Check((long?)payment.RefundedAmountMinor == refund, "Refund amount or omission changed.");
                Check(payment.PlanId is null && payment.PaidAt is null, "Legacy optional fields became required.");
                var roundTrip = JsonSerializer.Deserialize<BillingPayment>(JsonSerializer.Serialize(payment))!;
                Check(roundTrip == payment, "Payment cache serialization changed the amount.");
            }
        }
        CheckAccountFormatting();
    }

    private static void CheckAccountFormatting()
    {
        var source = File.ReadAllText(Path.Combine(AppMetadataContractTests.FindRepositoryRoot(), "native-windows", "src",
            "Vex.Windows.App", "Views", "AccountPage.xaml.cs"));
        var method = CSharpSyntaxTree.ParseText(source).GetRoot().DescendantNodes().OfType<MethodDeclarationSyntax>()
            .Single(node => node.Identifier.ValueText == "FormatMoney").ToFullString();
        // Compile the actual UI formatter without opening WinUI or a VPN service.
        var tree = CSharpSyntaxTree.ParseText("using System; using System.Globalization; public class MoneyProbe {" + method + "}");
        var paths = ((string?)AppContext.GetData("TRUSTED_PLATFORM_ASSEMBLIES"))!.Split(Path.PathSeparator);
        var compilation = CSharpCompilation.Create("MoneyProbe" + Guid.NewGuid().ToString("N"), [tree],
            paths.Select(path => MetadataReference.CreateFromFile(path)),
            new CSharpCompilationOptions(OutputKind.DynamicallyLinkedLibrary));
        using var output = new MemoryStream();
        var emitted = compilation.Emit(output);
        Check(emitted.Success, string.Join("\n", emitted.Diagnostics));
        output.Position = 0;
        var context = new AssemblyLoadContext("money-probe", isCollectible: true);
        try
        {
            var formatter = context.LoadFromStream(output).GetType("MoneyProbe")!
                .GetMethod("FormatMoney", BindingFlags.NonPublic | BindingFlags.Static)!
                .CreateDelegate<Func<long, string, string>>();
            foreach (var amount in new[] { (long)int.MaxValue + 1, long.MaxValue })
            {
                var digits = new string(formatter(amount, "RUB").Where(char.IsDigit).ToArray());
                Check(digits == amount.ToString(System.Globalization.CultureInfo.InvariantCulture),
                    "Account UI truncated a large payment or lost its minor units.");
            }
        }
        finally { context.Unload(); }
    }

    private static void Check(bool valid, string message)
    {
        if (!valid) throw new InvalidOperationException(message);
    }

    private sealed class PaymentHandler(string body) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Check(request.RequestUri!.AbsolutePath == "/v1/billing/payments" && request.RequestUri.Query == "?limit=24",
                "Unexpected billing endpoint.");
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json"),
            });
        }
    }
}
