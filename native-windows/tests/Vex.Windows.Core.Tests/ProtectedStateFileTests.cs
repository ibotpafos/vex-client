using System.Security.Cryptography;
using System.Text;
using Vex.Windows.Core.Presentation;

internal static class ProtectedStateFileTests
{
    public static void Run()
    {
        var directory = Path.Combine(Path.GetTempPath(), "vex-protected-state-tests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var path = Path.Combine(directory, "session.bin");
            var decrypted = false;
            var missing = ProtectedStateFileReader.Read<TestState>(path, bytes =>
            {
                decrypted = true;
                return bytes;
            });
            Require(missing.Kind == ProtectedFileReadKind.Missing && !decrypted,
                "A missing cache must not decrypt or replace a device identity.");

            File.WriteAllText(path, "protected bytes");
            var invalidProtection = ProtectedStateFileReader.Read<TestState>(path,
                _ => throw new CryptographicException("Wrong Windows user."));
            Require(invalidProtection.Kind == ProtectedFileReadKind.Unusable &&
                invalidProtection.Error is CryptographicException && File.ReadAllText(path) == "protected bytes",
                "An unusable encrypted cache must preserve its original file.");

            var denied = ProtectedStateFileReader.Read<TestState>(path, bytes => bytes,
                readBytes: _ => throw new UnauthorizedAccessException("Read denied."));
            Require(denied.Kind == ProtectedFileReadKind.Unavailable &&
                denied.Error is UnauthorizedAccessException,
                "An inaccessible cache must remain distinct from a missing cache.");
            var failedRead = ProtectedStateFileReader.Read<TestState>(path, bytes => bytes,
                readBytes: _ => throw new IOException("Read failed."));
            Require(failedRead.Kind == ProtectedFileReadKind.Unavailable,
                "A temporary I/O failure must not permit key replacement.");

            var malformedPlaintext = Encoding.UTF8.GetBytes("invalid json");
            var malformed = ProtectedStateFileReader.Read<TestState>(path, _ => malformedPlaintext);
            Require(malformed.Kind == ProtectedFileReadKind.Unusable && malformedPlaintext.All(value => value == 0),
                "Malformed plaintext must expire safely and be cleared from memory.");

            var incomplete = ProtectedStateFileReader.Read<TestState>(path,
                _ => Encoding.UTF8.GetBytes("{}"), validate: state => !string.IsNullOrWhiteSpace(state.Token));
            Require(incomplete.Kind == ProtectedFileReadKind.Unusable,
                "An incomplete session must not appear authenticated.");

            var plaintext = Encoding.UTF8.GetBytes("{\"Token\":\"valid-session\"}");
            var available = ProtectedStateFileReader.Read<TestState>(path, _ => plaintext);
            Require(available.Kind == ProtectedFileReadKind.Available &&
                available.Value?.Token == "valid-session" && plaintext.All(value => value == 0),
                "A healthy cache must load normally and clear its decrypted bytes.");
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    private static void Require(bool condition, string message)
    {
        if (!condition)
        {
            throw new InvalidOperationException(message);
        }
    }

    private sealed record TestState(string? Token);
}
