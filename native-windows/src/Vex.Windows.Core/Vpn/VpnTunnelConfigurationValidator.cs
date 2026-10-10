using System.Globalization;

namespace Vex.Windows.Core.Vpn;

public static class VpnTunnelConfigurationValidator
{
    private static readonly HashSet<string> InterfaceKeys =
        new(StringComparer.Ordinal)
        {
            "PrivateKey",
            "Address",
            "DNS",
            "MTU",
            "Jc",
            "Jmin",
            "Jmax",
            "S1",
            "S2",
            "S3",
            "S4",
            "H1",
            "H2",
            "H3",
            "H4",
            "I1",
            "I2",
            "I3",
            "I4",
            "I5",
            "HeaderProtectionKey",
            "ContentPaddingAddition",
            "RekeyAfterTime",
            "RekeyTimeout",
            "RejectAfterTime",
            "KeepaliveTimeout",
            "MaxHandshakeAttempts",
            "RandomTrailers",
            "DisableCookies",
        };

    private static readonly HashSet<string> PeerKeys =
        new(StringComparer.Ordinal)
        {
            "PublicKey",
            "PresharedKey",
            "Endpoint",
            "AllowedIPs",
            "PersistentKeepalive",
        };

    public static void Validate(string configuration)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(configuration);
        if (configuration.Length > 192 * 1024 ||
            configuration.Any(character =>
                character == '\0' ||
                (char.IsControl(character) &&
                 character is not '\r' and not '\n' and not '\t')))
        {
            Reject();
        }

        var state = new ValidationState();
        foreach (var rawLine in configuration.Split('\n'))
        {
            ValidateLine(rawLine.Trim(), state);
        }

        if (!state.HasInterface ||
            !state.HasPeer ||
            !state.HasPrivateKey ||
            !state.HasAddress ||
            !state.HasPublicKey ||
            !state.HasEndpoint ||
            !state.HasAllowedIps)
        {
            Reject();
        }
        ValidateAmnezia(state.Values);
    }

    private static void ValidateLine(string line, ValidationState state)
    {
        if (line.Length == 0 ||
            line.StartsWith('#') ||
            line.StartsWith(';'))
        {
            return;
        }

        if (line.Length > 64 * 1024)
        {
            Reject();
        }

        if (line is "[Interface]" or "[Peer]")
        {
            SetSection(line, state);
            return;
        }

        var separator = line.IndexOf('=');
        if (separator < 1 || state.Section is null)
        {
            Reject();
        }

        var key = line[..separator].Trim();
        var value = line[(separator + 1)..].Trim();
        var allowedKeys = state.Section == "[Interface]"
            ? InterfaceKeys
            : PeerKeys;
        if (value.Length == 0 || !allowedKeys.Contains(key) ||
            key != "AllowedIPs" && line.Length > 4096)
        {
            Reject();
        }

        if (!state.Values.TryAdd(key, value))
        {
            Reject();
        }
        state.Observe(key);
    }

    private static void ValidateAmnezia(IReadOnlyDictionary<string, string> values)
    {
        foreach (var key in new[] { "Jc", "Jmin", "Jmax", "S1", "S2", "S3", "S4" })
        {
            if (values.TryGetValue(key, out var value) &&
                (!TryUnsigned(value, out var number) || number > ushort.MaxValue))
            {
                Reject();
            }
        }
        if (values.TryGetValue("Jmin", out var minimum) &&
            values.TryGetValue("Jmax", out var maximum) &&
            uint.Parse(minimum, CultureInfo.InvariantCulture) >
            uint.Parse(maximum, CultureInfo.InvariantCulture))
        {
            Reject();
        }
        var headers = new (uint Low, uint High)[4];
        for (var index = 0; index < headers.Length; index++)
        {
            headers[index] = ParseRange(values.TryGetValue($"H{index + 1}", out var value)
                ? value : (index + 1).ToString(CultureInfo.InvariantCulture));
        }
        for (var index = 0; index < headers.Length; index++)
        {
            for (var other = index + 1; other < headers.Length; other++)
            {
                if (headers[index].Low <= headers[other].High &&
                    headers[other].Low <= headers[index].High)
                {
                    Reject();
                }
            }
        }
        foreach (var key in new[] { "ContentPaddingAddition", "RekeyAfterTime", "RekeyTimeout", "RejectAfterTime", "KeepaliveTimeout", "MaxHandshakeAttempts" })
        {
            if (values.TryGetValue(key, out var value))
            {
                _ = ParseRange(value);
            }
        }
        foreach (var key in new[] { "RandomTrailers", "DisableCookies" })
        {
            if (values.TryGetValue(key, out var value) && value is not "on" and not "off")
            {
                Reject();
            }
        }
        foreach (var key in new[] { "I1", "I2", "I3", "I4", "I5" })
        {
            if (values.TryGetValue(key, out var value)) { ValidateSignature(value); }
        }
        if (values.TryGetValue("HeaderProtectionKey", out var headerKey))
        {
            byte[] key;
            try { key = Convert.FromBase64String(headerKey); }
            catch (FormatException) { Reject(); return; }
            if (key.Length != 32) { Reject(); }
            if (key.Any(value => value != 0))
            {
                for (var index = 1; index <= 4; index++)
                {
                    if (!values.TryGetValue($"S{index}", out var padding) ||
                        !TryUnsigned(padding, out var number) || number < 12)
                    {
                        Reject();
                    }
                }
            }
        }
    }

    private static (uint Low, uint High) ParseRange(string value)
    {
        var bounds = value.Split('-');
        if (bounds.Length is < 1 or > 2 ||
            !TryUnsigned(bounds[0], out var low) ||
            !TryUnsigned(bounds[^1], out var high) || low > high)
        {
            Reject();
            return default;
        }
        return (low, high);
    }

    private static bool TryUnsigned(string value, out uint number) =>
        uint.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out number);

    private static void ValidateSignature(string value)
    {
        var offset = 0;
        while ((offset = value.IndexOf('<', offset)) >= 0)
        {
            var closing = value.IndexOf('>', offset + 1);
            if (closing < 0) { Reject(); }
            var parts = value[(offset + 1)..closing].Split(
                (char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length is < 1 or > 2) { Reject(); }
            switch (parts[0])
            {
                case "t": case "d": case "ds":
                    if (parts.Length != 1) { Reject(); }
                    break;
                case "r": case "rc": case "rd": case "dz":
                    if (parts.Length != 2 || !TryUnsigned(parts[1], out var length) || length > int.MaxValue) { Reject(); }
                    break;
                case "b":
                    if (parts.Length != 2) { Reject(); }
                    var hex = parts[1].StartsWith("0x", StringComparison.Ordinal) ? parts[1][2..] : parts[1];
                    if (hex.Length == 0 || hex.Length % 2 != 0 || !hex.All(char.IsAsciiHexDigit)) { Reject(); }
                    break;
                default: Reject(); break;
            }
            offset = closing + 1;
        }
    }

    private static void SetSection(string section, ValidationState state)
    {
        if (section == "[Interface]")
        {
            if (state.HasInterface || state.HasPeer)
            {
                Reject();
            }

            state.HasInterface = true;
        }
        else
        {
            if (!state.HasInterface || state.HasPeer)
            {
                Reject();
            }

            state.HasPeer = true;
        }

        state.Section = section;
    }

    private static void Reject() =>
        throw new VpnTunnelException("invalid_tunnel_configuration");

    private sealed class ValidationState
    {
        public string? Section { get; set; }

        public Dictionary<string, string> Values { get; } = new(StringComparer.Ordinal);

        public bool HasInterface { get; set; }

        public bool HasPeer { get; set; }

        public bool HasPrivateKey { get; private set; }

        public bool HasAddress { get; private set; }

        public bool HasPublicKey { get; private set; }

        public bool HasEndpoint { get; private set; }

        public bool HasAllowedIps { get; private set; }

        public void Observe(string key)
        {
            HasPrivateKey |= key == "PrivateKey";
            HasAddress |= key == "Address";
            HasPublicKey |= key == "PublicKey";
            HasEndpoint |= key == "Endpoint";
            HasAllowedIps |= key == "AllowedIPs";
        }
    }
}
