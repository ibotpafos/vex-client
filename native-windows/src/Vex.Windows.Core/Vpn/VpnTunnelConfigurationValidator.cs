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
    }

    private static void ValidateLine(string line, ValidationState state)
    {
        if (line.Length == 0 ||
            line.StartsWith('#') ||
            line.StartsWith(';'))
        {
            return;
        }

        if (line.Length > 4096)
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
        if (value.Length == 0 || !allowedKeys.Contains(key))
        {
            Reject();
        }

        state.Observe(key);
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
