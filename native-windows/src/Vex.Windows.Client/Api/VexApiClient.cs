using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Net;
using System.Text.Json;
using System.Text.Json.Serialization;
using Vex.Windows.Client.Security;

namespace Vex.Windows.Client.Api;

public interface INativeClientApi
{
    Task<VexUser> GetCurrentUserAsync(
        string accessToken,
        CancellationToken cancellationToken);

    Task<VexAuthSession> LoginAsync(
        string email,
        string password,
        CancellationToken cancellationToken);

    Task<EmailOtpChallenge> RequestEmailOtpAsync(
        string email,
        CancellationToken cancellationToken);

    Task<VexAuthSession> ConfirmEmailOtpAsync(
        string email,
        string challengeId,
        string code,
        CancellationToken cancellationToken);

    Task<VexAuthSession> ExchangeAppAuthCodeAsync(
        string code,
        string codeVerifier,
        CancellationToken cancellationToken);

    Task<VexAuthSession> RefreshSessionAsync(
        string accessToken,
        CancellationToken cancellationToken);

    Task<IReadOnlyList<VpnLocation>> GetLocationsAsync(
        string accessToken,
        CancellationToken cancellationToken);

    Task<VpnDevice> RegisterNativeDeviceAsync(
        string accessToken,
        string installationId,
        string publicKey,
        int keyEpoch,
        string locationId,
        string appVersion,
        CancellationToken cancellationToken);

    Task<ManagedVpnProfile> GetManagedVpnProfileAsync(
        string accessToken,
        string deviceId,
        string locationId,
        string routingMode,
        string? bypassRegion,
        int? knownVersion,
        CancellationToken cancellationToken);

    Task<VpnDevice> RotateManagedVpnKeyAsync(
        string accessToken,
        string deviceId,
        WireGuardIdentity identity,
        CancellationToken cancellationToken);

    Task<VexEntitlement> GetBillingEntitlementAsync(
        string accessToken,
        CancellationToken cancellationToken);

    Task<BillingSummary> GetBillingSummaryAsync(
        string accessToken,
        CancellationToken cancellationToken);

    Task<CheckoutSession> CreateCheckoutSessionAsync(
        string accessToken,
        string planId,
        string? provider,
        CancellationToken cancellationToken);

    Task<BillingPortalSession> GetBillingPortalSessionAsync(
        string accessToken,
        CancellationToken cancellationToken);

    Task<VexEntitlement> CancelSubscriptionAsync(
        string accessToken,
        CancellationToken cancellationToken);

    Task<IReadOnlyList<BillingPayment>> GetBillingPaymentsAsync(
        string accessToken,
        int limit,
        CancellationToken cancellationToken);

    Task<IReadOnlyList<VpnDevice>> GetDevicesAsync(
        string accessToken,
        CancellationToken cancellationToken);

    Task<IReadOnlyList<VpnDeviceUsage>> GetDeviceUsageAsync(
        string accessToken,
        CancellationToken cancellationToken);

    Task ReportVpnConnectAsync(
        string accessToken,
        VpnConnectionTelemetry telemetry,
        CancellationToken cancellationToken);

    Task ReportVpnDisconnectAsync(
        string accessToken,
        VpnConnectionTelemetry telemetry,
        CancellationToken cancellationToken);

    Task SubmitClientDiagnosticsAsync(
        string accessToken,
        ClientDiagnosticsReport report,
        CancellationToken cancellationToken);

    Task<IReadOnlyList<SupportTicket>> GetSupportTicketsAsync(
        string accessToken,
        CancellationToken cancellationToken);

    Task<SupportTicket> CreateSupportTicketAsync(
        string accessToken,
        string subject,
        string message,
        string source,
        CancellationToken cancellationToken);

    Task<Uri> GetSupportWebSocketUriAsync(
        string accessToken,
        CancellationToken cancellationToken);

    Task<AppRemoteConfig> GetRemoteConfigAsync(
        ClientAppMetadata metadata,
        CancellationToken cancellationToken);

    Task<AppUpdateCheckResult> CheckForAppUpdateAsync(
        ClientAppMetadata metadata,
        CancellationToken cancellationToken);
}

public sealed class VexApiClient : INativeClientApi
{
    private const int MaximumResponseBytes = 1024 * 1024;
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = false,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Skip,
    };

    private readonly HttpClient _httpClient;
    private readonly IDeviceIdentityProvider? _deviceIdentityProvider;

    public VexApiClient(
        HttpClient httpClient,
        IDeviceIdentityProvider? deviceIdentityProvider = null)
    {
        ArgumentNullException.ThrowIfNull(httpClient);
        if (httpClient.BaseAddress is null ||
            (!httpClient.BaseAddress.IsLoopback &&
             httpClient.BaseAddress.Scheme != Uri.UriSchemeHttps))
        {
            throw new ArgumentException(
                "The VEX API base address must use HTTPS.",
                nameof(httpClient));
        }

        _httpClient = httpClient;
        _deviceIdentityProvider = deviceIdentityProvider;
    }

    public Uri BaseUri => _httpClient.BaseAddress!;

    public async Task<VexUser> GetCurrentUserAsync(
        string accessToken,
        CancellationToken cancellationToken)
    {
        using var request = Authorized(
            HttpMethod.Get,
            "/v1/auth/me",
            accessToken);
        return await SendAsync<VexUser>(
            request,
            cancellationToken).ConfigureAwait(false);
    }

    public async Task<VexAuthSession> LoginAsync(
        string email,
        string password,
        CancellationToken cancellationToken)
    {
        email = NormalizeEmail(email, nameof(email));
        if (string.IsNullOrEmpty(password) || password.Length > 1024)
        {
            throw new ArgumentException("Invalid login credentials.");
        }

        using var request = new HttpRequestMessage(
            HttpMethod.Post,
            "/v1/auth/login")
        {
            Content = JsonContent.Create(new
            {
                email,
                password,
                remember_me = true,
                device_session = true,
            }),
        };
        var response = await SendAsync<AuthResponse>(
            request,
            cancellationToken).ConfigureAwait(false);
        return new VexAuthSession(
            response.User,
            response.Session.AccessToken,
            response.Session.ExpiresAt);
    }

    public async Task<EmailOtpChallenge> RequestEmailOtpAsync(
        string email,
        CancellationToken cancellationToken)
    {
        email = NormalizeEmail(email, nameof(email));
        using var request = new HttpRequestMessage(
            HttpMethod.Post,
            "/v1/auth/email-otp/request")
        {
            Content = JsonContent.Create(new
            {
                email,
            }),
        };
        var response = await SendAsync<EmailOtpChallengeResponse>(
            request,
            cancellationToken).ConfigureAwait(false);
        return new EmailOtpChallenge(
            response.ChallengeId,
            response.ExpiresAt);
    }

    public async Task<VexAuthSession> ConfirmEmailOtpAsync(
        string email,
        string challengeId,
        string code,
        CancellationToken cancellationToken)
    {
        email = NormalizeEmail(email, nameof(email));
        ValidateIdentifier(challengeId, nameof(challengeId));
        code = code.Trim();
        if (code.Length is < 4 or > 32 ||
            code.Any(character => !char.IsAsciiLetterOrDigit(character)))
        {
            throw new ArgumentException("Email OTP code is invalid.", nameof(code));
        }

        using var request = new HttpRequestMessage(
            HttpMethod.Post,
            "/v1/auth/email-otp/confirm")
        {
            Content = JsonContent.Create(new
            {
                email,
                challenge_id = challengeId,
                code,
                remember_me = true,
                device_session = true,
            }),
        };
        var response = await SendAsync<AuthResponse>(
            request,
            cancellationToken).ConfigureAwait(false);
        return new VexAuthSession(
            response.User,
            response.Session.AccessToken,
            response.Session.ExpiresAt);
    }

    public async Task<VexAuthSession> ExchangeAppAuthCodeAsync(
        string code,
        string codeVerifier,
        CancellationToken cancellationToken)
    {
        code = code.Trim();
        if (code.Length is < 8 or > 4096)
        {
            throw new ArgumentException("Auth code is invalid.", nameof(code));
        }

        ValidatePkceVerifier(codeVerifier, nameof(codeVerifier));
        using var request = new HttpRequestMessage(
            HttpMethod.Post,
            "/v1/auth/token")
        {
            Content = JsonContent.Create(new
            {
                code,
                code_verifier = codeVerifier,
            }),
        };
        var response = await SendAsync<AuthResponse>(
            request,
            cancellationToken).ConfigureAwait(false);
        return new VexAuthSession(
            response.User,
            response.Session.AccessToken,
            response.Session.ExpiresAt);
    }

    public async Task<IReadOnlyList<VpnLocation>> GetLocationsAsync(
        string accessToken,
        CancellationToken cancellationToken)
    {
        using var request = Authorized(
            HttpMethod.Get,
            "/v1/locations",
            accessToken);
        var locations = await SendAsync<List<VpnLocation>>(
            request,
            cancellationToken).ConfigureAwait(false);
        return locations
            .Where(location =>
                location.HealthyNodes > 0 &&
                location.Availability != "retired")
            .ToArray();
    }

    public async Task<VexAuthSession> RefreshSessionAsync(
        string accessToken,
        CancellationToken cancellationToken)
    {
        using var request = Authorized(
            HttpMethod.Post,
            "/v1/auth/refresh",
            accessToken);
        var response = await SendAsync<AuthResponse>(
            request,
            cancellationToken).ConfigureAwait(false);
        return new VexAuthSession(
            response.User,
            response.Session.AccessToken,
            response.Session.ExpiresAt);
    }

    public async Task<VpnDevice> RegisterNativeDeviceAsync(
        string accessToken,
        string installationId,
        string publicKey,
        int keyEpoch,
        string locationId,
        string appVersion,
        CancellationToken cancellationToken)
    {
        ValidateIdentifier(installationId, nameof(installationId));
        ValidateIdentifier(locationId, nameof(locationId));
        ValidateWireGuardKey(publicKey);
        if (keyEpoch < 1)
        {
            throw new ArgumentOutOfRangeException(nameof(keyEpoch));
        }

        using var request = Authorized(
            HttpMethod.Post,
            "/v1/devices/register",
            accessToken);
        var identityRegistration = await BuildIdentityRegistrationAsync(
            accessToken,
            installationId,
            publicKey,
            cancellationToken).ConfigureAwait(false);
        if (_deviceIdentityProvider is not null &&
            identityRegistration is null)
        {
            throw new VexApiException(
                HttpStatusCode.PreconditionFailed,
                "device_identity_challenge_failed");
        }

        request.Headers.Add(
            "Idempotency-Key",
            $"native-windows-register-{installationId}-{keyEpoch}-{(identityRegistration is null ? "legacy" : "verified")}");
        var payload = new Dictionary<string, object?>
        {
            ["device_id"] = installationId,
            ["installation_id"] = installationId,
            ["device_name"] = "Windows",
            ["platform"] = "windows",
            ["app_version"] = appVersion,
            ["protocol"] = "amneziawg",
            ["location"] = locationId,
            ["public_key"] = publicKey,
            ["key_epoch"] = keyEpoch,
        };
        if (identityRegistration is not null)
        {
            payload["identity_public_key"] =
                identityRegistration.IdentityPublicKey;
            payload["identity_key_type"] =
                identityRegistration.IdentityKeyType;
            payload["identity_challenge_id"] =
                identityRegistration.IdentityChallengeId;
            payload["identity_signature"] =
                identityRegistration.IdentitySignature;
        }

        request.Content = JsonContent.Create(payload);
        var response = await SendAsync<NativeDeviceRegistrationResponse>(
            request,
            cancellationToken).ConfigureAwait(false);
        return response.Device;
    }

    public async Task<ManagedVpnProfile> GetManagedVpnProfileAsync(
        string accessToken,
        string deviceId,
        string locationId,
        string routingMode,
        string? bypassRegion,
        int? knownVersion,
        CancellationToken cancellationToken)
    {
        ValidateIdentifier(deviceId, nameof(deviceId));
        ValidateIdentifier(locationId, nameof(locationId));
        if (routingMode is not ("full" or "split"))
        {
            throw new ArgumentException(
                "Routing mode is invalid.",
                nameof(routingMode));
        }
        if (knownVersion is { } version &&
            version <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(knownVersion));
        }

        var path =
            "/v1/vpn/profile?device_id=" +
            Uri.EscapeDataString(deviceId) +
            "&location=" +
            Uri.EscapeDataString(locationId) +
            "&routing_mode=" +
            routingMode +
            "&platform=windows" +
            "&awg_version=3" +
            (string.IsNullOrWhiteSpace(bypassRegion)
                ? string.Empty
                : "&bypass_region=" +
                  Uri.EscapeDataString(bypassRegion.Trim().ToLowerInvariant())) +
            (knownVersion is null
                ? string.Empty
                : "&known_version=" +
                  knownVersion.Value.ToString(
                      System.Globalization.CultureInfo.InvariantCulture));
        using var request = Authorized(
            HttpMethod.Get,
            path,
            accessToken);
        return await SendAsync<ManagedVpnProfile>(
            request,
            cancellationToken).ConfigureAwait(false);
    }

    public Task<ManagedVpnProfile> GetManagedVpnProfileAsync(
        string accessToken,
        string deviceId,
        string locationId,
        string routingMode,
        int? knownVersion,
        CancellationToken cancellationToken) =>
        GetManagedVpnProfileAsync(
            accessToken,
            deviceId,
            locationId,
            routingMode,
            bypassRegion: null,
            knownVersion,
            cancellationToken);

    public async Task<VpnDevice> RotateManagedVpnKeyAsync(
        string accessToken,
        string deviceId,
        WireGuardIdentity identity,
        CancellationToken cancellationToken)
    {
        ValidateIdentifier(deviceId, nameof(deviceId));
        ArgumentNullException.ThrowIfNull(identity);
        ValidateWireGuardKey(identity.PublicKey);
        using var request = Authorized(
            HttpMethod.Post,
            "/v1/vpn/rotate-key",
            accessToken);
        request.Headers.Add(
            "Idempotency-Key",
            $"native-windows-rotate-{deviceId}-{identity.KeyEpoch}");
        request.Content = JsonContent.Create(new
        {
            device_id = deviceId,
            public_key = identity.PublicKey,
            key_epoch = identity.KeyEpoch,
        });
        var response = await SendAsync<NativeDeviceRegistrationResponse>(
            request,
            cancellationToken).ConfigureAwait(false);
        return response.Device;
    }

    public Task<VexEntitlement> GetBillingEntitlementAsync(
        string accessToken,
        CancellationToken cancellationToken)
    {
        using var request = Authorized(
            HttpMethod.Get,
            "/v1/billing/entitlement",
            accessToken);
        return SendAsync<VexEntitlement>(
            request,
            cancellationToken);
    }

    public async Task<BillingSummary> GetBillingSummaryAsync(
        string accessToken,
        CancellationToken cancellationToken)
    {
        var plansTask = GetBillingPlansAsync(cancellationToken);
        var entitlementTask = GetBillingEntitlementAsync(
            accessToken,
            cancellationToken);
        var plans = await plansTask.ConfigureAwait(false);
        var entitlement = await entitlementTask.ConfigureAwait(false);
        return BillingSummaryBuilder.Build(plans, entitlement);
    }

    public async Task<CheckoutSession> CreateCheckoutSessionAsync(
        string accessToken,
        string planId,
        string? provider,
        CancellationToken cancellationToken)
    {
        ValidateIdentifier(planId, nameof(planId));
        using var request = Authorized(
            HttpMethod.Post,
            "/v1/billing/checkout-session",
            accessToken);
        request.Headers.Add(
            "Idempotency-Key",
            $"native-windows-checkout-{planId}-{DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()}");
        request.Content = JsonContent.Create(new
        {
            plan_id = planId,
            provider = string.IsNullOrWhiteSpace(provider)
                ? "platega"
                : provider,
            return_url = _httpClient.BaseAddress!.AbsoluteUri,
            failed_url = _httpClient.BaseAddress!.AbsoluteUri,
        });
        return await SendAsync<CheckoutSession>(
            request,
            cancellationToken).ConfigureAwait(false);
    }

    public async Task<BillingPortalSession> GetBillingPortalSessionAsync(
        string accessToken,
        CancellationToken cancellationToken)
    {
        using var request = Authorized(
            HttpMethod.Get,
            "/v1/billing/portal-session",
            accessToken);
        return await SendAsync<BillingPortalSession>(
            request,
            cancellationToken).ConfigureAwait(false);
    }

    public async Task<VexEntitlement> CancelSubscriptionAsync(
        string accessToken,
        CancellationToken cancellationToken)
    {
        using var request = Authorized(
            HttpMethod.Post,
            "/v1/billing/subscription/cancel",
            accessToken);
        request.Headers.Add(
            "Idempotency-Key",
            $"native-windows-subscription-cancel-{DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()}");
        return await SendAsync<VexEntitlement>(
            request,
            cancellationToken).ConfigureAwait(false);
    }

    public async Task<IReadOnlyList<BillingPayment>> GetBillingPaymentsAsync(
        string accessToken,
        int limit,
        CancellationToken cancellationToken)
    {
        if (limit is < 1 or > 100)
        {
            throw new ArgumentOutOfRangeException(nameof(limit));
        }

        using var request = Authorized(
            HttpMethod.Get,
            "/v1/billing/payments?limit=" +
            limit.ToString(System.Globalization.CultureInfo.InvariantCulture),
            accessToken);
        return await SendAsync<List<BillingPayment>>(
            request,
            cancellationToken).ConfigureAwait(false);
    }

    public async Task<IReadOnlyList<VpnDevice>> GetDevicesAsync(
        string accessToken,
        CancellationToken cancellationToken)
    {
        using var request = Authorized(
            HttpMethod.Get,
            "/v1/devices",
            accessToken);
        return await SendAsync<List<VpnDevice>>(
            request,
            cancellationToken).ConfigureAwait(false);
    }

    public async Task<IReadOnlyList<VpnDeviceUsage>> GetDeviceUsageAsync(
        string accessToken,
        CancellationToken cancellationToken)
    {
        using var request = Authorized(
            HttpMethod.Get,
            "/v1/devices/usage",
            accessToken);
        var response = await SendAsync<VpnDeviceUsageResponse>(
            request,
            cancellationToken).ConfigureAwait(false);
        return response.Usage ?? [];
    }

    public Task ReportVpnConnectAsync(
        string accessToken,
        VpnConnectionTelemetry telemetry,
        CancellationToken cancellationToken) =>
        ReportVpnLifecycleAsync(
            "/v1/vpn/connect",
            accessToken,
            telemetry,
            cancellationToken);

    public Task ReportVpnDisconnectAsync(
        string accessToken,
        VpnConnectionTelemetry telemetry,
        CancellationToken cancellationToken) =>
        ReportVpnLifecycleAsync(
            "/v1/vpn/disconnect",
            accessToken,
            telemetry,
            cancellationToken);

    public async Task SubmitClientDiagnosticsAsync(
        string accessToken,
        ClientDiagnosticsReport report,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(report);
        using var request = Authorized(
            HttpMethod.Post,
            "/v1/diagnostics/client",
            accessToken);
        request.Content = JsonContent.Create(report);
        await SendWithoutResponseAsync(
            request,
            cancellationToken).ConfigureAwait(false);
    }

    public async Task<IReadOnlyList<SupportTicket>> GetSupportTicketsAsync(
        string accessToken,
        CancellationToken cancellationToken)
    {
        using var request = Authorized(
            HttpMethod.Get,
            "/v1/support-tickets",
            accessToken);
        var tickets = await SendAsync<List<SupportTicket>?>(
            request,
            cancellationToken).ConfigureAwait(false);
        return tickets ?? [];
    }

    public async Task<SupportTicket> CreateSupportTicketAsync(
        string accessToken,
        string subject,
        string message,
        string source,
        CancellationToken cancellationToken)
    {
        subject = subject.Trim();
        message = message.Trim();
        source = source.Trim();
        if (subject.Length == 0 ||
            message.Length == 0 ||
            source.Length == 0)
        {
            throw new ArgumentException("Support ticket payload is invalid.");
        }

        using var request = Authorized(
            HttpMethod.Post,
            "/v1/support-tickets",
            accessToken);
        request.Headers.Add(
            "Idempotency-Key",
            $"native-windows-support-{DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()}");
        request.Content = JsonContent.Create(new
        {
            subject,
            message,
            source,
        });
        return await SendAsync<SupportTicket>(
            request,
            cancellationToken).ConfigureAwait(false);
    }

    public async Task<Uri> GetSupportWebSocketUriAsync(
        string accessToken,
        CancellationToken cancellationToken)
    {
        using var request = Authorized(
            HttpMethod.Get,
            "/v1/support-ws-ticket",
            accessToken);
        var response = await SendAsync<SupportSocketTicketResponse>(
            request,
            cancellationToken).ConfigureAwait(false);
        var ticket = response.Ticket?.Trim();
        if (string.IsNullOrEmpty(ticket))
        {
            throw new VexApiException(
                HttpStatusCode.BadGateway,
                "support_socket_ticket_invalid");
        }

        var builder = new UriBuilder(_httpClient.BaseAddress!)
        {
            Scheme = _httpClient.BaseAddress!.Scheme == Uri.UriSchemeHttps
                ? "wss"
                : "ws",
            Port = _httpClient.BaseAddress!.IsDefaultPort
                ? -1
                : _httpClient.BaseAddress.Port,
            Path = "/v1/support-ws",
            Query = "ticket=" + Uri.EscapeDataString(ticket),
        };
        return builder.Uri;
    }

    public Task<AppRemoteConfig> GetRemoteConfigAsync(
        ClientAppMetadata metadata,
        CancellationToken cancellationToken) =>
        SendAppMetadataAsync<AppRemoteConfig>(
            "/v1/app/remote-config",
            metadata,
            cancellationToken);

    public Task<AppUpdateCheckResult> CheckForAppUpdateAsync(
        ClientAppMetadata metadata,
        CancellationToken cancellationToken) =>
        SendAppMetadataAsync<AppUpdateCheckResult>(
            "/v1/app/update/check",
            metadata,
            cancellationToken);

    private async Task ReportVpnLifecycleAsync(
        string path,
        string accessToken,
        VpnConnectionTelemetry telemetry,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(telemetry);
        ValidateIdentifier(telemetry.DeviceId, nameof(telemetry.DeviceId));
        using var request = Authorized(HttpMethod.Post, path, accessToken);
        request.Content = JsonContent.Create(new
        {
            device_id = telemetry.DeviceId,
            client_time = DateTimeOffset.UtcNow,
            profile_version = telemetry.ProfileVersion,
            protocol = telemetry.Protocol,
            reason = telemetry.Reason,
        });
        await SendWithoutResponseAsync(
            request,
            cancellationToken).ConfigureAwait(false);
    }

    private async Task<T> SendAppMetadataAsync<T>(
        string path,
        ClientAppMetadata metadata,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(metadata);
        using var request = new HttpRequestMessage(HttpMethod.Post, path)
        {
            Content = JsonContent.Create(new
            {
                platform = metadata.Platform,
                appVersion = metadata.AppVersion,
                buildNumber = metadata.BuildNumber,
                channel = metadata.Channel,
                coreVersion = metadata.CoreVersion,
                osVersion = metadata.OsVersion,
                arch = metadata.Architecture,
                apiClientVersion = metadata.ApiClientVersion,
                configSchemaVersion = metadata.ConfigSchemaVersion,
            }),
        };
        return await SendAsync<T>(
            request,
            cancellationToken).ConfigureAwait(false);
    }

    private async Task SendWithoutResponseAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        using var response = await _httpClient.SendAsync(
            request,
            HttpCompletionOption.ResponseHeadersRead,
            cancellationToken).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            throw new VexApiException(
                response.StatusCode,
                response.StatusCode == HttpStatusCode.Unauthorized
                    ? "session_expired"
                    : "api_request_failed");
        }
    }

    private async Task<T> SendAsync<T>(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        using var response = await _httpClient.SendAsync(
            request,
            HttpCompletionOption.ResponseHeadersRead,
            cancellationToken).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            throw new VexApiException(
                response.StatusCode,
                response.StatusCode == HttpStatusCode.Unauthorized
                    ? "session_expired"
                    : "api_request_failed");
        }

        if (response.Content.Headers.ContentLength >
            MaximumResponseBytes)
        {
            throw new VexApiException(
                HttpStatusCode.BadGateway,
                "api_response_invalid");
        }

        await using var source = await response.Content.ReadAsStreamAsync(
            cancellationToken).ConfigureAwait(false);
        using var bounded = new MemoryStream();
        var buffer = new byte[16 * 1024];
        while (true)
        {
            var read = await source.ReadAsync(
                buffer,
                cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                break;
            }

            if (bounded.Length + read > MaximumResponseBytes)
            {
                throw new VexApiException(
                    HttpStatusCode.BadGateway,
                    "api_response_invalid");
            }

            bounded.Write(buffer, 0, read);
        }

        try
        {
            return JsonSerializer.Deserialize<T>(
                bounded.ToArray(),
                JsonOptions) ?? throw new JsonException();
        }
        catch (JsonException)
        {
            throw new VexApiException(
                HttpStatusCode.BadGateway,
                "api_response_invalid");
        }
    }

    private async Task<IReadOnlyList<BillingPlan>> GetBillingPlansAsync(
        CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(
            HttpMethod.Get,
            "/v1/billing/plans");
        try
        {
            return await SendAsync<List<BillingPlan>>(
                request,
                cancellationToken).ConfigureAwait(false);
        }
        catch (VexApiException)
        {
            return [];
        }
    }

    private async Task<DeviceIdentityRegistration?> BuildIdentityRegistrationAsync(
        string accessToken,
        string installationId,
        string wireGuardPublicKey,
        CancellationToken cancellationToken)
    {
        if (_deviceIdentityProvider is null)
        {
            return null;
        }

        var identity = await _deviceIdentityProvider.GetOrCreateAsync(
            cancellationToken).ConfigureAwait(false);
        if (identity is null)
        {
            return null;
        }

        using var request = Authorized(
            HttpMethod.Post,
            "/v1/devices/identity-challenge",
            accessToken);
        request.Content = JsonContent.Create(new
        {
            installation_id = installationId,
            purpose = "register",
        });
        var challenge = await SendAsync<DeviceIdentityChallengeResponse>(
            request,
            cancellationToken).ConfigureAwait(false);
        var payload = DeviceIdentity.SignaturePayload(
            challenge.Id,
            challenge.Nonce,
            string.IsNullOrWhiteSpace(challenge.Purpose)
                ? "register"
                : challenge.Purpose,
            installationId,
            identity.PublicKey,
            wireGuardPublicKey);
        return new DeviceIdentityRegistration(
            identity.PublicKey,
            identity.KeyType,
            challenge.Id,
            await identity.SignAsync(
                payload,
                cancellationToken).ConfigureAwait(false));
    }

    private static HttpRequestMessage Authorized(
        HttpMethod method,
        string path,
        string accessToken)
    {
        if (string.IsNullOrWhiteSpace(accessToken) ||
            accessToken.Length > 16 * 1024)
        {
            throw new ArgumentException(
                "The access token is invalid.",
                nameof(accessToken));
        }

        return new HttpRequestMessage(method, path)
        {
            Headers =
            {
                Authorization = new AuthenticationHeaderValue(
                    "Bearer",
                    accessToken),
            },
        };
    }

    private static void ValidateIdentifier(
        string value,
        string parameterName)
    {
        if (string.IsNullOrWhiteSpace(value) ||
            value.Length > 128 ||
            value.Any(character =>
                !(char.IsAsciiLetterOrDigit(character) ||
                  character is '-' or '_' or '.')))
        {
            throw new ArgumentException(
                "Identifier is invalid.",
                parameterName);
        }
    }

    private static void ValidateWireGuardKey(string value)
    {
        try
        {
            if (Convert.FromBase64String(value).Length != 32)
            {
                throw new FormatException();
            }
        }
        catch (FormatException error)
        {
            throw new ArgumentException(
                "WireGuard public key is invalid.",
                nameof(value),
                error);
        }
    }

    private static string NormalizeEmail(
        string email,
        string parameterName)
    {
        email = email.Trim().ToLowerInvariant();
        if (email.Length is < 3 or > 320 ||
            !email.Contains('@', StringComparison.Ordinal))
        {
            throw new ArgumentException(
                "Email address is invalid.",
                parameterName);
        }

        return email;
    }

    private static void ValidatePkceVerifier(
        string codeVerifier,
        string parameterName)
    {
        codeVerifier = codeVerifier.Trim();
        if (codeVerifier.Length is < 43 or > 128 ||
            codeVerifier.Any(character =>
                !(char.IsAsciiLetterOrDigit(character) ||
                  character is '-' or '.' or '_' or '~')))
        {
            throw new ArgumentException(
                "PKCE verifier is invalid.",
                parameterName);
        }
    }

    private sealed record DeviceIdentityRegistration(
        string IdentityPublicKey,
        string IdentityKeyType,
        string IdentityChallengeId,
        string IdentitySignature);
}
