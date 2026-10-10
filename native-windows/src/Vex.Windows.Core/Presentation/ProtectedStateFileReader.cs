using System.Security.Cryptography;
using System.Text.Json;

namespace Vex.Windows.Core.Presentation;

public enum ProtectedFileReadKind
{
    Missing,
    Available,
    Unusable,
    Unavailable,
}

public sealed record ProtectedFileReadResult<T>(
    ProtectedFileReadKind Kind,
    T? Value = default,
    Exception? Error = null);

public static class ProtectedStateFileReader
{
    public static ProtectedFileReadResult<T> Read<T>(
        string path,
        Func<byte[], byte[]> unprotect,
        JsonSerializerOptions? options = null,
        Func<T, bool>? validate = null,
        Func<string, byte[]>? readBytes = null)
    {
        byte[]? clearValue = null;
        try
        {
            var protectedValue = (readBytes ?? File.ReadAllBytes)(path);
            clearValue = unprotect(protectedValue);
            var value = JsonSerializer.Deserialize<T>(clearValue, options);
            if (value is null || (validate is not null && !validate(value)))
            {
                throw new JsonException("The protected client cache is incomplete.");
            }
            return new ProtectedFileReadResult<T>(ProtectedFileReadKind.Available, value);
        }
        catch (Exception error) when (error is FileNotFoundException or DirectoryNotFoundException)
        {
            return new ProtectedFileReadResult<T>(ProtectedFileReadKind.Missing);
        }
        catch (Exception error) when (error is CryptographicException or JsonException)
        {
            return new ProtectedFileReadResult<T>(ProtectedFileReadKind.Unusable, Error: error);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return new ProtectedFileReadResult<T>(ProtectedFileReadKind.Unavailable, Error: error);
        }
        finally
        {
            if (clearValue is not null)
            {
                CryptographicOperations.ZeroMemory(clearValue);
            }
        }
    }
}
