using System.Diagnostics;
using System.Net;
using System.Text;
using Vex.Windows.Client.Api;

internal static class VexApiResponseDeadlineTests
{
    private static readonly TimeSpan TestCeiling = TimeSpan.FromSeconds(4);

    public static readonly (string Name, Action Run)[] Cases =
    [
        ("API success body completes within the configured deadline", () => FastResponseAsync().GetAwaiter().GetResult()),
        ("API partial success body stops at the HTTP request deadline", () => StalledSuccessBodyAsync().GetAwaiter().GetResult()),
        ("API headers and body share one timeout budget", () => HeadersConsumeBodyBudgetAsync().GetAwaiter().GetResult()),
        ("API caller cancellation interrupts a stalled success body", () => CallerCancellationAsync(TimeSpan.FromSeconds(10)).GetAwaiter().GetResult()),
        ("API infinite HTTP timeout preserves caller cancellation", () => CallerCancellationAsync(Timeout.InfiniteTimeSpan).GetAwaiter().GetResult()),
        ("API response deadline preserves an authoritative error status", () => ErrorBodyDeadlineAsync().GetAwaiter().GetResult()),
    ];

    private static async Task FastResponseAsync()
    {
        using var http = Client(new ResponseHandler(new MemoryStream(
            Encoding.UTF8.GetBytes("{\"id\":\"user-1\",\"email\":\"user@example.com\",\"status\":\"active\"}"))),
            TimeSpan.FromSeconds(1));
        var user = await new VexApiClient(http).GetCurrentUserAsync("access-token", CancellationToken.None)
            .WaitAsync(TestCeiling).ConfigureAwait(false);
        Require(user.Id == "user-1" && user.Email == "user@example.com", "Fast API response changed.");
    }

    private static async Task StalledSuccessBodyAsync()
    {
        var body = new PartialThenStallStream();
        using var http = Client(new ResponseHandler(body), TimeSpan.FromMilliseconds(300));
        using var caller = new CancellationTokenSource();
        try
        {
            var response = new VexApiClient(http).GetCurrentUserAsync("access-token", caller.Token);
            await body.Waiting.Task.WaitAsync(TestCeiling).ConfigureAwait(false);
            var error = await ExpectCancellationAsync(response).ConfigureAwait(false);
            Require(!caller.IsCancellationRequested && error.InnerException is TimeoutException,
                "A body timeout was confused with caller cancellation.");
            Require(body.BytesServed > 0 && body.ReadCancelled && body.Disposed,
                "The actual partial response stream was not cancelled and disposed.");
        }
        finally { caller.Cancel(); }
    }

    private static async Task HeadersConsumeBodyBudgetAsync()
    {
        var body = new PartialThenStallStream();
        using var http = Client(new ResponseHandler(body, headerDelay: TimeSpan.FromMilliseconds(1250)),
            TimeSpan.FromSeconds(2));
        using var caller = new CancellationTokenSource();
        try
        {
            var response = new VexApiClient(http).GetCurrentUserAsync("access-token", caller.Token);
            await body.Waiting.Task.WaitAsync(TestCeiling).ConfigureAwait(false);
            var bodyTime = Stopwatch.StartNew();
            var error = await ExpectCancellationAsync(response).ConfigureAwait(false);
            Require(error.InnerException is TimeoutException && body.ReadCancelled &&
                bodyTime.Elapsed < TimeSpan.FromMilliseconds(1500),
                "The body received a fresh two-second timeout after the headers.");
        }
        finally { caller.Cancel(); }
    }

    private static async Task CallerCancellationAsync(TimeSpan httpTimeout)
    {
        var body = new PartialThenStallStream();
        using var http = Client(new ResponseHandler(body), httpTimeout);
        using var caller = new CancellationTokenSource();
        try
        {
            var response = new VexApiClient(http).GetCurrentUserAsync("access-token", caller.Token);
            await body.Waiting.Task.WaitAsync(TestCeiling).ConfigureAwait(false);
            caller.Cancel();
            var error = await ExpectCancellationAsync(response).ConfigureAwait(false);
            Require(error.CancellationToken == caller.Token && error.InnerException is not TimeoutException &&
                body.ReadCancelled && body.Disposed,
                "Caller cancellation did not stop the body or preserve the caller token.");
        }
        finally { caller.Cancel(); }
    }

    private static async Task ErrorBodyDeadlineAsync()
    {
        var body = new PartialThenStallStream();
        using var http = Client(new ResponseHandler(body, status: HttpStatusCode.Unauthorized),
            TimeSpan.FromMilliseconds(300));
        using var caller = new CancellationTokenSource();
        try
        {
            var response = new VexApiClient(http).ConfirmEmailOtpAsync(
                "user@example.com", "challenge-1", "123456", caller.Token);
            await body.Waiting.Task.WaitAsync(TestCeiling).ConfigureAwait(false);
            try
            {
                await response.WaitAsync(TestCeiling).ConfigureAwait(false);
                throw new InvalidOperationException("Expected the authoritative HTTP error.");
            }
            catch (VexApiException error)
            {
                Require(error.StatusCode == HttpStatusCode.Unauthorized && error.Code == "session_expired" &&
                    body.ReadCancelled && body.Disposed && !caller.IsCancellationRequested,
                    "A body deadline discarded the authoritative 401 response.");
            }
        }
        finally { caller.Cancel(); }
    }

    private static HttpClient Client(HttpMessageHandler handler, TimeSpan timeout) => new(handler)
    {
        BaseAddress = new Uri("https://api.example.test"),
        Timeout = timeout,
    };

    private static async Task<TaskCanceledException> ExpectCancellationAsync(Task operation)
    {
        try
        {
            await operation.WaitAsync(TestCeiling).ConfigureAwait(false);
            throw new InvalidOperationException("A stalled API response unexpectedly completed.");
        }
        catch (TaskCanceledException error) { return error; }
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) { throw new InvalidOperationException(message); }
    }

    private sealed class ResponseHandler(Stream body, TimeSpan headerDelay = default,
        HttpStatusCode status = HttpStatusCode.OK) : HttpMessageHandler
    {
        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Require(request.RequestUri?.Host == "api.example.test" &&
                request.Headers.Authorization?.Scheme is "Bearer" or null,
                "Deadline fixture did not exercise the actual API transport.");
            if (headerDelay > TimeSpan.Zero)
            {
                await Task.Delay(headerDelay, cancellationToken).ConfigureAwait(false);
            }
            return new HttpResponseMessage(status) { Content = new StreamContent(body) };
        }
    }

    private sealed class PartialThenStallStream : Stream
    {
        private readonly byte[] _prefix = Encoding.UTF8.GetBytes("{\"id\":\"user-1\",");
        public TaskCompletionSource Waiting { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public int BytesServed { get; private set; }
        public bool ReadCancelled { get; private set; }
        public bool Disposed { get; private set; }
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => BytesServed; set => throw new NotSupportedException(); }

        public override async ValueTask<int> ReadAsync(Memory<byte> buffer,
            CancellationToken cancellationToken = default)
        {
            if (BytesServed < _prefix.Length)
            {
                var count = Math.Min(buffer.Length, _prefix.Length - BytesServed);
                _prefix.AsMemory(BytesServed, count).CopyTo(buffer);
                BytesServed += count;
                return count;
            }
            Waiting.TrySetResult();
            try
            {
                await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken).ConfigureAwait(false);
                throw new InvalidOperationException("Stalled fixture unexpectedly reached EOF.");
            }
            catch (OperationCanceledException) { ReadCancelled = true; throw; }
        }

        public override Task<int> ReadAsync(byte[] buffer, int offset, int count,
            CancellationToken cancellationToken) => ReadAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();
        protected override void Dispose(bool disposing) { Disposed = true; base.Dispose(disposing); }
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
