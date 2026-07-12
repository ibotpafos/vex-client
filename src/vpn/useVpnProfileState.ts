import { useCallback, useEffect, useMemo, useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { Platform } from 'react-native';
import { errorMessage } from '@/utils/error';

import { entitlement, hasPaidEntitlement, type Entitlement, type VpnLocation } from '../api/vexApi';
import { resetVpnProfileCache, resolveVpnProfile, rotateVpnProfileKey, type VpnProfile } from './profile';
import type { ResolveConnectableProfileOptions } from './serverSwitch';
import { chooseBestVpnLocation } from './serverSelection';
import { clearHotVpnProfiles, hydrateHotVpnProfilesToQueryCache, loadHotVpnProfileResult, profileFromHotRecord, saveHotVpnProfile } from './hotProfileCache';
import { shouldUseLocalProfileBeforeOnline } from './connectFlow';
import type { VpnRoutingMode } from './routingPolicy';
import { androidVpnProfileWithinBinderBudget } from './androidRoutingSafety';

export type VpnProfileRefreshEvent = {
  device_id?: string;
  reason?: 'profile_updated' | 'device_revoked' | 'rotate_key_required' | string;
};

type UseVpnProfileStateInput = {
  accessToken?: string;
  availableLocations: VpnLocation[];
  hasVpnAccess: boolean;
  knownEntitlement: Entitlement | null;
  onDeviceRevoked: () => Promise<void>;
  onProfileRefreshFailed?: (event: { error: unknown; locationId: string; reason: string }) => void;
  onProfileRotationRequired: () => void;
  onSubscriptionRequired: () => void;
  prewarmStaleMs: number;
  profileRefreshMs: number;
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
    availableLocations,
    hasVpnAccess,
    knownEntitlement,
    onDeviceRevoked,
    onProfileRefreshFailed,
    onProfileRotationRequired,
    onSubscriptionRequired,
    prewarmStaleMs,
    profileRefreshMs,
    requestVpnPermission,
    routingMode,
    selectedLocationId,
    userId,
  } = input;
  const queryClient = useQueryClient();
  const [vpnProfile, setVpnProfile] = useState<VpnProfile | null>(null);
  const [isKeyRotationBusy, setIsKeyRotationBusy] = useState(false);
  const profileQueryKey = useMemo(() => ['vpn-profile', accessToken, selectedLocationId, routingMode] as const, [accessToken, routingMode, selectedLocationId]);
  const fetchSelectedProfile = useCallback(() => resolveVpnProfile(accessToken!, knownEntitlement, selectedLocationId, {
    forceRefresh: true,
    routingMode,
    userId,
  }), [accessToken, knownEntitlement, routingMode, selectedLocationId, userId]);
  const activeProfile = vpnProfile;
  const entitlementState = knownEntitlement ?? activeProfile?.entitlement ?? null;

  const cacheProfile = useCallback((locationId: string, profile: VpnProfile) => {
    if (!accessToken) {
      return;
    }
    queryClient.setQueryData(['vpn-profile', accessToken, locationId, profile.routingMode ?? routingMode], profile);
    if (profile.entitlement) {
      queryClient.setQueryData(['entitlement', accessToken], profile.entitlement);
    }
    if (userId) {
      void saveHotVpnProfile(userId, locationId, profile).catch(() => undefined);
    }
  }, [accessToken, queryClient, routingMode, userId]);

  const cachedProfileForLocation = useCallback((locationId: string): VpnProfile | null => {
    if (!accessToken) {
      return null;
    }
    const cached = queryClient.getQueryData<VpnProfile>(['vpn-profile', accessToken, locationId, routingMode]);
    if (cached) {
      return cached;
    }
    if (vpnProfile?.locationId === locationId && vpnProfile.routingMode === routingMode) {
      return vpnProfile;
    }
    return null;
  }, [accessToken, queryClient, routingMode, vpnProfile]);

  useEffect(() => {
    if (!accessToken || !userId) {
      return;
    }
    void hydrateHotVpnProfilesToQueryCache(userId, accessToken, queryClient)
      .then((records) => {
        const selected = records.find((record) =>
          record.locationId === selectedLocationId && record.profile.routingMode === routingMode
        );
        if (selected) {
          setVpnProfile(selected.profile);
        }
      })
      .catch(() => undefined);
  }, [accessToken, queryClient, routingMode, selectedLocationId, userId]);

  const refreshProfileInBackground = useCallback((
    locationId: string,
    currentEntitlement: Entitlement,
    baseProfile: VpnProfile,
  ) => {
    if (!accessToken) {
      return;
    }
    void resolveVpnProfile(accessToken, currentEntitlement, locationId, {
      forceRefresh: true,
      routingMode,
      userId,
    })
      .then((freshProfile) => {
        cacheProfile(locationId, freshProfile);
        if (baseProfile.device?.id && freshProfile.device?.id !== baseProfile.device.id) {
          return;
        }
        setVpnProfile((current) => current?.locationId === locationId ? freshProfile : current);
      })
      .catch((error) => {
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
  }, [accessToken, cacheProfile, onProfileRefreshFailed, routingMode, userId]);

  const clearProfile = useCallback(() => {
    resetVpnProfileCache();
    if (userId) {
      void clearHotVpnProfiles(userId).catch(() => undefined);
    }
    setVpnProfile(null);
  }, [userId]);

  useEffect(() => {
    if (!accessToken || !hasVpnAccess) {
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
        onProfileRefreshFailed?.({
          error,
          locationId: selectedLocationId,
          reason: 'profile_query_failed',
        });
        return null;
      });
      if (!cancelled && profile) {
        setVpnProfile(profile);
        cacheProfile(selectedLocationId, profile);
      }
    };

    void refreshProfile();
    const timer = setInterval(() => {
      void refreshProfile();
    }, profileRefreshMs);
    return () => {
      cancelled = true;
      clearInterval(timer);
    };
  }, [
    accessToken,
    cacheProfile,
    fetchSelectedProfile,
    hasVpnAccess,
    onProfileRefreshFailed,
    profileQueryKey,
    profileRefreshMs,
    queryClient,
    selectedLocationId,
  ]);

  useEffect(() => {
    if (!accessToken || !hasVpnAccess || !entitlementState || availableLocations.length === 0) {
      return undefined;
    }

    let cancelled = false;
    const prewarmProfiles = async () => {
      const locations = prewarmLocationOrder(availableLocations, selectedLocationId).slice(0, 4);
      for (let index = 0; index < locations.length; index += 2) {
        if (cancelled) {
          return;
        }
        const batch = locations.slice(index, index + 2);
        await Promise.all(batch.map((location) => queryClient.prefetchQuery({
          queryKey: ['vpn-profile', accessToken, location.id, routingMode],
          queryFn: () => resolveVpnProfile(accessToken, entitlementState, location.id, { routingMode, userId }),
          staleTime: prewarmStaleMs,
        }).then(() => {
          const profile = queryClient.getQueryData<VpnProfile>(['vpn-profile', accessToken, location.id, routingMode]);
          if (profile) {
            cacheProfile(location.id, profile);
          }
        }).catch((error) => {
          onProfileRefreshFailed?.({
            error,
            locationId: location.id,
            reason: 'profile_prewarm_failed',
          });
        })));
      }
    };

    void prewarmProfiles();
    return () => {
      cancelled = true;
    };
  }, [accessToken, availableLocations, cacheProfile, entitlementState, hasVpnAccess, onProfileRefreshFailed, prewarmStaleMs, queryClient, routingMode, selectedLocationId, userId]);

  const rotateActiveProfile = useCallback(async (profile: VpnProfile, locationId: string) => {
    if (!accessToken) {
      throw new Error('Сначала войдите в аккаунт.');
    }
    setIsKeyRotationBusy(true);
    try {
      const nextProfile = await rotateVpnProfileKey(accessToken, profile);
      setVpnProfile(nextProfile);
      cacheProfile(locationId, nextProfile);
      return nextProfile;
    } finally {
      setIsKeyRotationBusy(false);
    }
  }, [accessToken, cacheProfile]);

  const resolveConnectableVpnProfile = useCallback(async (
    locationId: string,
    options: ResolveConnectableProfileOptions = {},
  ) => {
    if (!accessToken) {
      throw new Error('Сначала войдите в аккаунт.');
    }

    const preferCached = options.preferCached !== false && options.forceRefresh !== true;
    const cachedProfile = options.cachedProfile ?? cachedProfileForLocation(locationId);
    if (
      preferCached &&
      cachedProfile?.routingMode === routingMode &&
      shouldUseLocalProfileBeforeOnline(cachedProfile, entitlementState) &&
      androidVpnProfileWithinBinderBudget(Platform.OS, cachedProfile.config)
    ) {
      const cachedEntitlement = cachedProfile.entitlement ?? entitlementState;
      if (options.requestPermission !== false) {
        const permissionGranted = await requestVpnPermission();
        if (!permissionGranted) {
          throw new Error('Разрешение Android VPN не выдано.');
        }
      }
      const localProfile: VpnProfile = { ...cachedProfile, source: 'local' };
      cacheProfile(locationId, localProfile);
      refreshProfileInBackground(locationId, cachedEntitlement!, cachedProfile);
      return localProfile;
    }

    if (preferCached && userId) {
      const hotResult = options.allowPersistentHotProfile === false
        ? { record: null }
        : await loadHotVpnProfileResult(userId, locationId, routingMode);
      if (hotResult.rejectedReason && hotResult.rejectedReason !== 'missing') {
        onProfileRefreshFailed?.({
          error: new Error(hotResult.rejectedReason),
          locationId,
          reason: 'hot_profile_rejected',
        });
      }
      const hotProfile = hotResult.record ? profileFromHotRecord(hotResult.record) : null;
      if (
        hotProfile?.hotProfileUsed &&
        hotProfile.routingMode === routingMode &&
        shouldUseLocalProfileBeforeOnline(hotProfile, null) &&
        androidVpnProfileWithinBinderBudget(Platform.OS, hotProfile.config)
      ) {
        const hotEntitlement = hotProfile.entitlement;
        if (!hotEntitlement) {
          throw new Error('Подписка не активна.');
        }
        if (options.requestPermission !== false) {
          const permissionGranted = await requestVpnPermission();
          if (!permissionGranted) {
            throw new Error('Разрешение Android VPN не выдано.');
          }
        }
        cacheProfile(locationId, hotProfile);
        refreshProfileInBackground(locationId, hotEntitlement, hotProfile);
        return hotProfile;
      }
    }

    const currentEntitlement = hasPaidEntitlement(entitlementState)
      ? entitlementState
      : await queryClient.fetchQuery<Entitlement>({
        queryKey: ['entitlement', accessToken],
        queryFn: () => entitlement(accessToken),
        staleTime: 5 * 60_000,
      });
    if (!hasPaidEntitlement(currentEntitlement)) {
      onSubscriptionRequired();
      throw new Error('Подписка не активна.');
    }

    if (options.requestPermission !== false) {
      const permissionGranted = await requestVpnPermission();
      if (!permissionGranted) {
        throw new Error('Разрешение Android VPN не выдано.');
      }
    }

    let profile = !options.forceRefresh && options.cachedProfile
      ? options.cachedProfile
      : await resolveVpnProfile(accessToken, currentEntitlement, locationId, {
        allowPersistentHotProfile: options.allowPersistentHotProfile,
        forceRefresh: options.forceRefresh ?? false,
        routingMode,
        userId,
      });
    cacheProfile(locationId, profile);
    if (!profile) {
      throw new Error('VPN-профиль недоступен.');
    }
    if (profile.rotationRequired) {
      setIsKeyRotationBusy(true);
      try {
        onProfileRotationRequired();
        profile = await rotateVpnProfileKey(accessToken, profile);
        cacheProfile(locationId, profile);
      } finally {
        setIsKeyRotationBusy(false);
      }
    }
    return profile;
  }, [accessToken, cacheProfile, cachedProfileForLocation, entitlementState, onProfileRefreshFailed, onProfileRotationRequired, onSubscriptionRequired, queryClient, refreshProfileInBackground, requestVpnPermission, routingMode, userId]);

  const refreshManagedProfile = useCallback(async (event: VpnProfileRefreshEvent = {}) => {
    if (!accessToken) {
      return;
    }
    const eventDeviceId = event.device_id?.trim();
    if (eventDeviceId && activeProfile?.device?.id && eventDeviceId !== activeProfile.device.id) {
      return;
    }
    resetVpnProfileCache();
    await queryClient.invalidateQueries({ queryKey: ['vpn-devices', accessToken] });
    if (event.reason === 'device_revoked') {
      if (userId) {
        await clearHotVpnProfiles(userId).catch(() => undefined);
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
    const nextProfile = await resolveVpnProfile(accessToken, entitlementState, selectedLocationId, { routingMode, userId });
    setVpnProfile(nextProfile);
    cacheProfile(selectedLocationId, nextProfile);
  }, [accessToken, activeProfile?.device?.id, cacheProfile, entitlementState, onDeviceRevoked, onProfileRefreshFailed, queryClient, routingMode, selectedLocationId, userId]);

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

function prewarmLocationOrder(locations: VpnLocation[], selectedLocationId: string): VpnLocation[] {
  const selected = locations.find((location) => location.id === selectedLocationId);
  const best = chooseBestVpnLocation(locations);
  const ordered: VpnLocation[] = [];
  for (const candidate of [selected, best, ...locations]) {
    if (!candidate || ordered.some((location) => location.id === candidate.id)) {
      continue;
    }
    if (candidate.availability === 'retired' || candidate.healthyNodes <= 0) {
      continue;
    }
    ordered.push(candidate);
  }
  return ordered;
}
