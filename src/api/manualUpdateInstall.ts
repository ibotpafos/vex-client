import type { AndroidUpdateDownload, AndroidUpdateInstallResult } from '@/native/vexVpn';
import { validateManualUpdatePayloadForBaseUrl } from './updatePreflight';
import type { AppUpdateCheckResult } from './types';

const defaultTrustedUpdateBaseUrl = process.env.EXPO_PUBLIC_VEX_API_BASE_URL || 'https://vexguard.app';

export type ManualUpdateInstallPlatform = 'android' | 'ios';

export type ManualUpdateInstallResult =
  | AndroidUpdateInstallResult
  | { status: 'external_update_opened' };

export type ManualUpdateInstallDeps = {
  downloadAndroidUpdateApk?: (downloadUrl: string, checksumSha256?: string | null) => Promise<AndroidUpdateDownload>;
  installAndroidUpdateApk?: (filePath: string) => Promise<AndroidUpdateInstallResult>;
  openUrl?: (url: string) => Promise<unknown>;
};

export async function installManualUpdate(
  update: AppUpdateCheckResult,
  platform: ManualUpdateInstallPlatform,
  deps: ManualUpdateInstallDeps = {},
): Promise<ManualUpdateInstallResult> {
  if (!update.updateAvailable || !update.downloadUrl) {
    throw new Error('Обновление недоступно для установки.');
  }

  if (platform === 'android') {
    const preflight = validateManualUpdatePayloadForBaseUrl({
      checksumSha256: update.checksumSha256,
      downloadUrl: update.downloadUrl,
      signatureUrl: update.signatureUrl,
    }, defaultTrustedUpdateBaseUrl);
    if (!preflight.ok) {
      throw new Error(preflight.error || 'Обновление не прошло проверку целостности.');
    }

    const downloadApk = deps.downloadAndroidUpdateApk ?? await defaultDownloadAndroidUpdateApk();
    const installApk = deps.installAndroidUpdateApk ?? await defaultInstallAndroidUpdateApk();
    const download = await downloadApk(
      update.downloadUrl,
      update.checksumSha256,
    );
    return installApk(download.filePath);
  }

  if (!isTrustedIosUpdateUrl(update.downloadUrl)) {
    throw new Error('Ссылка обновления iOS должна вести в App Store или TestFlight.');
  }
  const openUrl = deps.openUrl ?? await defaultOpenUrl();
  await openUrl(update.downloadUrl);
  return { status: 'external_update_opened' };
}

export function isTrustedIosUpdateUrl(value: string): boolean {
  try {
    const url = new URL(value);
    return url.protocol === 'https:' && (
      url.hostname === 'apps.apple.com'
      || url.hostname === 'testflight.apple.com'
      || url.hostname === 'www.testflight.apple.com'
    );
  } catch {
    return false;
  }
}

async function defaultDownloadAndroidUpdateApk(): Promise<NonNullable<ManualUpdateInstallDeps['downloadAndroidUpdateApk']>> {
  const module = await import('@/native/vexVpn');
  return module.downloadAndroidUpdateApk;
}

async function defaultInstallAndroidUpdateApk(): Promise<NonNullable<ManualUpdateInstallDeps['installAndroidUpdateApk']>> {
  const module = await import('@/native/vexVpn');
  return module.installAndroidUpdateApk;
}

async function defaultOpenUrl(): Promise<NonNullable<ManualUpdateInstallDeps['openUrl']>> {
  const module = await import('react-native');
  return module.Linking.openURL;
}
