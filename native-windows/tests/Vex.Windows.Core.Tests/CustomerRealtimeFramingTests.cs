using System.Net;
using System.Text;
using Vex.Windows.Client.Api;

internal static class CustomerRealtimeFramingTests
{
    private const int Limit = 64 * 1024;
    private static readonly TimeSpan Deadline = TimeSpan.FromSeconds(2);

    public static void Run()
    {
        var cases = new (string Name, Func<Task> Run)[]
        {
            ("CRLF at every chunk boundary", () => Sync(CrlfBoundaries)),
            ("complete oversized frame", () => Sync(OversizedCompleteFrame)),
            ("oversized unfinished frame", () => Sync(OversizedPartialFrame)),
            ("exact limit and multiple small frames", () => Sync(ValidFrameLimits)),
            ("unterminated transport line", UnterminatedTransportLineAsync),
            ("fragmented UTF8 transport", FragmentedTransportAsync),
            ("unfinished EOF frame", UnfinishedEofAsync),
            ("cancelled late transport frame", CancelledLateFrameAsync),
        };
        var failures = new List<string>();
        foreach (var scenario in cases)
        {
            try
            {
                scenario.Run().GetAwaiter().GetResult();
                Console.WriteLine("REALTIME_FRAMING_CASE=passed name=" + scenario.Name);
            }
            catch (Exception error)
            {
                failures.Add(scenario.Name + ": " + error.Message);
                Console.WriteLine("REALTIME_FRAMING_CASE=failed name=" + scenario.Name);
            }
        }
        if (failures.Count != 0) throw new InvalidOperationException(string.Join("; ", failures));
    }

    private static Task Sync(Action action) { action(); return Task.CompletedTask; }
    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static void CrlfBoundaries()
    {
        const string frame = "event: customer.change\r\nid: billing:7\r\ndata: {\"domain\":\"billing\",\"version\":7}\r\n\r\n";
        foreach (var wire in new[] { frame, frame.Replace("\r\n", "\r"), frame.Replace("\r\n", "\n") })
        for (var split = 0; split <= wire.Length; split++)
        {
            var parser = new CustomerSseParser();
            var events = parser.Append(wire[..split]).Concat(parser.Append(wire[split..])).ToArray();
            Check(events.Length == 1 && events[0].Type == "customer.change" &&
                  events[0].Id == "billing:7" && events[0].Data == "{\"domain\":\"billing\",\"version\":7}" &&
                  parser.Remainder.Length == 0, "valid event changed at chunk split " + split);
        }
    }

    private static string Heartbeat(int length)
    {
        const string prefix = "event: customer.heartbeat\ndata: ";
        return prefix + new string(' ', length - prefix.Length - 4) + "{}\n\n";
    }

    private static void Rejected(CustomerSseParser parser, string chunk)
    {
        try { parser.Append(chunk); }
        catch (InvalidDataException error)
        {
            Check(parser.Remainder.Length == 0 && !error.Message.Contains(chunk[..Math.Min(200, chunk.Length)], StringComparison.Ordinal),
                "framing failure retained private payload");
            return;
        }
        throw new InvalidOperationException("oversized frame was accepted instead of a bounded transport failure");
    }

    private static void OversizedCompleteFrame() => Rejected(new CustomerSseParser(), Heartbeat(Limit + 1));

    private static void OversizedPartialFrame()
    {
        var parser = new CustomerSseParser();
        Rejected(parser, new string('x', Limit + 1));
        Check(parser.Append("event: customer.heartbeat\ndata: {}\n\n").Count == 1,
            "failed frame contaminated a later fresh frame");
    }

    private static void ValidFrameLimits()
    {
        var parser = new CustomerSseParser();
        Check(parser.Append(Heartbeat(Limit)).Count == 1, "exact frame limit was rejected");
        var many = string.Concat(Enumerable.Repeat("event: customer.heartbeat\ndata: {}\n\n", 3000));
        Check(parser.Append(many).Count == 3000 && parser.Remainder.Length == 0,
            "frame limit was incorrectly applied to the total valid chunk");
    }

    private static async Task UnterminatedTransportLineAsync()
    {
        var stream = new FixtureStream([], endless: true);
        var handler = new Handler(stream);
        using var http = new HttpClient(handler) { BaseAddress = new Uri("https://realtime.example.test"), Timeout = Timeout.InfiniteTimeSpan };
        await using var client = new CustomerRealtimeClient(http);
        var events = 0;
        client.Changed += (_, _) => Interlocked.Increment(ref events);
        try
        {
            await client.StartAsync("inert-fixture-token");
            await stream.Disposed.Task.WaitAsync(Deadline);
            Check(stream.BytesRead <= Limit + 8192, "transport read beyond its frame budget");
        }
        finally { await client.StopAsync().WaitAsync(Deadline); }
        Check(handler.Requests == 1 && events == 0 && !client.IsConnected,
            "oversized transport triggered credential recovery or replay after stop");
    }

    private static async Task FragmentedTransportAsync()
    {
        const string data = "{\"domain\":\"billing\",\"version\":7,\"note\":\"Событие 🔐\"}";
        var wire = Encoding.UTF8.GetBytes("event: customer.change\r\nid: billing:7\r\ndata: " + data + "\r\n\r\n");
        var stream = new FixtureStream(wire, oneByte: true, holdAfterPayload: true);
        var handler = new Handler(stream);
        using var http = new HttpClient(handler) { BaseAddress = new Uri("https://realtime.example.test"), Timeout = Timeout.InfiniteTimeSpan };
        await using var client = new CustomerRealtimeClient(http);
        var received = new TaskCompletionSource<CustomerRealtimeChangedEventArgs>(TaskCreationOptions.RunContinuationsAsynchronously);
        client.Changed += (_, args) => received.TrySetResult(args);
        try
        {
            await client.StartAsync("inert-fixture-token");
            var args = await received.Task.WaitAsync(Deadline);
            Check(args.Event.Id == "billing:7" && args.Event.Data == data && args.Metadata.Domains.SequenceEqual(["billing"]),
                "incremental UTF8/CRLF changed the event contract");
        }
        finally { await client.StopAsync().WaitAsync(Deadline); }
        Check(stream.Disposed.Task.IsCompleted && handler.Requests == 1 && !client.IsConnected,
            "fragmented transport survived explicit stop");
    }

    private static async Task UnfinishedEofAsync()
    {
        var stream = new FixtureStream(Encoding.UTF8.GetBytes("event: customer.change\nid: billing:7\ndata: {\"domain\":\"billing\",\"version\":7}\n"));
        var handler = new Handler(stream);
        using var http = new HttpClient(handler) { BaseAddress = new Uri("https://realtime.example.test"), Timeout = Timeout.InfiniteTimeSpan };
        await using var client = new CustomerRealtimeClient(http);
        var events = 0;
        client.Changed += (_, _) => Interlocked.Increment(ref events);
        try
        {
            await client.StartAsync("inert-fixture-token");
            await stream.Disposed.Task.WaitAsync(Deadline);
        }
        finally { await client.StopAsync().WaitAsync(Deadline); }
        Check(events == 0 && handler.Requests == 1 && !client.IsConnected,
            "EOF fabricated a complete frame or retried after explicit stop");
    }

    private static async Task CancelledLateFrameAsync()
    {
        var payload = Encoding.UTF8.GetBytes("event: customer.change\nid: billing:7\ndata: {\"domain\":\"billing\",\"version\":7}\n\n");
        var stream = new FixtureStream(payload, releaseOnCancellation: true);
        var handler = new Handler(stream);
        using var http = new HttpClient(handler) { BaseAddress = new Uri("https://realtime.example.test"), Timeout = Timeout.InfiniteTimeSpan };
        await using var client = new CustomerRealtimeClient(http);
        var events = 0;
        client.Changed += (_, _) => Interlocked.Increment(ref events);
        try
        {
            await client.StartAsync("inert-fixture-token");
            await stream.Waiting.Task.WaitAsync(Deadline);
        }
        finally { await client.StopAsync().WaitAsync(Deadline); }
        Check(stream.Disposed.Task.IsCompleted && handler.Requests == 1 && events == 0 && !client.IsConnected,
            "cancelled buffered read published late account evidence");
    }

    private sealed class Handler(FixtureStream stream) : HttpMessageHandler
    {
        public int Requests;
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Interlocked.Increment(ref Requests);
            Check(request.RequestUri?.AbsolutePath == "/v1/events" &&
                  request.Headers.Authorization?.ToString() == "Bearer inert-fixture-token" &&
                  request.Headers.Accept.Single().MediaType == "text/event-stream",
                "realtime request boundary changed");
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(stream) });
        }
    }

    private sealed class FixtureStream(byte[] payload, bool endless = false, bool oneByte = false, bool holdAfterPayload = false, bool releaseOnCancellation = false) : Stream
    {
        private int _offset;
        public long BytesRead { get; private set; }
        public TaskCompletionSource Waiting { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource Disposed { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            if (releaseOnCancellation && _offset == 0)
            {
                Waiting.TrySetResult();
                try { await Task.Delay(Timeout.Infinite, cancellationToken); }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
            }
            else cancellationToken.ThrowIfCancellationRequested();
            if (endless)
            {
                await Task.Delay(1, cancellationToken);
                buffer.Span.Fill((byte)'x');
                BytesRead += buffer.Length;
                return buffer.Length;
            }
            if (_offset == payload.Length)
            {
                if (holdAfterPayload) await Task.Delay(Timeout.Infinite, cancellationToken);
                return 0;
            }
            var count = Math.Min(buffer.Length, oneByte ? 1 : payload.Length - _offset);
            payload.AsMemory(_offset, count).CopyTo(buffer);
            _offset += count;
            BytesRead += count;
            return count;
        }
        public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
            ReadAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();
        protected override void Dispose(bool disposing) { Disposed.TrySetResult(); base.Dispose(disposing); }
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override void Flush() => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
