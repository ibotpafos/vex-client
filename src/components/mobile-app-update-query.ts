import { useQuery } from '@tanstack/react-query';
import { Platform } from 'react-native';
import { useCallback, useMemo } from 'react';
import { shouldOfferAppUpdate, updateCheckChannel } from '@/api/updatePreflight';
import { appUpdateCheck, type AppUpdateCheckResult } from '@/api/vexApi';
import { createApiQueryRetry } from '@/api/queryRetry';
import { getAppInfo, getOrCreateDeviceId } from '@/native/appInfo';
import { useSession } from '@/auth/session-context';

const appUpdatePollIntervalMs = 5 * 60_000;

export function useMobileAppUpdateQuery(targetPlatform: 'android' | 'ios', buildNumber: number) {
  const { session, sessionRevision, isLoading, isCurrentSessionOperation } = useSession();
  const accessToken = session?.accessToken;
  const queryKey = useMemo(() => [`${targetPlatform}-update`, buildNumber, sessionRevision] as const, [buildNumber, targetPlatform, sessionRevision]);
  const queryFn = useCallback(async (): Promise<AppUpdateCheckResult> => {
    const [appInfo, deviceId] = await Promise.all([getAppInfo(), getOrCreateDeviceId()]);
    if (accessToken && !isCurrentSessionOperation()) throw new Error('Update session changed.');
    const update = await appUpdateCheck({
      accessToken,
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
    if (accessToken && !isCurrentSessionOperation()) throw new Error('Update session changed.');
    return update;
  }, [accessToken, buildNumber, targetPlatform, isCurrentSessionOperation]);

  return useQuery({
    queryKey,
    queryFn,
    enabled: !isLoading && (!accessToken || isCurrentSessionOperation()),
    staleTime: 0,
    refetchOnMount: true,
    refetchOnWindowFocus: true,
    refetchOnReconnect: true,
    refetchInterval: appUpdatePollIntervalMs,
    refetchIntervalInBackground: false,
    retry: createApiQueryRetry(2),
    select: (update) => shouldOfferAppUpdate(update, buildNumber)
      ? update
      : { ...update, required: false, updateAvailable: false },
  });
}
