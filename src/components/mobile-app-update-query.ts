import { useQuery } from '@tanstack/react-query';
import { Platform } from 'react-native';
import { useCallback, useMemo } from 'react';
import { shouldOfferAppUpdate, updateCheckChannel } from '@/api/updatePreflight';
import { appUpdateCheck, type AppUpdateCheckResult } from '@/api/vexApi';
import { getAppInfo, getOrCreateDeviceId } from '@/native/appInfo';

const appUpdatePollIntervalMs = 5 * 60_000;

export function useMobileAppUpdateQuery(targetPlatform: 'android' | 'ios', buildNumber: number) {
  const queryKey = useMemo(() => [`${targetPlatform}-update`, buildNumber] as const, [buildNumber, targetPlatform]);
  const queryFn = useCallback(async (): Promise<AppUpdateCheckResult> => {
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
  }, [buildNumber, targetPlatform]);

  return useQuery({
    queryKey,
    queryFn,
    staleTime: 0,
    refetchOnMount: true,
    refetchOnWindowFocus: true,
    refetchOnReconnect: true,
    refetchInterval: appUpdatePollIntervalMs,
    refetchIntervalInBackground: false,
    retry: 2,
    select: (update) => shouldOfferAppUpdate(update, buildNumber)
      ? update
      : { ...update, required: false, updateAvailable: false },
  });
}
