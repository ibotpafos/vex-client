using Microsoft.Windows.AppLifecycle;
using Vex.Windows.Client.Auth;
using Windows.ApplicationModel.Activation;

namespace Vex.Windows.App;

// AppLifecycle payloads belong to the receiving activation context. Only these
// managed immutable values may cross the dispatcher or wait for window startup.
internal sealed class ActivationSnapshot
{
    public string? LaunchArguments { get; }
    public Uri? ProtocolUri { get; }
    public bool CaptureFailed { get; }

    private ActivationSnapshot(string? launchArguments, Uri? protocolUri, bool captureFailed = false)
    {
        LaunchArguments = launchArguments;
        ProtocolUri = protocolUri;
        CaptureFailed = captureFailed;
    }

    public static ActivationSnapshot Capture(AppActivationArguments activation)
    {
        try
        {
            string? launchArguments = null;
            Uri? protocolUri = null;
            // Query only the interface belonging to this activation kind.
            switch (activation.Kind)
            {
                case ExtendedActivationKind.Protocol:
                    protocolUri = activation.Data is IProtocolActivatedEventArgs protocol
                        ? protocol.Uri : throw new InvalidCastException();
                    break;
                case ExtendedActivationKind.Launch:
                    launchArguments = activation.Data is ILaunchActivatedEventArgs launch
                        ? launch.Arguments : throw new InvalidCastException();
                    protocolUri = ProtocolActivationUriParser.Parse(launchArguments);
                    break;
            }
            AuthActivationTrace.Record(AuthActivationStage.ActivationCaptured);
            return new ActivationSnapshot(launchArguments, protocolUri);
        }
        catch (Exception error) when (error is not OutOfMemoryException and not AccessViolationException)
        {
            AuthActivationTrace.Record(AuthActivationStage.ActivationCaptureFailed);
            AuthActivationTrace.RecordFault(error);
            return new ActivationSnapshot(null, null, captureFailed: true);
        }
    }

    // Callback and launch data can contain credentials. Never format the values.
    public override string ToString() => nameof(ActivationSnapshot);
}
