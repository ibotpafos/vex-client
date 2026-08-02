namespace Vex.Windows.Core.Vpn;

public static class VpnErrorCode
{
    public const string RuntimeFailure = "tunnel_runtime_failure";

    public static string Sanitize(string? value)
    {
        if (value is null || value.Length is < 1 or > 64)
        {
            return RuntimeFailure;
        }

        return value.All(character =>
            character is >= 'a' and <= 'z'
            or >= '0' and <= '9'
            or '_')
            ? value
            : RuntimeFailure;
    }
}
