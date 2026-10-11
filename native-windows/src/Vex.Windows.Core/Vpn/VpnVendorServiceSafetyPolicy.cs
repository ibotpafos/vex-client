namespace Vex.Windows.Core.Vpn;

public static class VpnVendorServiceSafetyPolicy
{
    public static void QualifyForRecoveryOrStop(Action qualifyOwnedRegistration) =>
        qualifyOwnedRegistration();

    public static void QualifyForStartup(Action verifyRuntimeFiles, Action qualifyOwnedRegistration)
    {
        // The installed image must be intact before a new start. An owned
        // process already running must remain stoppable when disk files fail.
        verifyRuntimeFiles();
        qualifyOwnedRegistration();
    }
}
