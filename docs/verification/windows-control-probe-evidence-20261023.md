# Windows control HTTPS probe evidence

The full tunnel fixture probes the public control host using an explicitly bound
physical IPv4 socket. Its earlier TCP prebaseline targets a different public
address. A successful prebaseline therefore does not prove TCP connectivity to
the control host. The public HTTPS probe retains its five-second connect bound,
eight-second operation bound, normal certificate/hostname validation, exact
host/port scope, no proxy or redirects, and original failure verdict.

The runtime's connect timeout can also cover TLS setup. The
[.NET 10.0.13 implementation](https://github.com/dotnet/runtime/blob/v10.0.13/src/libraries/System.Net.Http/src/System/Net/Http/SocketsHttpHandler/ConnectionPool/HttpConnectionPool.cs)
reports this timeout through an OperationCanceledException with an immediate
TimeoutException. Parent cancellation=false and operation budget expiry=false
do not by themselves locate the failure in TCP or TLS.

## Typed connection observation

`full_control_probe_tcp_connected` is a nullable boolean, sampled in the probe's
`SendAsync` finally block:

| Value | Evidence at that snapshot |
| --- | --- |
| null | The socket-connect helper had not been entered |
| false | A connect was attempted, with no TCP completion observed yet |
| true | At least one TCP connect completed |

The helper marks completion immediately after `Socket.ConnectAsync`, before
returning the owning NetworkStream for HttpClient's TLS work. Its per-probe
state is atomic and monotonic. An async callback never mutates the result
dictionary. A later completion cannot retroactively change the saved snapshot,
and a failed subsequent attempt cannot erase an earlier completion.

The PowerShell summary accepts only actual bool values; missing, null, numeric
and string values remain null. It emits no destination/source addresses, paths,
exception bodies, credentials or account data. Existing three cancellation
observations retain their semantics. This field does not qualify a successful
HTTP response, certificate, tunnel, cleanup or customer recovery.

## Executed local scope

The portable suite links the actual connection helper and exercises owned
loopback sockets: failed/closed socket cleanup, caller cancellation, connected
stream ownership and bytes, a TLS ClientHello followed by a stalled handshake,
and rejection of a matching-host but untrusted certificate under default TLS
validation. The TLS stall produces a connect timeout after TCP completion while
the outer caller is still live. No system trust, VPN, routes, DNS or firewall
state is changed by these scenarios.

Local qualification: 271 portable Windows test groups pass, strict PowerShell
summary tests pass, the existing full portable client check passes, and the
explicit win-x64 fixture cross-build passes. These checks do not execute the
real Windows tunnel fixture on macOS. Source inverse checks restore the previous
probe/wrapper byte-for-byte after removing the extraction and new observation;
physical targets, TLS, budgets, lease, gates and cleanup remain unchanged.

The preceding exact head `259f8d08` has a
[Windows tunnel failure](https://github.com/ibotpafos/vex-client/actions/runs/39905240347/job/120255578238)
at `full-control-https-baseline`, with parent=false, budget=false,
innerTimeout=true and cleanup=true. It has no TCP-completion observation; its
underlying TCP/TLS cause remains unresolved. Current exact-head CI is tracked
separately in PR136. This record does not announce a fixed tunnel or a release.
