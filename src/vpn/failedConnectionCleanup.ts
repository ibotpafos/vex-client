import { isVpnAdmissionError } from './connectionFallback';

export type FailedConnectionDisconnect = (options: { releaseAntiLeak: boolean }) => Promise<unknown>;

export async function cleanupFailedVpnConnection(
  antiLeakEnabled: boolean,
  disconnect: FailedConnectionDisconnect,
  error?: unknown,
): Promise<void> {
  if (isVpnAdmissionError(error)) return;
  await disconnect({ releaseAntiLeak: !antiLeakEnabled });
}
