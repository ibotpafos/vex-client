import * as SecureStore from '@/native/secureStore';
import { getAppInfo, getOrCreateInstallId } from '@/native/appInfo';
import { jsonRequest } from './client';

type AppInstallResponse = {
  event_id: string;
};

const installReportedKey = 'vex.app.install_reported.v1';

export async function reportAppInstall(accessToken: string, userId: string): Promise<void> {
  if (!accessToken || !userId) {
    return;
  }
  const [appInfo, installId] = await Promise.all([getAppInfo(), getOrCreateInstallId()]);
  const reportKey = `${userId}:${installId}:${appInfo.platform}:${appInfo.version}:${appInfo.build || '0'}`;
  if (await isInstallReportSent(reportKey)) {
    return;
  }
  await jsonRequest<AppInstallResponse>('/v1/app/install', {
    accessToken,
    body: {
      installId,
      platform: appInfo.platform,
      appVersion: appInfo.version,
      buildNumber: Number(appInfo.build || 0) || 0,
      channel: appInfo.channel,
      source: appInstallSource(appInfo.platform),
      metadata: {
        app_name: appInfo.name,
        core_version: appInfo.coreVersion,
        config_schema_version: String(appInfo.configSchemaVersion),
      },
    },
    method: 'POST',
    suppressErrorLog: true,
  });
  await markInstallReportSent(reportKey);
}

async function isInstallReportSent(reportKey: string): Promise<boolean> {
  const reported = await readReportedInstallKeys();
  return reported.includes(reportKey);
}

async function markInstallReportSent(reportKey: string): Promise<void> {
  const reported = await readReportedInstallKeys();
  if (reported.includes(reportKey)) {
    return;
  }
  const next = [...reported.slice(-40), reportKey];
  await SecureStore.setItemAsync(installReportedKey, JSON.stringify(next)).catch(() => undefined);
}

async function readReportedInstallKeys(): Promise<string[]> {
  const raw = await SecureStore.getItemAsync(installReportedKey).catch(() => null);
  if (!raw) {
    return [];
  }
  try {
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed.filter((item): item is string => typeof item === 'string') : [];
  } catch {
    await SecureStore.deleteItemAsync(installReportedKey).catch(() => undefined);
    return [];
  }
}

function appInstallSource(platform: string): string {
  switch (platform) {
    case 'android':
      return 'android_app';
    case 'ios':
      return 'ios_app';
    case 'macos':
      return 'macos_app';
    case 'windows':
      return 'windows_app';
    case 'linux':
      return 'linux_app';
    default:
      return 'web_app';
  }
}
