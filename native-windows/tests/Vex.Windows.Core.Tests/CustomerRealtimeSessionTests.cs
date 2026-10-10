using System.Collections.Concurrent;
using System.Net;
using System.Text;
using System.Threading.Channels;
using Vex.Windows.App.Services;
using Vex.Windows.Client.Api;
using Vex.Windows.Client.Auth;
using Vex.Windows.Client.Security;
using Vex.Windows.Client.Session;
using Vex.Windows.Core.Vpn;

internal static class CustomerRealtimeSessionTests
{
    private const string OldToken = "old-stream-access-token";
    private const string NewToken = "fresh-session-access-token";
    private static readonly TimeSpan Deadline = TimeSpan.FromSeconds(5);

    public static void Run() => RunAsync().GetAwaiter().GetResult();

    private static async Task RunAsync()
    {
        await TransientRefreshFailuresPreserveSessionAsync();
        await TransientRefreshThenSuccessRestartsFreshStreamAsync();
        await RefreshAuthenticationRejectionSignsOutAsync();
        await ServerSessionInvalidProbesBeforeSigningOutAsync();
        await DuplicateSessionInvalidCoalescesInFlightRefreshAsync();
        await OldStreamEventCannotAffectNewLoginAsync(revoked: false);
        await OldStreamEventCannotAffectNewLoginAsync(revoked: true);
        await SessionChangedWhileWaitingForCoordinatorGateAsync(revoked: false);
        await SessionChangedWhileWaitingForCoordinatorGateAsync(revoked: true);
        await UnauthorizedStreamStopsAfterOneRequestAsync();
        await SameTokenRefreshCannotReplayRejectedStreamAsync();
        await SilentStreamReconnectsWithoutSessionRecoveryAsync();
        await PartialBytesAndHeartbeatsResetLivenessAsync();
        await StopCancelsSilentStreamWithoutReconnectAsync();
        await SilentResponseHeadersRetryWithoutSessionRecoveryAsync();
    }

    private static async Task TransientRefreshFailuresPreserveSessionAsync()
    {
        foreach (var revoked in new[] { false, true })
        foreach (var failure in new Exception[]
        {
            new HttpRequestException("Refresh server is offline."),
            new TaskCanceledException("Refresh request timed out."),
            new VexApiException(HttpStatusCode.ServiceUnavailable, "temporarily_unavailable"),
        })
        {
            await using var fixture = new Fixture(revoked);
            fixture.Proxy.Overrides[nameof(INativeClientApi.RefreshSessionAsync)] = _ =>
            {
                fixture.RefreshCalls++;
                return Task.FromException<VexAuthSession>(failure);
            };

            await fixture.StartAndRecoverAsync();

            Check(fixture.RefreshCalls == 3 && fixture.Delays.Count == 2,
                "Transient SSE credential recovery did not stop after its three-attempt budget.");
            Check(fixture.Store.State?.Session.AccessToken == OldToken && fixture.Store.ClearCount == 0 &&
                fixture.Vpn.DisconnectCount == 0 && fixture.MatchedSignOuts == 0,
                "A network, timeout or 503 refresh failure signed out or disconnected the VPN.");
            Check(fixture.StopCalls == 1 && fixture.RestartTokens.Count == 0 && !fixture.Realtime.IsConnected &&
                fixture.Handler.Tokens.Count == 1,
                "Failed refresh restarted the rejected old SSE token instead of pausing realtime.");
            Check(fixture.Events.Single().Event.Type == (revoked
                    ? "customer.session.revoked" : "customer.session.refresh_required") &&
                (!revoked || fixture.Events.Single().Metadata.Reason == "session_invalid"),
                "The fixture did not deliver the actual HTTP 401 or server session_invalid signal.");
        }
    }

    private static async Task TransientRefreshThenSuccessRestartsFreshStreamAsync()
    {
        foreach (var revoked in new[] { false, true })
        {
            await using var fixture = new Fixture(revoked);
            fixture.Proxy.Overrides[nameof(INativeClientApi.RefreshSessionAsync)] = args =>
            {
                fixture.RefreshCalls++;
                Check((string)args[0]! == OldToken, "Credential recovery refreshed an unrelated session token.");
                return fixture.RefreshCalls == 1
                    ? Task.FromException<VexAuthSession>(new HttpRequestException("Temporary refresh outage."))
                    : Task.FromResult(Session(NewToken));
            };

            await fixture.StartAndRecoverAsync();
            await fixture.Handler.FreshRequest.Task.WaitAsync(Deadline);

            Check(fixture.RefreshCalls == 2 && fixture.Delays.Count == 1 &&
                fixture.Store.State?.Session.AccessToken == NewToken,
                "Transient credential recovery did not persist the successful replacement session.");
            Check(fixture.RestartTokens.SequenceEqual([NewToken]) && fixture.Handler.Tokens.Contains(NewToken) &&
                fixture.Store.ClearCount == 0 && fixture.Vpn.DisconnectCount == 0 && fixture.MatchedSignOuts == 0,
                "Successful refresh failed to restart SSE with the fresh token or disconnected VPN.");
        }
    }

    private static async Task RefreshAuthenticationRejectionSignsOutAsync()
    {
        foreach (var revoked in new[] { false, true })
        foreach (var failure in new Exception[]
        {
            new VexApiException(HttpStatusCode.Unauthorized, "session_invalid"),
            new HttpRequestException("Refresh credentials rejected.", null, HttpStatusCode.Unauthorized),
        })
        {
            await using var fixture = new Fixture(revoked);
            fixture.Proxy.Overrides[nameof(INativeClientApi.RefreshSessionAsync)] = _ =>
            {
                fixture.RefreshCalls++;
                return Task.FromException<VexAuthSession>(failure);
            };

            await fixture.StartAndRecoverAsync();

            Check(fixture.RefreshCalls == 1 && fixture.Delays.Count == 0 && fixture.RestartTokens.Count == 0,
                "A real refresh 401 was retried or restarted an invalid stream.");
            Check(fixture.Store.State is null && fixture.Store.ClearCount == 1 &&
                fixture.Vpn.DisconnectCount == 1 && fixture.MatchedSignOuts == 1,
                "Rejected refresh credentials did not clear the session and disconnect exactly once.");
        }
    }

    private static async Task ServerSessionInvalidProbesBeforeSigningOutAsync()
    {
        foreach (var payload in new[]
        {
            "{\"reason\":\"session_invalid\"}",
            "{}",
            "{\"reason\":\"unknown_future_reason\"}",
            "{\"reason\":\"unauthorized\"}",
        })
        {
            await using var fixture = new Fixture(revoked: true, revokedPayload: payload);
            fixture.Proxy.Overrides[nameof(INativeClientApi.RefreshSessionAsync)] = _ =>
            {
                fixture.RefreshCalls++;
                return Task.FromResult(Session(NewToken));
            };

            await fixture.StartAndRecoverAsync();
            await fixture.Handler.FreshRequest.Task.WaitAsync(Deadline);

            Check(fixture.Events.Single().Event.Type == "customer.session.revoked",
                "The fixture did not deliver the server's session-invalid event frame.");
            Check(fixture.RefreshCalls == 1 && fixture.Store.State?.Session.AccessToken == NewToken &&
                fixture.Store.ClearCount == 0 && fixture.Vpn.DisconnectCount == 0 && fixture.MatchedSignOuts == 0 &&
                fixture.RestartTokens.SequenceEqual([NewToken]) && fixture.Handler.Tokens.Contains(NewToken),
                "A session-invalid frame or its reason signed out without first probing refresh credentials.");
        }
    }

    private static async Task OldStreamEventCannotAffectNewLoginAsync(bool revoked)
    {
        await using var fixture = new Fixture(revoked, autoRecover: false);
        var oldEvent = await fixture.StartAndCaptureAsync();
        await fixture.Coordinator.ProvisionAuthenticatedSessionAsync(Session(NewToken), CancellationToken.None);

        await fixture.Recovery.HandleAsync(oldEvent).WaitAsync(Deadline);

        Check(fixture.Store.State?.Session.AccessToken == NewToken && fixture.RefreshCalls == 0 &&
            fixture.Store.ClearCount == 0 && fixture.Vpn.DisconnectCount == 0 && fixture.MatchedSignOuts == 0 &&
            fixture.StopCalls == 0 && fixture.RestartTokens.Count == 0,
            "A queued event from an old SSE stream refreshed, stopped or revoked the new login.");
        Check(oldEvent.SourceTokenFingerprint == CustomerRealtimeClient.TokenFingerprint(OldToken) &&
            oldEvent.SourceTokenFingerprint != OldToken,
            "The realtime event did not retain its source token fingerprint without exposing the token.");
    }

    private static async Task DuplicateSessionInvalidCoalescesInFlightRefreshAsync()
    {
        await using var fixture = new Fixture();
        var started = Signal();
        var response = Result<VexAuthSession>();
        CancellationToken refreshToken = default;
        fixture.Proxy.Overrides[nameof(INativeClientApi.RefreshSessionAsync)] = args =>
        {
            fixture.RefreshCalls++;
            refreshToken = (CancellationToken)args[^1]!;
            started.TrySetResult();
            return response.Task;
        };
        var recovering = fixture.StartAndRecoverAsync();
        await started.Task.WaitAsync(Deadline);
        await using var serverEvent = new Fixture(revoked: true, autoRecover: false);
        var revoked = await serverEvent.StartAndCaptureAsync();

        var duplicate = fixture.Recovery.HandleAsync(revoked);
        await duplicate.WaitAsync(Deadline);
        Check(!refreshToken.IsCancellationRequested && fixture.RefreshCalls == 1,
            "A duplicate session-invalid signal cancelled or duplicated its in-flight refresh probe.");
        response.TrySetResult(Session(NewToken));
        await recovering.WaitAsync(Deadline);
        await fixture.Handler.FreshRequest.Task.WaitAsync(Deadline);

        Check(fixture.Store.State?.Session.AccessToken == NewToken && fixture.Store.ClearCount == 0 &&
            fixture.MatchedSignOuts == 0 && fixture.Vpn.DisconnectCount == 0 && fixture.RefreshCalls == 1 &&
            fixture.StopCalls == 1 && fixture.RestartTokens.SequenceEqual([NewToken]),
            "Duplicate session-invalid signals did not adopt one successful probe while retaining the VPN.");
    }

    private static async Task SessionChangedWhileWaitingForCoordinatorGateAsync(bool revoked)
    {
        await using var fixture = new Fixture(revoked, autoRecover: false);
        var oldEvent = await fixture.StartAndCaptureAsync();
        var blocked = Signal();
        var locations = Result<IReadOnlyList<VpnLocation>>();
        var reads = 0;
        fixture.Proxy.Overrides[nameof(INativeClientApi.GetLocationsAsync)] = _ =>
        {
            if (++reads != 1) return Task.FromResult(fixture.Api.Locations);
            blocked.TrySetResult();
            return locations.Task;
        };
        var holdingGate = fixture.Coordinator.GetLocationsAsync(CancellationToken.None);
        await blocked.Task.WaitAsync(Deadline);
        // The new login reaches the serialized coordinator before the stale
        // recovery request, while recovery's initial token check still sees old.
        var newLogin = fixture.Coordinator.ProvisionAuthenticatedSessionAsync(Session(NewToken), CancellationToken.None);
        var staleRecovery = fixture.Recovery.HandleAsync(oldEvent);
        await fixture.Stopped.Task.WaitAsync(Deadline);
        Check(!staleRecovery.IsCompleted, "The stale recovery did not queue behind the coordinator operation.");
        locations.TrySetResult(fixture.Api.Locations);
        await Task.WhenAll(holdingGate, newLogin, staleRecovery).WaitAsync(Deadline);

        Check(fixture.Store.State?.Session.AccessToken == NewToken && fixture.RefreshCalls == 0 &&
            fixture.Store.ClearCount == 0 && fixture.Vpn.DisconnectCount == 0 && fixture.MatchedSignOuts == 0 &&
            fixture.RestartTokens.Count == 0,
            "A stale recovery waiting for the coordinator gate acted on the replacement session.");
    }

    private static async Task UnauthorizedStreamStopsAfterOneRequestAsync()
    {
        var handler = new RecordingSseHandler(_ => new HttpResponseMessage(HttpStatusCode.Unauthorized));
        using var http = new HttpClient(handler)
        {
            BaseAddress = new Uri("https://realtime.example.test"),
            Timeout = Timeout.InfiniteTimeSpan,
        };
        await using var realtime = new CustomerRealtimeClient(http);
        var received = Result<CustomerRealtimeChangedEventArgs>();
        var events = 0;
        realtime.Changed += (_, args) =>
        {
            Interlocked.Increment(ref events);
            received.TrySetResult(args);
        };
        await realtime.StartAsync(OldToken);
        var first = await received.Task.WaitAsync(Deadline);
        // A rejected stream used to reconnect after its first one-second delay.
        // Leave the client alive across that boundary without a recovery handler.
        await Task.Delay(TimeSpan.FromMilliseconds(1150));
        Check(first.Event.Type == "customer.session.refresh_required" && events == 1 && handler.Tokens.Count == 1 &&
            !realtime.IsConnected,
            "HTTP 401 repeatedly replayed expired credentials or emitted a server revocation.");
    }

    private static VexAuthSession Session(string token) =>
        new(new VexUser("user-1", "user@example.com", "active"), token,
            new DateTimeOffset(2099, 8, 1, 0, 0, 0, TimeSpan.Zero));

    private static async Task SameTokenRefreshCannotReplayRejectedStreamAsync()
    {
        await using var fixture = new Fixture();
        fixture.Proxy.Overrides[nameof(INativeClientApi.RefreshSessionAsync)] = _ =>
        {
            fixture.RefreshCalls++;
            return Task.FromResult(Session(OldToken));
        };

        await fixture.StartAndRecoverAsync();
        await fixture.Realtime.StartAsync(OldToken);

        Check(fixture.RefreshCalls == 1 && fixture.Handler.Tokens.Count == 1 && fixture.Events.Count == 1 &&
            fixture.Store.State?.Session.AccessToken == OldToken && fixture.Vpn.DisconnectCount == 0,
            "Successful same-token refresh or duplicate start entered an expired-token SSE loop.");

        fixture.Proxy.Overrides[nameof(INativeClientApi.RefreshSessionAsync)] = _ =>
            Task.FromResult(Session(NewToken));
        var renewed = await fixture.Coordinator.ForceRefreshSessionAsync(CancellationToken.None, OldToken);
        await fixture.Realtime.StartAsync(renewed.Session.AccessToken);
        await fixture.Handler.FreshRequest.Task.WaitAsync(Deadline);

        Check(fixture.Handler.Tokens.Count == 2 && fixture.Handler.Tokens.Last() == NewToken &&
            fixture.Store.State?.Session.AccessToken == NewToken && fixture.Store.ClearCount == 0,
            "Pausing rejected credentials prevented a later fresh token from resuming SSE.");
    }

    private static async Task SilentStreamReconnectsWithoutSessionRecoveryAsync()
    {
        var firstStream = new QueuedStream();
        firstStream.Append("event: customer.heartbeat\nid: event-42\ndata: {}\n\n");
        var reconnected = Signal();
        var requests = 0;
        await using var fixture = new Fixture(streamResponse: _ =>
        {
            if (Interlocked.Increment(ref requests) == 1) return EventStream(firstStream);
            reconnected.TrySetResult();
            return EventStream("event: customer.heartbeat\ndata: {}\n\n");
        }, livenessTimeout: TimeSpan.FromMilliseconds(400));
        var disconnected = Result<bool>();
        fixture.Realtime.ConnectionChanged += (_, connected) =>
        {
            if (!connected) disconnected.TrySetResult(!fixture.Realtime.IsConnected &&
                firstStream.ReadCancelled && firstStream.Disposed && fixture.Handler.Tokens.Count == 1);
        };

        await fixture.Realtime.StartAsync(OldToken);
        await firstStream.Waiting.Task.WaitAsync(Deadline);
        Check(await disconnected.Task.WaitAsync(Deadline),
            "A silent SSE stream did not cancel/dispose its read and expose disconnected status before backoff.");
        await reconnected.Task.WaitAsync(Deadline);
        Check(fixture.Handler.Tokens.Count == 2 && fixture.Handler.Tokens.All(token => token == OldToken) &&
            fixture.Handler.LastEventIds.SequenceEqual([string.Empty, "event-42"]) &&
            fixture.Store.State?.Session.AccessToken == OldToken && fixture.Store.ClearCount == 0 &&
            fixture.RefreshCalls == 0 && fixture.MatchedSignOuts == 0 && fixture.Vpn.DisconnectCount == 0 &&
            fixture.Events.Count == 0,
            "SSE liveness recovery refreshed credentials, logged out, disconnected VPN or failed to reconnect.");
    }

    private static async Task PartialBytesAndHeartbeatsResetLivenessAsync()
    {
        var stream = new QueuedStream();
        await using var fixture = new Fixture(streamResponse: _ => EventStream(stream),
            livenessTimeout: TimeSpan.FromMilliseconds(600));
        var heartbeats = 0;
        var received = Signal();
        var allHeartbeats = Signal();
        var disconnects = 0;
        fixture.Realtime.ConnectionChanged += (_, connected) =>
        {
            if (!connected) Interlocked.Increment(ref disconnects);
        };
        fixture.Realtime.Changed += (_, args) =>
        {
            if (args.Event.Type == "customer.heartbeat")
            {
                if (Interlocked.Increment(ref heartbeats) == 6) allHeartbeats.TrySetResult();
                received.TrySetResult();
            }
        };

        await fixture.Realtime.StartAsync(OldToken);
        await stream.Waiting.Task.WaitAsync(Deadline);
        // No complete line is delivered for more than one liveness deadline.
        // Each byte chunk must extend the deadline without triggering refresh.
        foreach (var chunk in new[] { "event: ", "customer.", "heartbeat", "\ndata: ", "{}", "\n\n" })
        {
            await Task.Delay(TimeSpan.FromMilliseconds(160));
            stream.Append(chunk);
        }
        await received.Task.WaitAsync(Deadline);
        foreach (var _ in Enumerable.Range(0, 5))
        {
            await Task.Delay(TimeSpan.FromMilliseconds(160));
            stream.Append("event: customer.heartbeat\ndata: {}\n\n");
        }
        await allHeartbeats.Task.WaitAsync(Deadline);
        await fixture.Realtime.StopAsync().WaitAsync(Deadline);
        Check(heartbeats == 6 && disconnects == 1 && fixture.Handler.Tokens.Count == 1 &&
            fixture.RefreshCalls == 0 && fixture.Events.Count == 0 && fixture.Store.ClearCount == 0 &&
            fixture.Vpn.DisconnectCount == 0 && stream.ReadCancelled && stream.Disposed,
            "Partial stream bytes or active heartbeats failed to extend liveness without account/session refresh.");
    }

    private static async Task StopCancelsSilentStreamWithoutReconnectAsync()
    {
        var stream = new QueuedStream();
        await using var fixture = new Fixture(streamResponse: _ => EventStream(stream),
            livenessTimeout: TimeSpan.FromMilliseconds(200));
        await fixture.Realtime.StartAsync(OldToken);
        await stream.Waiting.Task.WaitAsync(Deadline);
        await fixture.Realtime.StopAsync().WaitAsync(Deadline);
        await Task.Delay(TimeSpan.FromMilliseconds(1150));
        Check(stream.ReadCancelled && stream.Disposed && !fixture.Realtime.IsConnected &&
            fixture.Handler.Tokens.Count == 1 && fixture.Events.Count == 0 && fixture.RefreshCalls == 0 &&
            fixture.Store.ClearCount == 0 && fixture.Vpn.DisconnectCount == 0,
            "Explicit SSE stop was treated as a liveness/auth failure or reconnected after cancellation.");
    }

    private static async Task SilentResponseHeadersRetryWithoutSessionRecoveryAsync()
    {
        var handler = new SilentHeadersHandler();
        using var http = new HttpClient(handler)
        {
            BaseAddress = new Uri("https://realtime.example.test"),
            Timeout = Timeout.InfiniteTimeSpan,
        };
        await using var realtime = new CustomerRealtimeClient(http, TimeSpan.FromMilliseconds(200));
        var authEvents = 0;
        realtime.Changed += (_, _) => Interlocked.Increment(ref authEvents);
        await realtime.StartAsync(OldToken);
        await handler.Retried.Task.WaitAsync(Deadline);
        await realtime.StopAsync().WaitAsync(Deadline);
        Check(handler.Requests == 2 && handler.CancelledReads == 2 && authEvents == 0 && !realtime.IsConnected,
            "Stalled SSE response headers did not time out/retry or were misclassified as rejected credentials.");
    }

    private static TaskCompletionSource Signal() => new(TaskCreationOptions.RunContinuationsAsynchronously);
    private static TaskCompletionSource<T> Result<T>() => new(TaskCreationOptions.RunContinuationsAsynchronously);
    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private sealed class Fixture : IAsyncDisposable
    {
        private readonly HttpClient _http;
        private readonly bool _autoRecover;
        private readonly TaskCompletionSource<Task> _handling = Result<Task>();
        private readonly TaskCompletionSource<CustomerRealtimeChangedEventArgs> _firstEvent = Result<CustomerRealtimeChangedEventArgs>();
        public FakeNativeClientApi Api { get; } = new();
        public NativeApiProxy Proxy { get; }
        public CountingStateStore Store { get; } = new();
        public CountingVpnClient Vpn { get; } = new();
        public NativeClientCoordinator Coordinator { get; }
        public CustomerRealtimeClient Realtime { get; }
        public CustomerRealtimeSessionRecovery Recovery { get; }
        public RecordingSseHandler Handler { get; }
        public ConcurrentQueue<CustomerRealtimeChangedEventArgs> Events { get; } = new();
        public List<string> RestartTokens { get; } = [];
        public List<int> Delays { get; } = [];
        public TaskCompletionSource Stopped { get; } = Signal();
        public int RefreshCalls { get; set; }
        public int StopCalls { get; private set; }
        public int MatchedSignOuts { get; private set; }

        public Fixture(bool revoked = false, bool autoRecover = true, string? revokedPayload = null,
            Func<string, HttpResponseMessage>? streamResponse = null, TimeSpan? livenessTimeout = null)
        {
            _autoRecover = autoRecover;
            Store.Save(new NativeClientState(Session(OldToken), "realtime-installation", "device-1", "fi-1",
                WireGuardIdentity.Generate()));
            var (api, proxy) = NativeApiProxy.Wrap(Api);
            Proxy = proxy;
            Proxy.Overrides[nameof(INativeClientApi.RefreshSessionAsync)] = _ =>
            {
                RefreshCalls++;
                return Task.FromResult(Session(NewToken));
            };
            Coordinator = new NativeClientCoordinator(api, Store, Vpn, "1.0.0");
            Handler = new RecordingSseHandler(streamResponse ?? (token => token == OldToken && !revoked
                ? new HttpResponseMessage(HttpStatusCode.Unauthorized)
                : EventStream(token == OldToken
                    ? "event: customer.session.revoked\ndata: " + (revokedPayload ?? "{\"reason\":\"session_invalid\"}") + "\n\n"
                    : "event: customer.heartbeat\ndata: {}\n\n")));
            _http = new HttpClient(Handler)
            {
                BaseAddress = new Uri("https://realtime.example.test"),
                Timeout = Timeout.InfiniteTimeSpan,
            };
            Realtime = new CustomerRealtimeClient(_http, livenessTimeout);
            Recovery = new CustomerRealtimeSessionRecovery(Coordinator,
                async (token, cancellationToken) =>
                {
                    RestartTokens.Add(token);
                    await Realtime.StartAsync(token, cancellationToken);
                },
                async () =>
                {
                    StopCalls++;
                    await Realtime.StopAsync();
                    Stopped.TrySetResult();
                },
                (token, cancellationToken) =>
                {
                    var signingOut = Coordinator.SignOutAsync(cancellationToken,
                        expectedAccessToken: token, onMatchedSignOut: () => MatchedSignOuts++);
                    return signingOut;
                },
                (attempt, token) =>
                {
                    token.ThrowIfCancellationRequested();
                    Delays.Add(attempt);
                    return Task.CompletedTask;
                });
            Realtime.Changed += (_, args) =>
            {
                if (args.Event.Type is not ("customer.session.revoked" or "customer.session.refresh_required")) return;
                Events.Enqueue(args);
                _firstEvent.TrySetResult(args);
                if (_autoRecover) _handling.TrySetResult(Recovery.HandleAsync(args));
            };
        }

        public async Task StartAndRecoverAsync()
        {
            await Realtime.StartAsync(OldToken);
            var handling = await _handling.Task.WaitAsync(Deadline);
            await handling.WaitAsync(Deadline);
        }

        public async Task<CustomerRealtimeChangedEventArgs> StartAndCaptureAsync()
        {
            await Realtime.StartAsync(OldToken);
            return await _firstEvent.Task.WaitAsync(Deadline);
        }

        public async ValueTask DisposeAsync()
        {
            await Realtime.DisposeAsync();
            _http.Dispose();
        }
    }

    private static HttpResponseMessage EventStream(string prefix) => EventStream(new PrefixThenWaitStream(prefix));

    private static HttpResponseMessage EventStream(Stream stream)
    {
        var response = new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StreamContent(stream),
        };
        response.Content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("text/event-stream");
        return response;
    }

    private sealed class RecordingSseHandler(Func<string, HttpResponseMessage> respond) : HttpMessageHandler
    {
        public ConcurrentQueue<string> Tokens { get; } = new();
        public ConcurrentQueue<string> LastEventIds { get; } = new();
        public TaskCompletionSource FreshRequest { get; } = Signal();
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Check(request.RequestUri?.AbsolutePath == "/v1/events" && request.Headers.Authorization?.Scheme == "Bearer" &&
                request.Headers.Accept.Any(item => item.MediaType == "text/event-stream"),
                "The session regression fixture did not exercise the real authenticated SSE endpoint.");
            var token = request.Headers.Authorization!.Parameter!;
            Tokens.Enqueue(token);
            LastEventIds.Enqueue(request.Headers.TryGetValues("Last-Event-ID", out var ids) ? ids.Single() : string.Empty);
            if (token == NewToken) FreshRequest.TrySetResult();
            return Task.FromResult(respond(token));
        }
    }

    private sealed class SilentHeadersHandler : HttpMessageHandler
    {
        private int _requests;
        private int _cancelledReads;
        public int Requests => Volatile.Read(ref _requests);
        public int CancelledReads => Volatile.Read(ref _cancelledReads);
        public TaskCompletionSource Retried { get; } = Signal();

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request, CancellationToken cancellationToken)
        {
            if (Interlocked.Increment(ref _requests) == 2) Retried.TrySetResult();
            try
            {
                await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
                throw new InvalidOperationException("The silent header fixture unexpectedly completed.");
            }
            catch (OperationCanceledException)
            {
                Interlocked.Increment(ref _cancelledReads);
                throw;
            }
        }
    }

    private sealed class QueuedStream : Stream
    {
        private readonly Channel<byte[]> _chunks = Channel.CreateUnbounded<byte[]>();
        private byte[]? _current;
        private int _position;
        public TaskCompletionSource Waiting { get; } = Signal();
        public bool ReadCancelled { get; private set; }
        public bool Disposed { get; private set; }
        public void Append(string chunk) => Check(_chunks.Writer.TryWrite(Encoding.UTF8.GetBytes(chunk)),
            "The controlled SSE fixture rejected a byte chunk.");
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => _position; set => throw new NotSupportedException(); }

        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            try
            {
                if (_current is null || _position == _current.Length)
                {
                    Waiting.TrySetResult();
                    _current = await _chunks.Reader.ReadAsync(cancellationToken);
                    _position = 0;
                }
                var read = Math.Min(buffer.Length, _current.Length - _position);
                _current.AsMemory(_position, read).CopyTo(buffer);
                _position += read;
                return read;
            }
            catch (OperationCanceledException)
            {
                ReadCancelled = true;
                throw;
            }
        }

        public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
            ReadAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();
        protected override void Dispose(bool disposing)
        {
            Disposed = true;
            base.Dispose(disposing);
        }
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }

    private sealed class PrefixThenWaitStream(string prefix) : Stream
    {
        private readonly byte[] _prefix = Encoding.UTF8.GetBytes(prefix);
        private int _position;
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => _position; set => throw new NotSupportedException(); }
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            if (_position < _prefix.Length)
            {
                var length = Math.Min(buffer.Length, _prefix.Length - _position);
                _prefix.AsMemory(_position, length).CopyTo(buffer);
                _position += length;
                return length;
            }
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            return 0;
        }
        public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
            ReadAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }

    private sealed class CountingStateStore : IClientStateStore
    {
        public NativeClientState? State { get; private set; }
        public int ClearCount { get; private set; }
        public ClientStateAccessKind GetAccessState() => State is null ? ClientStateAccessKind.Missing : ClientStateAccessKind.Available;
        public string GetOrCreateInstallationId() => "realtime-installation";
        public NativeClientState? Load() => State;
        public NativeDeviceState? LoadDevice() => State is null ? null
            : new(State.InstallationId, State.DeviceId, State.LocationId, State.Identity);
        public void Save(NativeClientState state) => State = state;
        public void Clear()
        {
            ClearCount++;
            State = null;
        }
    }

    private sealed class CountingVpnClient : IVpnControlClient
    {
        public int DisconnectCount { get; private set; }
        public Task<VpnServiceResponse> GetStatusAsync(CancellationToken cancellationToken) =>
            Task.FromResult(new VpnServiceResponse("realtime-status", true,
                new VpnConnectionSnapshot(VpnConnectionPhase.Connected, "fi-1", 1, null), null));
        public Task<VpnServiceResponse> ConnectAsync(VpnProfileAuthorization authorization, string privateKey,
            CancellationToken cancellationToken) => throw new InvalidOperationException("Realtime recovery must not connect VPN.");
        public Task<VpnServiceResponse> DisconnectAsync(CancellationToken cancellationToken)
        {
            DisconnectCount++;
            return Task.FromResult(new VpnServiceResponse("realtime-disconnect", true, VpnConnectionSnapshot.Disconnected(), null));
        }
    }
}
