using System.Diagnostics.Tracing;

namespace Vex.Windows.Client.Auth;

// Fixed stage numbers only. Never add URIs, codes, state, account identifiers,
// tokens, exception messages or saved session data to this provider.
public enum AuthActivationStage
{
    ProcessStarted = 1,
    PrimarySelected,
    RedirectStarted,
    RedirectCompleted,
    RedirectFailed,
    RedirectReceived,
    DispatcherAccepted,
    DispatcherRejected,
    StartupQueued,
    HandlerStarted,
    HandlerNoProtocol,
    CallbackEntered,
    AuthGateEntered,
    CallbackIgnoredAfterCancellation,
    ChallengeLoaded,
    CallbackRejected,
    StateMatched,
    ExchangeStarted,
    ExchangeCompleted,
    SessionSaveStarted,
    SessionSaveCompleted,
    AuthSucceeded,
    AuthFailed,
    HandlerCompleted,
    HandlerFaulted,
    BrowserRequestStarted,
    UiRefreshRequested,
}

public static class AuthActivationTrace
{
    public const string ProviderGuid = "5474fab7-6d97-488e-b40f-84ba10c8c1d9";
    public const string ProviderName = "VEX-Windows-AuthActivation";

    public static void Record(AuthActivationStage stage)
    {
        if (stage is < AuthActivationStage.ProcessStarted or > AuthActivationStage.UiRefreshRequested) return;
        try
        {
            if (AuthActivationEventSource.Log.IsEnabled()) AuthActivationEventSource.Log.Stage((int)stage);
        }
        catch (EventSourceException) { /* Diagnostics cannot interrupt login. */ }
    }
}

[EventSource(Name = AuthActivationTrace.ProviderName, Guid = AuthActivationTrace.ProviderGuid)]
internal sealed class AuthActivationEventSource : EventSource
{
    public static readonly AuthActivationEventSource Log = new();

    private AuthActivationEventSource() : base(EventSourceSettings.EtwSelfDescribingEventFormat) { }

    [Event(1, Level = EventLevel.Informational)]
    public void Stage(int stage) => WriteEvent(1, stage);
}
