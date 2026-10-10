namespace Vex.Windows.Client.Auth;

public interface IPkceStateStore
{
    PendingPkceChallenge? Load();
    void Save(PendingPkceChallenge pendingChallenge);
    void Clear();
}
