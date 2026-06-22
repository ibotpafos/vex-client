import { useQuery } from '@tanstack/react-query';
import { Platform } from 'react-native';
import { updateCheckChannel } from '@/api/updatePreflight';
import { appUpdateCheck, type AppUpdateCheckResult } from '@/api/vexApi';
import { getAppInfo, getOrCreateDeviceId } from '@/native/appInfo';

const appUpdatePollIntervalMs = 5 * 60_000;

export function useMobileAppUpdateQuery(targetPlatform: 'android' | 'ios', buildNumber: number) {
  return useQuery({
    queryKey: [`${targetPlatform}-update`, buildNumber],
    queryFn: async (): Promise<AppUpdateCheckResult> => {
      const [appInfo, deviceId] = await Promise.all([getAppInfo(), getOrCreateDeviceId()]);
      return appUpdateCheck({
        platform: targetPlatform,
        appVersion: appInfo.version,
        buildNumber,
        channel: updateCheckChannel(appInfo.channel),
        coreVersion: appInfo.coreVersion,
        deviceId,
        osVersion: `${targetPlatform} ${String(Platform.Version ?? '')}`,
        apiClientVersion: appInfo.apiClientVersion,
        configSchemaVersion: appInfo.configSchemaVersion,
      });
    },
    staleTime: 0,
    refetchOnMount: true,
    refetchOnWindowFocus: true,
    refetchOnReconnect: true,
    refetchInterval: appUpdatePollIntervalMs,
    refetchIntervalInBackground: false,
    retry: 2,
  });
}
