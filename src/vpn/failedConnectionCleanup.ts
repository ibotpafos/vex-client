export type FailedConnectionDisconnect = (options: { releaseAntiLeak: boolean }) => Promise<unknown>;

export async function cleanupFailedVpnConnection(
  antiLeakEnabled: boolean,
  disconnect: FailedConnectionDisconnect,
): Promise<void> {
  await disconnect({ releaseAntiLeak: !antiLeakEnabled });
}
