import type { AppUpdateCheckResult } from '../api/types';
import { requiresNativeUpdate } from '../api/updatePreflight';

export type AndroidDownloadState =
  | { status: 'idle' }
  | { status: 'ready'; build: number }
  | { status: 'installing'; build: number }
  | { status: 'permission_required'; build: number }
  | { status: 'installer_opened'; build: number }
  | { status: 'error'; build: number; message: string };

export function shouldShowUpdateSheet(
  update: AppUpdateCheckResult | null,
  downloadState: AndroidDownloadState,
  dismissedBuild: number | null,
  installerOpenedBuild: number | null,
  preflight: { ok: boolean; error?: string },
): boolean {
  if (!update?.updateAvailable) {
    return false;
  }
  if (!requiresNativeUpdate(update)) {
    return false;
  }
  if (installerOpenedBuild === update.latestBuild) {
    return false;
  }
  if (!update.required && dismissedBuild === update.latestBuild) {
    return false;
  }
  if (!preflight.ok) {
    return update.required;
  }
  if (update.required) {
    return true;
  }
  // Keep the user's install attempt visible through download, permission and
  // failure; only an explicit dismissal or installer handoff should hide it.
  return downloadState.status === 'ready'
    || downloadState.status === 'installing'
    || downloadState.status === 'permission_required'
    || downloadState.status === 'error';
}
