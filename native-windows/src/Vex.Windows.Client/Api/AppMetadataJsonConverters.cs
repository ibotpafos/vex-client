using System.Text.Json;
using System.Text.Json.Serialization;

namespace Vex.Windows.Client.Api;

internal static class AppMetadataJson
{
    public static T? Read<T>(JsonElement root, string name, JsonSerializerOptions options, string? legacy = null)
    {
        if (root.ValueKind != JsonValueKind.Object) throw new JsonException("App metadata must be an object.");
        if (!root.TryGetProperty(name, out var value) &&
            (legacy is null || !root.TryGetProperty(legacy, out value))) return default;
        return value.ValueKind == JsonValueKind.Null ? default : value.Deserialize<T>(options);
    }
}

public sealed class AppRemoteConfigJsonConverter : JsonConverter<AppRemoteConfig>
{
    public override AppRemoteConfig Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var document = JsonDocument.ParseValue(ref reader);
        var root = document.RootElement;
        return new(
            AppMetadataJson.Read<string>(root, "version", options),
            AppMetadataJson.Read<string>(root, "signature", options),
            AppMetadataJson.Read<string>(root, "releasedAt", options, "released_at"),
            AppMetadataJson.Read<string>(root, "platform", options),
            AppMetadataJson.Read<string>(root, "channel", options),
            AppMetadataJson.Read<int?>(root, "minSupportedBuild", options, "min_supported_build"),
            AppMetadataJson.Read<int?>(root, "recommendedBuild", options, "recommended_build"),
            AppMetadataJson.Read<string>(root, "recommendedVersion", options, "recommended_version"),
            AppMetadataJson.Read<string>(root, "coreVersion", options, "core_version"),
            AppMetadataJson.Read<int?>(root, "configSchemaVersion", options, "config_schema_version"),
            AppMetadataJson.Read<int?>(root, "minConfigSchemaVersion", options, "min_config_schema_version"),
            AppMetadataJson.Read<string>(root, "routingPolicyVersion", options, "routing_policy_version"),
            AppMetadataJson.Read<IReadOnlyDictionary<string, bool>>(root, "featureFlags", options, "feature_flags"),
            AppMetadataJson.Read<string>(root, "incidentBanner", options, "incident_banner"));
    }

    public override void Write(Utf8JsonWriter writer, AppRemoteConfig value, JsonSerializerOptions options) =>
        JsonSerializer.Serialize(writer, new
        {
            version = value.Version, signature = value.Signature, releasedAt = value.ReleasedAt,
            platform = value.Platform, channel = value.Channel, minSupportedBuild = value.MinSupportedBuild,
            recommendedBuild = value.RecommendedBuild, recommendedVersion = value.RecommendedVersion,
            coreVersion = value.CoreVersion, configSchemaVersion = value.ConfigSchemaVersion,
            minConfigSchemaVersion = value.MinConfigSchemaVersion, routingPolicyVersion = value.RoutingPolicyVersion,
            featureFlags = value.FeatureFlags, incidentBanner = value.IncidentBanner,
        }, options);
}

public sealed class AppUpdateCheckResultJsonConverter : JsonConverter<AppUpdateCheckResult>
{
    public override AppUpdateCheckResult Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var document = JsonDocument.ParseValue(ref reader);
        var root = document.RootElement;
        return new(
            AppMetadataJson.Read<bool>(root, "updateAvailable", options, "update_available"),
            AppMetadataJson.Read<bool>(root, "required", options),
            AppMetadataJson.Read<string>(root, "latestVersion", options, "latest_version") ?? string.Empty,
            AppMetadataJson.Read<int>(root, "latestBuild", options, "latest_build"),
            AppMetadataJson.Read<int>(root, "minSupportedBuild", options, "min_supported_build"),
            AppMetadataJson.Read<string>(root, "downloadUrl", options, "download_url") ?? string.Empty,
            AppMetadataJson.Read<bool?>(root, "currentBuildBlocked", options, "current_build_blocked"),
            AppMetadataJson.Read<int?>(root, "minConfigSchemaVersion", options, "min_config_schema_version"),
            AppMetadataJson.Read<string>(root, "changelog", options),
            AppMetadataJson.Read<string>(root, "checksumSha256", options, "checksum_sha256"),
            AppMetadataJson.Read<string>(root, "signatureUrl", options, "signature_url"),
            AppMetadataJson.Read<string>(root, "channel", options),
            AppMetadataJson.Read<string>(root, "reason", options),
            AppMetadataJson.Read<int?>(root, "rolloutPercent", options, "rollout_percent"),
            AppMetadataJson.Read<string>(root, "checkedAt", options, "checked_at"),
            AppMetadataJson.Read<string>(root, "delivery", options));
    }

    public override void Write(Utf8JsonWriter writer, AppUpdateCheckResult value, JsonSerializerOptions options) =>
        JsonSerializer.Serialize(writer, new
        {
            updateAvailable = value.UpdateAvailable, required = value.Required, latestVersion = value.LatestVersion,
            latestBuild = value.LatestBuild, minSupportedBuild = value.MinSupportedBuild, downloadUrl = value.DownloadUrl,
            currentBuildBlocked = value.CurrentBuildBlocked, minConfigSchemaVersion = value.MinConfigSchemaVersion,
            changelog = value.Changelog, checksumSha256 = value.ChecksumSha256, signatureUrl = value.SignatureUrl,
            channel = value.Channel, reason = value.Reason, rolloutPercent = value.RolloutPercent,
            checkedAt = value.CheckedAt, delivery = value.Delivery,
        }, options);
}
