using Vex.Windows.Client.Updates;
using Vex.Windows.Core.Updates;

namespace Vex.Windows.App.Services;

public sealed partial class NativeUpdateService
{
    internal static (
        WindowsUpdateCoordinator? Coordinator,
        NativeUpdateSnapshot InitialSnapshot) InitializeWithDurableRollback(
            Func<WindowsUpdateRollbackState?> loadRollbackState,
            Func<WindowsUpdateRollbackState?, (
                WindowsUpdateCoordinator? Coordinator,
                NativeUpdateSnapshot InitialSnapshot)> configure,
            string currentVersion,
            string channel,
            string architecture)
    {
        ArgumentNullException.ThrowIfNull(loadRollbackState);
        ArgumentNullException.ThrowIfNull(configure);

        WindowsUpdateRollbackState? rollbackState;
        try
        {
            rollbackState = loadRollbackState();
        }
        catch (Exception error) when (NativeUpdateFailurePolicy.IsExpectedFailure(error))
        {
            // An unreadable existing record may contain a mandatory target.
            // Keep account/settings recovery available without treating loss of
            // that evidence as permission to connect or stage an arbitrary build.
            return (null, NativeUpdateSnapshot.Disabled(currentVersion, channel, architecture,
                "Локальная запись обновлений повреждена или недоступна. Для подключения восстановите VEX через центр загрузок.") with
            {
                State = "required_update_recovery",
                UpdateAvailable = true,
                Required = true,
                Release = null,
            });
        }

        try
        {
            var configuration = configure(rollbackState);
            return (configuration.Coordinator,
                configuration.InitialSnapshot.WithRollbackState(rollbackState));
        }
        catch (Exception error) when (NativeUpdateFailurePolicy.IsExpectedFailure(error))
        {
            // A separate trust/configuration failure must still preserve any
            // mandatory floor or target successfully read from durable storage.
            return (null, NativeUpdateSnapshot.Disabled(currentVersion, channel, architecture,
                "Проверка обновлений недоступна: " + error.Message).WithRollbackState(rollbackState));
        }
    }
}
