using System.Buffers.Binary;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Vex.Windows.Core.Vpn.Ipc;

public static class VpnIpcFrameCodec
{
    public const int MaxFrameBytes = 256 * 1024;

    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = false,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    };

    public static Task WriteRequestAsync(
        Stream stream,
        VpnIpcRequestEnvelope envelope,
        CancellationToken cancellationToken) =>
        WriteAsync(stream, envelope, cancellationToken);

    public static Task<VpnIpcRequestEnvelope> ReadRequestAsync(
        Stream stream,
        CancellationToken cancellationToken) =>
        ReadAsync<VpnIpcRequestEnvelope>(stream, cancellationToken);

    public static Task WriteResponseAsync(
        Stream stream,
        VpnServiceResponse response,
        CancellationToken cancellationToken) =>
        WriteAsync(stream, response, cancellationToken);

    public static Task<VpnServiceResponse> ReadResponseAsync(
        Stream stream,
        CancellationToken cancellationToken) =>
        ReadAsync<VpnServiceResponse>(stream, cancellationToken);

    private static async Task WriteAsync<T>(
        Stream stream,
        T value,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(stream);
        ArgumentNullException.ThrowIfNull(value);

        var payload = JsonSerializer.SerializeToUtf8Bytes(
            value,
            SerializerOptions);
        if (payload.Length is < 1 or > MaxFrameBytes)
        {
            throw new VpnIpcProtocolException("frame_size_invalid");
        }

        var header = new byte[sizeof(int)];
        BinaryPrimitives.WriteInt32LittleEndian(header, payload.Length);
        await stream.WriteAsync(header, cancellationToken).ConfigureAwait(false);
        await stream.WriteAsync(payload, cancellationToken).ConfigureAwait(false);
        await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    private static async Task<T> ReadAsync<T>(
        Stream stream,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(stream);

        try
        {
            var header = new byte[sizeof(int)];
            await stream.ReadExactlyAsync(header, cancellationToken)
                .ConfigureAwait(false);
            var length = BinaryPrimitives.ReadInt32LittleEndian(header);
            if (length is < 1 or > MaxFrameBytes)
            {
                throw new VpnIpcProtocolException("frame_size_invalid");
            }

            var payload = new byte[length];
            await stream.ReadExactlyAsync(payload, cancellationToken)
                .ConfigureAwait(false);
            return JsonSerializer.Deserialize<T>(payload, SerializerOptions)
                ?? throw new VpnIpcProtocolException("frame_payload_invalid");
        }
        catch (VpnIpcProtocolException)
        {
            throw;
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception error) when (
            error is EndOfStreamException
                or JsonException
                or ArgumentException)
        {
            throw new VpnIpcProtocolException(
                "frame_payload_invalid",
                error);
        }
    }
}

public sealed class VpnIpcProtocolException : Exception
{
    public VpnIpcProtocolException(string code, Exception? innerException = null)
        : base("The VPN IPC frame was rejected.", innerException)
    {
        Code = code;
    }

    public string Code { get; }
}
