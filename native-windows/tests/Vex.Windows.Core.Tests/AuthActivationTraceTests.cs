using System.Diagnostics.Tracing;
using Vex.Windows.Client.Auth;

internal static class AuthActivationTraceTests
{
    public static void Run()
    {
        using var listener = new StageListener();
        AuthActivationTrace.Record(AuthActivationStage.ProcessStarted);
        AuthActivationTrace.Record(AuthActivationStage.AuthSucceeded);
        AuthActivationTrace.Record((AuthActivationStage)0);
        AuthActivationTrace.Record((AuthActivationStage)999);
        if (!listener.Stages.SequenceEqual(new[] { 1, 22 }) || listener.StartupStages.Count != 0 || listener.UnsafePayload)
            throw new InvalidOperationException("Authentication diagnostics emitted non-stage data, invalid stages or provider errors.");
        foreach (var stage in Enum.GetValues<AppStartupStage>()) AuthActivationTrace.RecordStartup(stage);
        AuthActivationTrace.RecordStartup((AppStartupStage)0);
        AuthActivationTrace.RecordStartup((AppStartupStage)999);
        if (!listener.Stages.SequenceEqual(new[] { 1, 22 }) ||
            !listener.StartupStages.SequenceEqual(Enumerable.Range(1, 13)) || listener.UnsafePayload)
            throw new InvalidOperationException("Startup diagnostics changed legacy auth events or emitted unsafe/invalid stage data.");
    }

    private sealed class StageListener : EventListener
    {
        public List<int> Stages { get; } = [];
        public List<int> StartupStages { get; } = [];
        public bool UnsafePayload { get; private set; }

        protected override void OnEventSourceCreated(EventSource source)
        {
            if (source.Name == AuthActivationTrace.ProviderName)
                EnableEvents(source, EventLevel.Informational);
        }

        protected override void OnEventWritten(EventWrittenEventArgs value)
        {
            if (value.EventSource.Name != AuthActivationTrace.ProviderName) return;
            if (value.EventId is not (1 or 2) || value.Payload is not { Count: 1 } || value.Payload[0] is not int stage ||
                value.PayloadNames is not { Count: 1 } || value.PayloadNames[0] != "stage" ||
                value.EventName != (value.EventId == 1 ? "Stage" : "StartupStage"))
            {
                UnsafePayload = true;
                return;
            }
            if (value.EventId == 1) Stages.Add(stage);
            else StartupStages.Add(stage);
        }
    }
}
