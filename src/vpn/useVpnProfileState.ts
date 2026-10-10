import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { Platform } from 'react-native';
import { errorMessage } from '@/utils/error';

import { entitlement, hasPaidEntitlement, type Entitlement } from '../api/vexApi';
import { resetVpnProfileCache, resolveVpnProfile, rotateVpnProfileKey, type VpnProfile } from './profile';
import { ProfileRequestSupersededError } from './profileRequestQueue';
import type { ResolveConnectableProfileOptions } from './serverSwitch';
import { clearHotVpnProfiles, hydrateHotVpnProfilesToQueryCache, loadHotVpnProfileResult, profileFromHotRecord, saveHotVpnProfile } from './hotProfileCache';
import { connectableLocalProfile } from './connectFlow';
import type { VpnRoutingMode } from './routingPolicy';
import { androidVpnProfileRequiresRefresh, androidVpnProfileWithinBinderBudget } from './androidRoutingSafety';
import { SessionOperationSupersededError } from './sessionOperation';

const assumeCurrentSessionOperation = () => true;

export type VpnProfileRefreshEvent = {
  device_id?: string;
  reason?: 'profile_updated' | 'device_revoked' | 'rotate_key_required' | string;
};

type UseVpnProfileStateInput = {
  accessToken?: string;
  isCurrentSessionOperation: () => boolean;
  canRefreshInBackground?: (locationId: string) => boolean;
  hasVpnAccess: boolean;
  knownEntitlement: Entitlement | null;
  onDeviceRevoked: () => Promise<void>;
  onProfileRefreshFailed?: (event: { error: unknown; locationId: string; reason: string }) => void;
  onProfileRotationRequired: () => void;
  onSubscriptionRequired: () => void;
  profileRefreshMs: number;
  realtimeConnected?: boolean;
  realtimeRevision?: number;
  requestVpnPermission: () => Promise<boolean>;
  routingMode: VpnRoutingMode;
  selectedLocationId: string;
  userId?: string;
};

type UseVpnProfileStateResult = {
  activeProfile: VpnProfile | null;
  activeProfileConfig?: string;
  activeProfileDeviceId?: string;
  cacheProfile: (locationId: string, profile: VpnProfile) => void;
  clearProfile: () => void;
  entitlementState: Entitlement | null;
  isKeyRotationBusy: boolean;
  refreshManagedProfile: (event?: VpnProfileRefreshEvent) => Promise<void>;
  resolveConnectableVpnProfile: (locationId: string, options?: ResolveConnectableProfileOptions) => Promise<VpnProfile>;
  rotateActiveProfile: (profile: VpnProfile, locationId: string) => Promise<VpnProfile>;
  setActiveProfile: (profile: VpnProfile | null) => void;
};

export function useVpnProfileState(input: UseVpnProfileStateInput): UseVpnProfileStateResult {
  const {
    accessToken,
    isCurrentSessionOperation = assumeCurrentSessionOperation,
    canRefreshInBackground,
    hasVpnAccess,
    knownEntitlement,
    onDeviceRevoked,
    onProfileRefreshFailed,
    onProfileRotationRequired,
    onSubscriptionRequired,
    profileRefreshMs,
    realtimeConnected = false,
    realtimeRevision = 0,
    requestVpnPermission,
    routingMode,
    selectedLocationId,
    userId,
  } = input;
  const queryClient = useQueryClient();
  const requireCurrentSession = useCallback(() => {
    if (!isCurrentSessionOperation()) throw new SessionOperationSupersededError();
  }, [isCurrentSessionOperation]);
  const currentRequestScope = useRef({ accessToken, selectedLocationId, canRefreshInBackground, isCurrentSessionOperation });
  currentRequestScope.current = { accessToken, selectedLocationId, canRefreshInBackground, isCurrentSessionOperation };
  const backgroundRequestIsCurrent = useCallback((token: string | undefined, location: string) => {
    const current = currentRequestScope.current;
    return current.isCurrentSessionOperation?.() !== false && current.accessToken === token && current.selectedLocationId === location && current.canRefreshInBackground?.(location) !== false;
  }, []);
  const [vpnProfile, setVpnProfileState] = useState<VpnProfile | null>(null);
  const vpnProfileOwnerRef = useRef<{ userId?: string; isCurrentSessionOperation: () => boolean } | null>(null);
  const setVpnProfile = useCallback((value: React.SetStateAction<VpnProfile | null>) => {
    if (!isCurrentSessionOperation()) return;
    const previousOwner = vpnProfileOwnerRef.current;
    const previousProfileIsOwned = previousOwner?.userId === userId && previousOwner?.isCurrentSessionOperation();
    vpnProfileOwnerRef.current = { userId, isCurrentSessionOperation };
    setVpnProfileState((current) => typeof value === 'function' ? value(previousProfileIsOwned ? current : null) : value);
  }, [isCurrentSessionOperation, userId]);
  const [isKeyRotationBusy, setIsKeyRotationBusy] = useState(false);
  const profileQueryKey = useMemo(() => ['vpn-profile', accessToken, selectedLocationId, routingMode] as const, [accessToken, routingMode, selectedLocationId]);
  const fetchSelectedProfile = useCallback(() => resolveVpnProfile(accessToken!, knownEntitlement, selectedLocationId, {
    forceRefresh: true,
    revalidateProfile: queryClient.getQueryData<VpnProfile>(profileQueryKey),
    shouldFetch: () => backgroundRequestIsCurrent(accessToken, selectedLocationId),
    isCurrentSessionOperation,
    routingMode,
    userId,
  }), [accessToken, backgroundRequestIsCurrent, isCurrentSessionOperation, knownEntitlement, profileQueryKey, queryClient, routingMode, selectedLocationId, userId]);
  const activeProfile = vpnProfileOwnerRef.current?.userId === userId
    && vpnProfileOwnerRef.current?.isCurrentSessionOperation() && isCurrentSessionOperation() ? vpnProfile : null;
  const entitlementState = knownEntitlement ?? activeProfile?.entitlement ?? null;

  useEffect(() => {
    vpnProfileOwnerRef.current = null;
    setVpnProfileState(null);
    setIsKeyRotationBusy(false);
  }, [isCurrentSessionOperation, userId]);

  const cacheProfile = useCallback((locationId: string, profile: VpnProfile) => {
    if (!accessToken || !isCurrentSessionOperation()) {
      return;
    }
    queryClient.setQueryData(['vpn-profile', accessToken, locationId, profile.routingMode ?? routingMode], profile);
    if (profile.entitlement) {
      queryClient.setQueryData(['entitlement', accessToken], profile.entitlement);
    }
    if (userId) {
      void saveHotVpnProfile(userId, locationId, profile).catch(() => undefined);
    }
  }, [accessToken, isCurrentSessionOperation, queryClient, routingMode, userId]);

  const cachedProfileForLocation = useCallback((locationId: string): VpnProfile | null => {
    if (!accessToken || !isCurrentSessionOperation()) {
      return null;
    }
    const cached = queryClient.getQueryData<VpnProfile>(['vpn-profile', accessToken, locationId, routingMode]);
    if (cached) {
      return cached;
    }
    if (activeProfile?.locationId === locationId && activeProfile.routingMode === routingMode) {
      return activeProfile;
    }
    return null;
  }, [accessToken, activeProfile, isCurrentSessionOperation, queryClient, routingMode]);

  useEffect(() => {
    if (!accessToken || !userId) {
      return;
    }
    let cancelled = false;
    void hydrateHotVpnProfilesToQueryCache(userId, accessToken, queryClient)
      .then((records) => {
        const selected = records.find((record) =>
          record.locationId === selectedLocationId && record.profile.routingMode === routingMode
        );
        if (!cancelled && isCurrentSessionOperation() && selected && backgroundRequestIsCurrent(accessToken, selectedLocationId)) {
          setVpnProfile(selected.profile);
        }
      })
      .catch(() => undefined);
    return () => { cancelled = true; };
  }, [accessToken, backgroundRequestIsCurrent, isCurrentSessionOperation, queryClient, routingMode, selectedLocationId, setVpnProfile, userId]);

  const refreshProfileInBackground = useCallback((
    locationId: string,
    currentEntitlement: Entitlement,
    baseProfile: VpnProfile,
  ) => {
    if (!accessToken || !isCurrentSessionOperation()) {
      return;
    }
    void resolveVpnProfile(accessToken, currentEntitlement, locationId, {
      forceRefresh: true,
      revalidateProfile: baseProfile,
      shouldFetch: () => backgroundRequestIsCurrent(accessToken, locationId),
      isCurrentSessionOperation,
      routingMode,
      userId,
    })
      .then((freshProfile) => {
        if (!isCurrentSessionOperation() || !backgroundRequestIsCurrent(accessToken, locationId)) return;
        cacheProfile(locationId, freshProfile);
        if (baseProfile.device?.id && freshProfile.device?.id !== baseProfile.device.id) {
          return;
        }
        setVpnProfile((current) => current?.locationId === locationId ? freshProfile : current);
      })
      .catch((error) => {
        if (error instanceof ProfileRequestSupersededError || error instanceof SessionOperationSupersededError || !isCurrentSessionOperation()) return;
        if (userId && errorMessage(error).includes('Подписка не активна')) {
          void clearHotVpnProfiles(userId).catch(() => undefined);
          onProfileRefreshFailed?.({
            error,
            locationId,
            reason: baseProfile.hotProfileUsed ? 'hot_profile_revoked' : 'background_profile_revoked',
          });
          return;
        }
        onProfileRefreshFailed?.({
          error,
          locationId,
          reason: baseProfile.hotProfileUsed ? 'hot_profile_refresh_failed' : 'background_profile_refresh_failed',
        });
      });
  }, [accessToken, backgroundRequestIsCurrent, cacheProfile, isCurrentSessionOperation, onProfileRefreshFailed, routingMode, setVpnProfile, userId]);

  const clearProfile = useCallback(() => {
    if (!isCurrentSessionOperation()) return;
    resetVpnProfileCache();
    if (userId) {
      void clearHotVpnProfiles(userId).catch(() => undefined);
    }
    setVpnProfile(null);
  }, [isCurrentSessionOperation, setVpnProfile, userId]);

  useEffect(() => {
    if (!accessToken || !hasVpnAccess || !selectedLocationId) {
      setVpnProfile(null);
      return undefined;
    }

    let cancelled = false;
    const refreshProfile = async () => {
      const profile = await queryClient.fetchQuery({
        queryKey: profileQueryKey,
        queryFn: fetchSelectedProfile,
        staleTime: profileRefreshMs,
      }).catch((error) => {
        if (cancelled || error instanceof ProfileRequestSupersededError || error instanceof SessionOperationSupersededError || !isCurrentSessionOperation()) return null;
        onProfileRefreshFailed?.({
          error,
          locationId: selectedLocationId,
          reason: 'profile_query_failed',
        });
        return null;
      });
      if (!cancelled && profile && backgroundRequestIsCurrent(accessToken, selectedLocationId) && isCurrentSessionOperation()) {
        setVpnProfile(profile);
        cacheProfile(selectedLocationId, profile);
      }
    };

    void refreshProfile();
    const timer = realtimeConnected ? undefined : setInterval(() => {
      void refreshProfile();
    }, profileRefreshMs);
    return () => {
      cancelled = true;
      if (timer) clearInterval(timer);
    };
  }, [
    accessToken,
    backgroundRequestIsCurrent,
    cacheProfile,
    fetchSelectedProfile,
    hasVpnAccess,
    isCurrentSessionOperation,
    onProfileRefreshFailed,
    profileQueryKey,
    profileRefreshMs,
    queryClient,
    realtimeConnected,
    realtimeRevision,
    selectedLocationId,
    setVpnProfile,
  ]);

  const rotateActiveProfile = useCallback(async (profile: VpnProfile, locationId: string) => {
    requireCurrentSession();
    if (!accessToken) {
      throw new Error('Сначала войдите в аккаунт.');
    }
    setIsKeyRotationBusy(true);
    try {
      const nextProfile = await rotateVpnProfileKey(accessToken, profile, isCurrentSessionOperation);
      requireCurrentSession();
      setVpnProfile(nextProfile);
      cacheProfile(locationId, nextProfile);
      return nextProfile;
    } finally {
      if (isCurrentSessionOperation()) setIsKeyRotationBusy(false);
    }
  }, [accessToken, cacheProfile, isCurrentSessionOperation, requireCurrentSession, setVpnProfile]);

  const resolveConnectableVpnProfile = useCallback(async (
    locationId: string,
    options: ResolveConnectableProfileOptions = {},
  ) => {
    requireCurrentSession();
    if (!accessToken) {
      throw new Error('Сначала войдите в аккаунт.');
    }

    const preparationStartedAtMs = Date.now();
    let entitlementWaitMs = 0;
    let hotProfileLookupMs = 0;
    let keyRotationMs = 0;
    let permissionWaitMs = 0;
    const withConnectPreparationTiming = (profile: VpnProfile): VpnProfile => ({
      ...profile,
      connectPreparationTiming: {
        startedAtMs: preparationStartedAtMs,
        completedAtMs: Date.now(),
        entitlementWaitMs,
        hotProfileLookupMs,
        keyRotationMs,
        permissionWaitMs,
      },
    });
    const requestPermissionWithTiming = async () => {
      const startedAtMs = Date.now();
      try {
        requireCurrentSession();
        const granted = await requestVpnPermission();
        requireCurrentSession();
        return granted;
      } finally {
        permissionWaitMs += Math.max(0, Date.now() - startedAtMs);
      }
    };

    const preferCached = options.preferCached !== false && options.forceRefresh !== true;
    const cachedProfile = options.cachedProfile ?? cachedProfileForLocation(locationId);
    let forceRouteBudgetRefresh = androidVpnProfileRequiresRefresh(Platform.OS, cachedProfile?.config);
    const cachedLocalProfile = preferCached
      ? connectableLocalProfile(cachedProfile, locationId, entitlementState, routingMode)
      : null;
    if (
      cachedLocalProfile &&
      androidVpnProfileWithinBinderBudget(Platform.OS, cachedLocalProfile.config)
    ) {
      const cachedEntitlement = cachedLocalProfile.entitlement ?? entitlementState;
      if (options.requestPermission !== false) {
        const permissionGranted = await requestPermissionWithTiming();
        if (!permissionGranted) {
          throw new Error('Разрешение Android VPN не выдано.');
        }
      }
      const localProfile = withConnectPreparationTiming(cachedLocalProfile);
      cacheProfile(locationId, localProfile);
      refreshProfileInBackground(locationId, cachedEntitlement!, cachedLocalProfile);
      return localProfile;
    }

    if (preferCached && userId) {
      const hotLookupStartedAtMs = Date.now();
      const hotResult = options.allowPersistentHotProfile === false
        ? { record: null }
        : await loadHotVpnProfileResult(userId, locationId, routingMode);
      requireCurrentSession();
      hotProfileLookupMs += Math.max(0, Date.now() - hotLookupStartedAtMs);
      if (hotResult.rejectedReason && hotResult.rejectedReason !== 'missing') {
        onProfileRefreshFailed?.({
          error: new Error(hotResult.rejectedReason),
          locationId,
          reason: 'hot_profile_rejected',
        });
      }
      const hotProfile = hotResult.record ? profileFromHotRecord(hotResult.record) : null;
      forceRouteBudgetRefresh = forceRouteBudgetRefresh || androidVpnProfileRequiresRefresh(Platform.OS, hotProfile?.config);
      const connectableHotProfile = hotProfile?.hotProfileUsed
        ? connectableLocalProfile(hotProfile, locationId, null, routingMode)
        : null;
      if (
        connectableHotProfile &&
        androidVpnProfileWithinBinderBudget(Platform.OS, connectableHotProfile.config)
      ) {
        const hotEntitlement = connectableHotProfile.entitlement;
        if (!hotEntitlement) {
          throw new Error('Подписка не активна.');
        }
        if (options.requestPermission !== false) {
          const permissionGranted = await requestPermissionWithTiming();
          if (!permissionGranted) {
            throw new Error('Разрешение Android VPN не выдано.');
          }
        }
        const preparedHotProfile = withConnectPreparationTiming(connectableHotProfile);
        cacheProfile(locationId, preparedHotProfile);
        refreshProfileInBackground(locationId, hotEntitlement, connectableHotProfile);
        return preparedHotProfile;
      }
    }

    let currentEntitlement = entitlementState;
    if (!hasPaidEntitlement(currentEntitlement)) {
      const entitlementStartedAtMs = Date.now();
      try {
        currentEntitlement = await queryClient.fetchQuery<Entitlement>({
          queryKey: ['entitlement', accessToken],
          queryFn: () => entitlement(accessToken),
          staleTime: 5 * 60_000,
        });
        requireCurrentSession();
      } finally {
        entitlementWaitMs += Math.max(0, Date.now() - entitlementStartedAtMs);
      }
    }
    if (!hasPaidEntitlement(currentEntitlement)) {
      onSubscriptionRequired();
      throw new Error('Подписка не активна.');
    }

    if (options.requestPermission !== false) {
      const permissionGranted = await requestPermissionWithTiming();
      if (!permissionGranted) {
        throw new Error('Разрешение Android VPN не выдано.');
      }
    }

    if (forceRouteBudgetRefresh) {
      resetVpnProfileCache();
      queryClient.removeQueries({ queryKey: ['vpn-profile', accessToken, locationId, routingMode], exact: true });
      if (userId) {
        await clearHotVpnProfiles(userId).catch(() => undefined);
        requireCurrentSession();
      }
    }

    let profile = !options.forceRefresh && !forceRouteBudgetRefresh && cachedLocalProfile
      ? cachedLocalProfile
      : await resolveVpnProfile(accessToken, currentEntitlement, locationId, {
        allowPersistentHotProfile: forceRouteBudgetRefresh ? false : options.allowPersistentHotProfile,
        forceRefresh: options.forceRefresh === true || forceRouteBudgetRefresh,
        isCurrentSessionOperation,
        revalidateProfile: options.validateCachedProfile && !forceRouteBudgetRefresh ? cachedProfile : undefined,
        routingMode,
        userId,
      });
    requireCurrentSession();
    if (!profile) {
      throw new Error('VPN-профиль недоступен.');
    }
    if (!androidVpnProfileWithinBinderBudget(Platform.OS, profile.config)) {
      resetVpnProfileCache();
      if (userId) {
        await clearHotVpnProfiles(userId).catch(() => undefined);
        requireCurrentSession();
      }
      throw new Error('Сервер вернул слишком большой VPN-профиль. Повторите подключение после обновления профиля.');
    }
    if (profile.rotationRequired) {
      setIsKeyRotationBusy(true);
      try {
        onProfileRotationRequired();
        const rotationStartedAtMs = Date.now();
        try {
          profile = await rotateVpnProfileKey(accessToken, profile, isCurrentSessionOperation);
          requireCurrentSession();
        } finally {
          keyRotationMs += Math.max(0, Date.now() - rotationStartedAtMs);
        }
      } finally {
        if (isCurrentSessionOperation()) setIsKeyRotationBusy(false);
      }
    }
    profile = withConnectPreparationTiming(profile);
    cacheProfile(locationId, profile);
    return profile;
  }, [accessToken, cacheProfile, cachedProfileForLocation, entitlementState, isCurrentSessionOperation, onProfileRefreshFailed, onProfileRotationRequired, onSubscriptionRequired, queryClient, refreshProfileInBackground, requestVpnPermission, requireCurrentSession, routingMode, userId]);

  const refreshManagedProfile = useCallback(async (event: VpnProfileRefreshEvent = {}) => {
    if (!accessToken || !isCurrentSessionOperation()) {
      return;
    }
    const eventDeviceId = event.device_id?.trim();
    if (eventDeviceId && activeProfile?.device?.id && eventDeviceId !== activeProfile.device.id) {
      return;
    }
    if (event.reason !== 'device_revoked' && !backgroundRequestIsCurrent(accessToken, selectedLocationId)) return;
    resetVpnProfileCache();
    await queryClient.invalidateQueries({ queryKey: ['vpn-devices', accessToken] });
    if (!isCurrentSessionOperation()) return;
    if (event.reason === 'device_revoked') {
      if (userId) {
        await clearHotVpnProfiles(userId).catch(() => undefined);
        if (!isCurrentSessionOperation()) return;
      }
      onProfileRefreshFailed?.({
        error: new Error('device_revoked'),
        locationId: selectedLocationId,
        reason: 'hot_profile_revoked',
      });
      setVpnProfile(null);
      await onDeviceRevoked();
      return;
    }
    const nextProfile = await resolveVpnProfile(accessToken, entitlementState, selectedLocationId, { routingMode, userId, isCurrentSessionOperation, shouldFetch: () => backgroundRequestIsCurrent(accessToken, selectedLocationId) }).catch((error) => {
      if (error instanceof ProfileRequestSupersededError || error instanceof SessionOperationSupersededError || !isCurrentSessionOperation()) return null;
      throw error;
    });
    if (!nextProfile || !isCurrentSessionOperation() || !backgroundRequestIsCurrent(accessToken, selectedLocationId)) return;
    setVpnProfile(nextProfile);
    cacheProfile(selectedLocationId, nextProfile);
  }, [accessToken, backgroundRequestIsCurrent, activeProfile?.device?.id, cacheProfile, entitlementState, isCurrentSessionOperation, onDeviceRevoked, onProfileRefreshFailed, queryClient, routingMode, selectedLocationId, setVpnProfile, userId]);

  return {
    activeProfile,
    activeProfileConfig: activeProfile?.config,
    activeProfileDeviceId: activeProfile?.device?.id,
    cacheProfile,
    clearProfile,
    entitlementState,
    isKeyRotationBusy,
    refreshManagedProfile,
    resolveConnectableVpnProfile,
    rotateActiveProfile,
    setActiveProfile: setVpnProfile,
  };
}
