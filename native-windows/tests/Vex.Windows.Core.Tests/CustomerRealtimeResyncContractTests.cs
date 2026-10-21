using Vex.Windows.Client.Api;

internal static class CustomerRealtimeResyncContractTests
{
    public static void Run()
    {
        var failures = new List<string>();
        foreach (var reason in new[] { "broker_error", "initial", "reconnect", "subscriber_overflow", "resync" })
        {
            var data = "{\"versions\":null,\"reason\":\"" + reason + "\"}";
            var metadata = CustomerRealtimeMetadata.Parse("customer.resync", data);
            if (metadata is null || metadata.Domains.Count != 0 || metadata.Reason != reason)
                failures.Add("null versions: " + reason);
        }
        var defaultReason = CustomerRealtimeMetadata.Parse("customer.resync", "{\"versions\":null}");
        if (defaultReason is null || defaultReason.Domains.Count != 0 || defaultReason.Reason != "resync")
            failures.Add("null versions: default reason");
        foreach (var malformed in new[] { "{}", "{\"versions\":true}", "{\"versions\":1}", "{\"versions\":\"null\"}", "{\"versions\":{}}" })
            if (CustomerRealtimeMetadata.Parse("customer.resync", malformed) is not null)
                failures.Add("malformed versions admitted");
        var empty = CustomerRealtimeMetadata.Parse("customer.resync", "{\"versions\":[]}");
        if (empty is null || empty.Domains.Count != 0 || empty.Reason != "resync")
            failures.Add("empty array compatibility");
        var nonempty = CustomerRealtimeMetadata.Parse("customer.resync", "{\"versions\":[{\"domain\":\"devices\"},{\"domain\":\"unknown\"},{\"domain\":\"billing\"},{\"domain\":\"devices\"}],\"reason\":\"initial\"}");
        if (nonempty is null || !nonempty.Domains.SequenceEqual(new[] { "billing", "devices" }) || nonempty.Reason != "initial")
            failures.Add("nonempty array compatibility");
        var parser = new CustomerSseParser();
        var events = parser.Append("event: customer.resync\r\ndata: {\"versions\":null,\"reason\":\"broker_error\"}\r\n\r\n");
        if (events.Count != 1 || CustomerRealtimeMetadata.Parse(events[0].Type, events[0].Data) is null)
            failures.Add("wire decoder null resync");
        if (events.Count == 1 && CustomerRealtimeMetadata.Parse(events[0].Type, events[0].Data) is { } metadataForRefresh)
        {
            var args = new CustomerRealtimeChangedEventArgs(events[0], metadataForRefresh);
            if (!CustomerRealtimeRefreshPolicy.ShouldRefreshAccount(args) || !CustomerRealtimeRefreshPolicy.ShouldRefreshSettings(args))
                failures.Add("resync must refresh account and settings");
        }
        if (failures.Count != 0) throw new InvalidOperationException(string.Join("; ", failures));
    }
}
