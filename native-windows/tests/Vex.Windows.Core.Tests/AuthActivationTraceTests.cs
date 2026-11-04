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
        if (!listener.Stages.SequenceEqual(new[] { 1, 22 }) || listener.UnsafePayload)
            throw new InvalidOperationException("Authentication diagnostics emitted non-stage data, invalid stages or provider errors.");
    }

    private sealed class StageListener : EventListener
    {
        public List<int> Stages { get; } = [];
        public bool UnsafePayload { get; private set; }

        protected override void OnEventSourceCreated(EventSource source)
        {
            if (source.Name == AuthActivationTrace.ProviderName)
                EnableEvents(source, EventLevel.Informational);
        }

        protected override void OnEventWritten(EventWrittenEventArgs value)
        {
            if (value.EventSource.Name != AuthActivationTrace.ProviderName) return;
            if (value.EventId != 1 || value.Payload is not { Count: 1 } || value.Payload[0] is not int stage)
            {
                UnsafePayload = true;
                return;
            }
            Stages.Add(stage);
        }
    }
}
