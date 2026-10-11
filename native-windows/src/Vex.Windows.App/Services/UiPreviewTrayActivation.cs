#if DEBUG
using System.Text.Json;

namespace Vex.Windows.App.Services;

// Only fixed stages and exception type names leave the isolated Debug preview.
// Recording must not replace an activation error or prevent its original work.
internal sealed class UiPreviewTrayActivation(UiPreviewTrayRequest request)
{
    private string _stage = "redirected-request-accepted";
    internal UiPreviewTrayRequest Request => request;

    internal void Record(string stage)
    {
        if (!IsStage(stage)) throw new ArgumentOutOfRangeException(nameof(stage));
        _stage = stage;
        TryRecord(null);
    }

    internal void RecordFailure(Exception error)
    {
        var type = error.GetType().Name;
        if (type.Length is < 1 or > 80 || !type.EndsWith("Exception", StringComparison.Ordinal) ||
            type.Any(value => !char.IsAsciiLetterOrDigit(value) && value != '_'))
            type = nameof(Exception);
        TryRecord(type);
    }

    private void TryRecord(string? failureType)
    {
        if (!UiPreviewContext.IsEnabled || UiPreviewContext.StateDirectory is null ||
            request.Id == Guid.Empty) return;
        var path = request.ProgressPath;
        try
        {
            foreach (var candidate in new[] { path, path + ".tmp" })
                if (File.Exists(candidate) && (File.GetAttributes(candidate) & FileAttributes.ReparsePoint) != 0)
                    return;
            var value = JsonSerializer.Serialize(new
            {
                schema = "vex.windows.ui-preview-tray-activation.v1",
                process_id = Environment.ProcessId,
                preview_mode = UiPreviewContext.IsProtectedStateFaultPreview ? "protected-state-fault" :
                    UiPreviewContext.IsAuthenticated ? "fixtures" : "signed-out",
                scenario = request.Scenario,
                stage = _stage,
                failure_type = failureType,
            });
            File.WriteAllText(path + ".tmp", value);
            File.Move(path + ".tmp", path, overwrite: true);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // A diagnostic path failure cannot change the activation outcome.
        }
    }

    private static bool IsStage(string stage) => stage is
        "redirected-request-accepted" or "handler-started" or
        "reset-session-restoring" or "reset-session-restored" or "reset-ui-requested" or
        "reset-ui-entered" or "reset-ui-state-read" or "reset-ui-navigated" or
        "reset-ui-shown" or "reset-ui-completed" or "completion-recording" or
        "completion-temp-write" or "completion-move";
}
#endif
