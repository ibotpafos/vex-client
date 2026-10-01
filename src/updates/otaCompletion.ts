type DownloadedOta = { type: 'new' | 'rollback'; updateId?: string };

export type OtaCompletionTarget =
  | { type: 'new'; updateId: string; runtimeVersion: string }
  | { type: 'rollback'; runtimeVersion: string };

type RunningOta = {
  updateId?: string;
  runtimeVersion?: string;
  isEmbeddedLaunch: boolean;
  isEmergencyLaunch: boolean;
};

export function createOtaCompletionTarget(downloaded: DownloadedOta | null, runtimeVersion: string | null | undefined): OtaCompletionTarget | null {
  if (!downloaded || !runtimeVersion) return null;
  if (downloaded.type === 'rollback') return { type: 'rollback', runtimeVersion };
  return downloaded.updateId ? { type: 'new', updateId: downloaded.updateId, runtimeVersion } : null;
}

export function parseOtaCompletionTarget(value: string | null): OtaCompletionTarget | null {
  if (!value) return null;
  try {
    const parsed: unknown = JSON.parse(value);
    if (!parsed || typeof parsed !== 'object') return null;
    const item = parsed as Record<string, unknown>;
    if (typeof item.runtimeVersion !== 'string' || !item.runtimeVersion) return null;
    if (item.type === 'rollback') return { type: 'rollback', runtimeVersion: item.runtimeVersion };
    if (item.type === 'new' && typeof item.updateId === 'string' && item.updateId) {
      return { type: 'new', updateId: item.updateId, runtimeVersion: item.runtimeVersion };
    }
  } catch {
    // A stale or malformed local marker must never claim that an update ran.
  }
  return null;
}

export function wasOtaCompletionApplied(target: OtaCompletionTarget | null, running: RunningOta): boolean {
  if (!target || running.isEmergencyLaunch || target.runtimeVersion !== running.runtimeVersion) return false;
  if (target.type === 'rollback') return running.isEmbeddedLaunch;
  return !running.isEmbeddedLaunch && target.updateId === running.updateId;
}
