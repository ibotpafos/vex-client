import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { router } from 'expo-router';
import { AppState, Platform } from 'react-native';
import { useQueryClient } from '@tanstack/react-query';

import {
  type Entitlement,
  type VpnDevice,
  type VpnLocation,
  entitlement,
  hasPaidEntitlement,
  registerDevicePushToken,
  vexApiBaseUrl,
  vpnDeviceUsage,
  vpnDevices,
  vpnLocations,
} from '@/api/vexApi';
import { useSession } from '@/auth/session-context';
import {
  playErrorHaptic,
  playMediumImpactHaptic,
  playSelectionHaptic,
  playSuccessHaptic,
  playWarningHaptic,
} from '@/native/haptics';
import { listenTauriEvent } from '@/native/tauriEvents';
import {
  disconnectVpn,
  endVpnLiveActivity,
  getVpnStatus,
  listenVpnStatusChanged,
  measureEndpointLatency,
  requestVpnPermission,
  updateVpnLiveActivity,
  type VpnStatus,
} from '@/native/vexVpn';
import { getExpoAccountPushRegistration } from '@/notifications/expoPush';
import {
  getAndroidAutoConnectEnabled,
  getAntiLeakEnabled,
  getSelectedVpnLocation,
  getServerSelectionMode,
  getVpnRoutingMode,
  setVpnRoutingMode,
  setSelectedVpnLocation,
  setServerSelectionMode,
} from '@/settings/vpnPreferences';
import {
  isVpnTransportFallbackError,
  profileEndpoint,
} from '@/vpn/connectionFallback';
import type { VpnProfile } from '@/vpn/profile';
import { probeNetworkHealth } from '@/vpn/networkHealthProbe';
import {
  defaultVpnRoutingMode,
  isSmartRoutingMode,
  type VpnRoutingMode,
} from '@/vpn/routingPolicy';
import {
  HOME_TAB_ROUTE,
  SERVER_PICKER_ROUTE,
  SUBSCRIPTION_ROUTE,
  UPDATE_CENTER_ROUTE,
} from '@/navigation/routes';
import {
  autoSwitchTargetLocationId,
  type ServerSelectionMode,
} from '@/vpn/serverSelection';
import { switchVpnLocation } from '@/vpn/serverSwitch';
import { useNativeVpnWatchdog } from '@/vpn/useNativeVpnWatchdog';
import { useVpnProfileState, type VpnProfileRefreshEvent } from '@/vpn/useVpnProfileState';
import { useVpnDiagnostics } from './useVpnDiagnostics';
import { useVpnConnectionFlow } from './useVpnConnectionFlow';
import { useVpnConnectionAnimations } from './useVpnConnectionAnimations';
import {
  publishVpnTrafficStats,
  readVpnTrafficStatsSnapshot,
  resetVpnTrafficStats,
} from './vpnTrafficStatsStore';
import {
  loadCachedEntitlement,
  loadCachedVpnDevices,
  loadCachedVpnLocations,
  saveCachedEntitlement,
  saveCachedVpnDevices,
  saveCachedVpnLocations,
} from './vpnQueryCache';

import {
  activeDeviceRefreshMs,
  connectedNativeStatusPollMs,
  entitlementRefreshMs,
  locationRefreshMs,
  nativeStatusPollMs,
  tauriNativeStatusPollMs,
  nativeHealthPollMs,
  nativeHealthFailureThreshold,
  nativeReconnectCooldownMs,
  staleHandshakeReconnectSeconds,
  clientDiagnosticsHeartbeatMs,
  prewarmedProfileStaleMs,
  profileRefreshMs,
  vpnStatusChangedEvent,
  vpnProfileChangedEvent,
  type DiagnosticsSnapshotRef,
  type ConnectionPhase,
  isTauriRuntime,
  supportsNativeLatencyProbe,
  supportsNativeVpnWatchdog,
  supportsNativeStatusPolling,
  nextVpnStatusWithState,
  areVpnStatusesEqual,
  errorMessage,
  isAuthenticationError,
  disconnectedVpnStatus,
  availableVpnLocations,
  formatBytes,
  locationLatencyText,
  serverLocationLabel,
  subscriptionTierLabel,
  subscriptionSummaryText,
} from '../screens/home-screen-helpers';

type VpnStatusCore = Omit<VpnStatus, 'rxBytes' | 'txBytes'>;
const HOME_ROUTE = HOME_TAB_ROUTE;
const deviceLocationLatencyCache: Record<string, number> = {};
const deviceLocationLatencyListeners = new Set<(snapshot: Record<string, number>) => void>();

function publishDeviceLocationLatencies(measurements: readonly (readonly [string, number] | null)[]) {
  let changed = false;
  for (const measurement of measurements) {
    if (!measurement) {
      continue;
    }
    const [locationId, latency] = measurement;
    if (deviceLocationLatencyCache[locationId] !== latency) {
      deviceLocationLatencyCache[locationId] = latency;
      changed = true;
    }
  }
  if (!changed) {
    return;
  }
  const snapshot = { ...deviceLocationLatencyCache };
  for (const listener of deviceLocationLatencyListeners) {
    listener(snapshot);
  }
}

function closeRouteOverlay() {
  if (router.canGoBack()) {
    router.back();
    return;
  }
  router.replace(HOME_ROUTE);
}

export function useVpnConnection() {
  const queryClient = useQueryClient();
  const { session, refreshSession, signOut } = useSession();

  const vpnStatusRef = useRef<VpnStatus>({ state: 'disconnected', rxBytes: 0, txBytes: 0 });
  const [vpnStatusCore, setVpnStatusCore] = useState<VpnStatusCore>(() => vpnStatusCoreFromStatus(vpnStatusRef.current));
  const [vpnError, setVpnError] = useState<string | null>(null);
  const [isVpnBusy, setIsVpnBusy] = useState(false);
  const [isServerSwitching, setIsServerSwitching] = useState(false);
  const [clientLatencyMs, setClientLatencyMs] = useState<number | null>(null);
  const [antiLeakEnabled, setAntiLeakEnabledState] = useState(true);
  const [routingMode, setRoutingMode] = useState<VpnRoutingMode>(defaultVpnRoutingMode);
  const [serverSelectionMode, setServerSelectionModeState] = useState<ServerSelectionMode>('auto');
  const [selectedLocationId, setSelectedLocationId] = useState('de');
  const [isUpdateCenterVisible, setIsUpdateCenterVisible] = useState(false);
  const [isAppActive, setIsAppActive] = useState(AppState.currentState === 'active');

  const diagnosticsSnapshotRef = useRef<DiagnosticsSnapshotRef>({
    vpnStatus: vpnStatusRef.current,
    latencyMs: null,
    endpoint: undefined,
    profileVersion: undefined,
  });

  const setVpnStatus = useCallback((value: React.SetStateAction<VpnStatus>) => {
    const current = vpnStatusRef.current;
    const nextStatus = typeof value === 'function'
      ? value(current)
      : value;
    if (areVpnStatusesEqual(current, nextStatus)) {
      return;
    }
    vpnStatusRef.current = nextStatus;
    publishVpnTrafficStats(nextStatus);
    diagnosticsSnapshotRef.current = {
      ...diagnosticsSnapshotRef.current,
      vpnStatus: nextStatus,
    };
    const nextCore = vpnStatusCoreFromStatus(nextStatus);
    setVpnStatusCore((previousCore) => areVpnStatusCoresEqual(previousCore, nextCore) ? previousCore : nextCore);
  }, []);

  const vpnStatus = useMemo(
    () => ({ ...vpnStatusCore, ...readVpnTrafficStatsSnapshot() }),
    [vpnStatusCore],
  );

  const isConnected = vpnStatusCore.state === 'connected';
  const isAutopilotActive = isConnected || vpnStatusCore.state === 'degraded';
  const isLeakBlocked = vpnStatusCore.leakProtection === 'blocking';

  const connectionPhase: ConnectionPhase = isServerSwitching
    ? 'switching'
    : isLeakBlocked
      ? 'blocked'
      : vpnStatusCore.state === 'degraded'
        ? 'degraded'
      : vpnStatusCore.state === 'verifying' || (vpnStatusCore.state === 'connected' && vpnStatusCore.verified === false)
        ? 'verifying'
      : vpnStatusCore.state === 'connecting'
        ? 'connecting'
        : vpnStatusCore.state === 'disconnecting'
          ? 'disconnecting'
          : isVpnBusy
            ? (isConnected ? 'disconnecting' : 'connecting')
            : isConnected
              ? 'connected'
              : 'idle';

  const { pulseProgress, spinProgress } = useVpnConnectionAnimations(connectionPhase);
  const autoConnectAttemptedRef = useRef(false);
  const vpnOperationInFlightRef = useRef(false);
  const vpnConnectGenerationRef = useRef(0);
  const lastRegisteredPushDeviceRef = useRef('');
  const [persistedEntitlement, setPersistedEntitlement] = useState<Entitlement | null>(null);
  const [persistedLocations, setPersistedLocations] = useState<VpnLocation[] | null>(null);
  const [persistedDevices, setPersistedDevices] = useState<VpnDevice[] | null>(null);
  const [entitlementData, setEntitlementData] = useState<Entitlement | null>(null);
  const [entitlementError, setEntitlementError] = useState<unknown>(null);
  const [locationsData, setLocationsData] = useState<VpnLocation[] | null>(null);
  const [deviceLocationLatencies, setDeviceLocationLatencies] = useState<Record<string, number>>(() => ({
    ...deviceLocationLatencyCache,
  }));
  const [devicesData, setDevicesData] = useState<VpnDevice[] | null>(null);
  const accessToken = session?.accessToken;
  const cacheUserId = session?.user.id ?? '';
  const entitlementQueryKey = useMemo(() => ['entitlement', accessToken] as const, [accessToken]);
  const locationsQueryKey = useMemo(() => ['vpn-locations', accessToken] as const, [accessToken]);
  const devicesQueryKey = useMemo(() => ['vpn-devices', accessToken] as const, [accessToken]);
  const fetchEntitlement = useCallback(() => entitlement(accessToken!), [accessToken]);
  const fetchVpnLocations = useCallback(() => vpnLocations(accessToken!), [accessToken]);
  const fetchVpnDevices = useCallback(() => vpnDevices(accessToken!), [accessToken]);

  const cachedSelectedProfile = accessToken
    ? queryClient.getQueryData<VpnProfile>(['vpn-profile', accessToken, selectedLocationId, routingMode])
    : undefined;
  const cachedEntitlement = entitlementData ?? persistedEntitlement ?? cachedSelectedProfile?.entitlement ?? null;
  const knownEntitlement = entitlementData ?? cachedEntitlement;
  const hasVpnAccess = hasPaidEntitlement(knownEntitlement);

  const locationSource = locationsData ?? persistedLocations ?? undefined;
  const baseAvailableLocations = useMemo(() => availableVpnLocations(locationSource), [locationSource]);
  const availableLocations = useMemo(() => baseAvailableLocations.map((location) => {
    const measuredLatency = deviceLocationLatencies[location.id];
    return typeof measuredLatency === 'number' && Number.isFinite(measuredLatency)
      ? { ...location, latencyMs: measuredLatency }
      : location;
  }), [baseAvailableLocations, deviceLocationLatencies]);

  useEffect(() => {
    const listener = (snapshot: Record<string, number>) => setDeviceLocationLatencies(snapshot);
    deviceLocationLatencyListeners.add(listener);
    return () => {
      deviceLocationLatencyListeners.delete(listener);
    };
  }, []);

  const handleProfileRevoked = useCallback(async () => {
    await disconnectVpn({ releaseAntiLeak: true }).catch(() => undefined);
    setVpnStatus({ state: 'disconnected', rxBytes: 0, txBytes: 0, leakProtection: 'off' });
    setVpnError('Устройство отключено администратором.');
  }, [setVpnStatus]);

  const handleSubscriptionRequired = useCallback(() => {
    router.push(SUBSCRIPTION_ROUTE);
  }, []);

  const handleProfileRefreshFailedRef = useRef<(event: { error: unknown; locationId: string; reason: string }) => void>(() => {});

  const {
    activeProfile,
    activeProfileConfig,
    activeProfileDeviceId,
    cacheProfile,
    clearProfile,
    entitlementState,
    isKeyRotationBusy,
    refreshManagedProfile,
    resolveConnectableVpnProfile,
    rotateActiveProfile,
    setActiveProfile,
  } = useVpnProfileState({
    accessToken: session?.accessToken,
    availableLocations,
    hasVpnAccess,
    knownEntitlement,
    onDeviceRevoked: handleProfileRevoked,
    onProfileRefreshFailed: useCallback((event) => handleProfileRefreshFailedRef.current(event), []),
    onProfileRotationRequired: playWarningHaptic,
    onSubscriptionRequired: handleSubscriptionRequired,
    prewarmStaleMs: prewarmedProfileStaleMs,
    profileRefreshMs,
    requestVpnPermission,
    routingMode,
    selectedLocationId,
    userId: session?.user.id,
  });

  const activeDevice = activeProfile?.device
    ? (devicesData ?? persistedDevices)?.find((device) => device.id === activeProfile.device?.id) ?? activeProfile.device
    : undefined;

  useEffect(() => {
    let cancelled = false;
    if (!cacheUserId) {
      setPersistedEntitlement(null);
      setPersistedLocations(null);
      setPersistedDevices(null);
      return undefined;
    }

    loadCachedEntitlement(cacheUserId)
      .then((value) => {
        if (cancelled || !value) {
          return;
        }
        setPersistedEntitlement(value);
        if (session?.accessToken) {
          queryClient.setQueryData(['entitlement', session.accessToken], (current: Entitlement | undefined) => current ?? value);
        }
      })
      .catch(() => undefined);

    loadCachedVpnLocations(cacheUserId)
      .then((value) => {
        if (cancelled || !value) {
          return;
        }
        setPersistedLocations(value);
        if (session?.accessToken) {
          queryClient.setQueryData(['vpn-locations', session.accessToken], (current: VpnLocation[] | undefined) => current ?? value);
        }
      })
      .catch(() => undefined);

    loadCachedVpnDevices(cacheUserId)
      .then((value) => {
        if (cancelled || !value) {
          return;
        }
        setPersistedDevices(value);
        if (session?.accessToken) {
          queryClient.setQueryData(['vpn-devices', session.accessToken], (current: VpnDevice[] | undefined) => current ?? value);
        }
      })
      .catch(() => undefined);

    return () => {
      cancelled = true;
    };
  }, [cacheUserId, queryClient, session?.accessToken]);

  useEffect(() => {
    if (!accessToken) {
      setEntitlementData(null);
      setEntitlementError(null);
      return undefined;
    }

    let cancelled = false;
    const refreshEntitlement = async () => {
      try {
        const value = await queryClient.fetchQuery({
          queryKey: entitlementQueryKey,
          queryFn: fetchEntitlement,
          staleTime: entitlementRefreshMs,
        });
        if (!cancelled) {
          setEntitlementData(value);
          setEntitlementError(null);
        }
      } catch (error) {
        if (!cancelled) {
          setEntitlementError(error);
        }
      }
    };

    void refreshEntitlement();
    const timer = setInterval(() => {
      void refreshEntitlement();
    }, entitlementRefreshMs);
    return () => {
      cancelled = true;
      clearInterval(timer);
    };
  }, [accessToken, entitlementQueryKey, fetchEntitlement, queryClient]);

  useEffect(() => {
    if (!accessToken || !hasVpnAccess) {
      setLocationsData(null);
      return undefined;
    }

    let cancelled = false;
    const refreshLocations = async () => {
      const value = await queryClient.fetchQuery({
        queryKey: locationsQueryKey,
        queryFn: fetchVpnLocations,
        staleTime: locationRefreshMs,
      }).catch(() => null);
      if (!cancelled && value) {
        setLocationsData(value);
      }
    };

    void refreshLocations();
    const timer = setInterval(() => {
      void refreshLocations();
    }, locationRefreshMs);
    return () => {
      cancelled = true;
      clearInterval(timer);
    };
  }, [accessToken, fetchVpnLocations, hasVpnAccess, locationsQueryKey, queryClient]);

  useEffect(() => {
    if (!accessToken || !activeProfile?.device?.id || !isConnected) {
      setDevicesData(null);
      return undefined;
    }

    let cancelled = false;
    const refreshDevices = async () => {
      const value = await queryClient.fetchQuery({
        queryKey: devicesQueryKey,
        queryFn: fetchVpnDevices,
        staleTime: activeDeviceRefreshMs,
      }).catch(() => null);
      if (!cancelled && value) {
        setDevicesData(value);
      }
    };

    void refreshDevices();
    const timer = setInterval(() => {
      void refreshDevices();
    }, activeDeviceRefreshMs);
    return () => {
      cancelled = true;
      clearInterval(timer);
    };
  }, [accessToken, activeProfile?.device?.id, devicesQueryKey, fetchVpnDevices, isConnected, queryClient]);

  useEffect(() => {
    if (!cacheUserId || !entitlementData) {
      return;
    }
    setPersistedEntitlement(entitlementData);
    void saveCachedEntitlement(cacheUserId, entitlementData).catch(() => undefined);
  }, [cacheUserId, entitlementData]);

  useEffect(() => {
    if (!cacheUserId || !locationsData) {
      return;
    }
    setPersistedLocations(locationsData);
    void saveCachedVpnLocations(cacheUserId, locationsData).catch(() => undefined);
  }, [cacheUserId, locationsData]);

  useEffect(() => {
    if (!cacheUserId || !devicesData) {
      return;
    }
    setPersistedDevices(devicesData);
    void saveCachedVpnDevices(cacheUserId, devicesData).catch(() => undefined);
  }, [cacheUserId, devicesData]);

  const handleSignOut = useCallback(async () => {
    await signOut();
    clearProfile();
    resetVpnTrafficStats();
    setVpnStatus({ state: 'disconnected', rxBytes: 0, txBytes: 0 });
    setVpnError(null);
  }, [signOut, clearProfile, setVpnStatus]);

  const diagnostics = useVpnDiagnostics({
    session,
    activeProfileDeviceId,
    connectionPhase,
    clientLatencyMs,
    vpnStatus,
    diagnosticsSnapshotRef,
    entitlementQueryError: entitlementError,
    cachedEntitlement,
    refreshSession,
  });

  const {
    handleProfileRefreshFailed,
    reportVpnConnectEvent,
    reportVpnDisconnectEvent,
    submitClientDiagnosticsEvent,
    submitVpnDiagnostics,
  } = diagnostics;

  const refreshVpnStatus = useCallback(async (failureEvent: string) => {
    try {
      const nextStatus = await getVpnStatus();
      if (!vpnOperationInFlightRef.current) {
        setVpnStatus((current) => current.state === nextStatus.state && areVpnStatusesEqual(current, nextStatus)
          ? current
          : nextStatus);
      }
      return nextStatus;
    } catch (error) {
      void submitClientDiagnosticsEvent(failureEvent, 'error', {
        error_message: errorMessage(error, failureEvent),
      }).catch(() => undefined);
      return null;
    }
  }, [setVpnStatus, submitClientDiagnosticsEvent]);

  handleProfileRefreshFailedRef.current = handleProfileRefreshFailed;

  const {
    connectProfileWithEndpointFallback,
    connectCurrentVpn,
  } = useVpnConnectionFlow({
    antiLeakEnabled,
    routingMode,
    selectedLocationId,
    serverSelectionMode,
    availableLocations,
    activeProfile,
    entitlementState,
    requestVpnPermission,
    cacheProfile,
    resolveConnectableVpnProfile,
    vpnStatus,
    clientLatencyMs,
    reportVpnConnectEvent,
    setSelectedLocationId,
    setActiveProfile,
    setVpnStatus,
    session,
  });

  const accountTierLabel = subscriptionTierLabel(entitlementState);
  const accountSummaryText = subscriptionSummaryText(entitlementState);
  const selectedLocation = availableLocations.find((location) => location.id === selectedLocationId) ?? availableLocations[0];
  // Home and the server picker must use the same device-to-location probe.
  // clientLatencyMs remains diagnostic telemetry for the active device only.
  const selectedLatencyText = locationLatencyText(selectedLocation);

  const canCancelConnecting = connectionPhase === 'connecting';
  const powerButtonDisabled = isVpnBusy && !canCancelConnecting;

  useEffect(() => {
    void Promise.all([getSelectedVpnLocation(), getServerSelectionMode(), getAntiLeakEnabled(), getVpnRoutingMode()])
      .then(([locationId, mode, enabled, storedRoutingMode]) => {
        setSelectedLocationId(locationId);
        setServerSelectionModeState(mode);
        setAntiLeakEnabledState(enabled);
        setRoutingMode(storedRoutingMode);
      })
      .catch(() => undefined);
  }, [setVpnStatus]);

  useEffect(() => {
    if (!selectedLocation || selectedLocation.id === selectedLocationId) {
      return;
    }
    setSelectedLocationId(selectedLocation.id);
  }, [selectedLocation, selectedLocationId]);

  useEffect(() => {
    diagnosticsSnapshotRef.current = {
      vpnStatus,
      latencyMs: clientLatencyMs,
      endpoint: activeDevice?.endpoint,
      profileVersion: activeProfile?.profileVersion,
      routingMode: activeProfile?.routingMode ?? routingMode,
      bypassRegion: activeProfile?.bypassRegion,
      bypassRangesCount: activeProfile?.bypassRangesCount,
      routingPolicyVersion: activeProfile?.routingPolicyVersion,
      selectedLocationId,
    };
  }, [
    activeDevice?.endpoint,
    activeProfile?.bypassRangesCount,
    activeProfile?.bypassRegion,
    activeProfile?.profileVersion,
    activeProfile?.routingMode,
    activeProfile?.routingPolicyVersion,
    clientLatencyMs,
    routingMode,
    selectedLocationId,
    vpnStatus,
  ]);

  useEffect(() => {
    if (Platform.OS !== 'ios') {
      return;
    }
    if (connectionPhase === 'idle' || vpnStatusCore.state === 'disconnected') {
      void endVpnLiveActivity().catch(() => undefined);
      return;
    }

    const activityLocation = selectedLocation ? serverLocationLabel(selectedLocation) : 'VEX';
    void updateVpnLiveActivity({
      state: vpnStatusCore.state,
      phase: connectionPhase,
      locationName: activityLocation,
      latencyText: selectedLatencyText === '-- мс' ? '' : selectedLatencyText,
      receivedText: formatBytes(vpnStatus.rxBytes),
      sentText: formatBytes(vpnStatus.txBytes),
      updatedAtEpochSeconds: Date.now() / 1000,
    }).catch(() => undefined);
  }, [
    connectionPhase,
    selectedLatencyText,
    selectedLocation,
    vpnStatus.rxBytes,
    vpnStatus.txBytes,
    vpnStatusCore.state,
  ]);



  useEffect(() => {
    if (Platform.OS === 'web' || !session?.accessToken || !activeProfileDeviceId) {
      return undefined;
    }
    const registrationKey = `${activeProfileDeviceId}:${activeProfile?.profileVersion ?? 0}`;
    if (lastRegisteredPushDeviceRef.current === registrationKey) {
      return;
    }
    lastRegisteredPushDeviceRef.current = registrationKey;

    let cancelled = false;
    const registerAccountPushToken = async () => {
      const registration = await getExpoAccountPushRegistration().catch(() => null);
      if (cancelled || !registration) {
        return;
      }
      await registerDevicePushToken(session.accessToken, activeProfileDeviceId, registration);
      await queryClient.invalidateQueries({ queryKey: ['vpn-devices', session.accessToken] });
    };

    void registerAccountPushToken().catch(() => {
      lastRegisteredPushDeviceRef.current = '';
    });
    return () => {
      cancelled = true;
    };
  }, [activeProfile?.profileVersion, activeProfileDeviceId, queryClient, session?.accessToken]);

  useEffect(() => {
    void refreshVpnStatus('native_status_startup_failed');
  }, [refreshVpnStatus]);

  useEffect(() => {
    if (!session) {
      return undefined;
    }
    const subscription = AppState.addEventListener('change', (state) => {
      const isActive = state === 'active';
      setIsAppActive(isActive);
      if (state === 'active') {
        void refreshVpnStatus('native_status_on_active_failed');
        refreshManagedProfile({ reason: 'profile_updated' }).catch((error) => {
          void submitClientDiagnosticsEvent('profile_refresh_on_active_failed', 'error', {
            error_message: errorMessage(error, 'profile_refresh_on_active_failed'),
          }).catch(() => undefined);
        });
      }
    });
    return () => subscription.remove();
  }, [refreshManagedProfile, refreshVpnStatus, session, submitClientDiagnosticsEvent]);

  useEffect(() => {
    if (!isTauriRuntime()) {
      return undefined;
    }

    let disposed = false;
    let unlisten: (() => void) | undefined;
    listenTauriEvent<VpnStatus>(vpnStatusChangedEvent, (nextStatus) => {
      setVpnStatus((current) => areVpnStatusesEqual(current, nextStatus) ? current : nextStatus);
    })
      .then((cleanup) => {
        if (disposed) {
          cleanup();
          return;
        }
        unlisten = cleanup;
      })
      .catch(() => undefined);

    return () => {
      disposed = true;
      unlisten?.();
    };
  }, [setVpnStatus]);

  useEffect(() => {
    let disposed = false;
    let unlisten: (() => void) | undefined;
    listenTauriEvent<VpnProfileRefreshEvent>(vpnProfileChangedEvent, (event) => {
      refreshManagedProfile(event).catch((error) => {
        void submitClientDiagnosticsEvent('profile_refresh_event_failed', 'error', {
          error_message: errorMessage(error, 'profile_refresh_event_failed'),
          profile_refresh_reason: event.reason,
          profile_refresh_location_id: selectedLocationId,
        }).catch(() => undefined);
      });
    })
      .then((cleanup) => {
        if (disposed) {
          cleanup();
          return;
        }
        unlisten = cleanup;
      })
      .catch((error) => {
        void submitClientDiagnosticsEvent('profile_event_subscribe_failed', 'error', {
          error_message: errorMessage(error, 'profile_event_subscribe_failed'),
        }).catch(() => undefined);
      });

    return () => {
      disposed = true;
      unlisten?.();
    };
  }, [refreshManagedProfile, selectedLocationId, submitClientDiagnosticsEvent]);

  useEffect(() => {
    if (!isAppActive || !supportsNativeLatencyProbe()) {
      return undefined;
    }

    const probeTargets = baseAvailableLocations.filter((location) => Boolean(location.endpoint));
    if (probeTargets.length === 0) {
      return undefined;
    }

    let cancelled = false;
    const refreshLocationLatencies = async () => {
      const measurements = await Promise.all(probeTargets.map(async (location) => {
        try {
          const latency = await measureEndpointLatency(location.endpoint || '');
          return typeof latency === 'number' && Number.isFinite(latency)
            ? [location.id, Math.max(0, latency)] as const
            : null;
        } catch {
          return null;
        }
      }));
      if (cancelled) {
        return;
      }
      publishDeviceLocationLatencies(measurements);
    };

    void refreshLocationLatencies();
    const timer = setInterval(() => {
      void refreshLocationLatencies();
    }, 30_000);
    return () => {
      cancelled = true;
      clearInterval(timer);
    };
  }, [baseAvailableLocations, isAppActive]);

  useEffect(() => {
    if (!isAppActive || !supportsNativeLatencyProbe() || !activeDevice?.endpoint) {
      setClientLatencyMs(null);
      return undefined;
    }

    let cancelled = false;
    const refreshLatency = async () => {
      try {
        const nextLatency = await measureEndpointLatency(activeDevice.endpoint || '');
        if (!cancelled) {
          setClientLatencyMs(typeof nextLatency === 'number' && Number.isFinite(nextLatency) ? nextLatency : null);
        }
      } catch {
        if (!cancelled) {
          setClientLatencyMs(null);
        }
      }
    };

    void refreshLatency();
    const timer = setInterval(() => {
      void refreshLatency();
    }, isConnected ? activeDeviceRefreshMs : 30_000);

    return () => {
      cancelled = true;
      clearInterval(timer);
    };
  }, [activeDevice?.endpoint, isAppActive, isConnected]);

  useEffect(() => {
    if (!isAppActive || !isConnected || !session?.accessToken || !activeProfileDeviceId) {
      return undefined;
    }

    let disposed = false;
    const sendHeartbeat = async () => {
      if (disposed) {
        return;
      }
      await submitVpnDiagnostics('vpn_connected_heartbeat', 'ok').catch(() => undefined);
    };

    void sendHeartbeat();
    const timer = setInterval(() => {
      void sendHeartbeat();
    }, clientDiagnosticsHeartbeatMs);

    return () => {
      disposed = true;
      clearInterval(timer);
    };
  }, [activeProfileDeviceId, isAppActive, isConnected, session?.accessToken, submitVpnDiagnostics]);




  const reportNativeWatchdogConnect = useCallback((profile: VpnProfile) => {
    if (!session?.accessToken) {
      return;
    }
    reportVpnConnectEvent(profile, 'native_watchdog');
  }, [reportVpnConnectEvent, session?.accessToken]);

  const probeVpnAutopilotHealth = useCallback((profile: VpnProfile) => {
    return probeNetworkHealth({
      apiBaseUrl: vexApiBaseUrl,
      endpoint: profileEndpoint(profile),
      measureEndpointLatency,
    });
  }, []);

  const handleNativeWatchdogRecoveryStarted = useCallback(() => {
    setVpnError(null);
    setVpnStatus((current) => nextVpnStatusWithState(current, 'degraded'));
  }, [setVpnStatus]);

  const handleNativeWatchdogRecovery = useCallback((profile: VpnProfile, status: VpnStatus, locationId: string) => {
    setActiveProfile(profile);
    setVpnStatus(status);
    if (locationId !== selectedLocationId) {
      setSelectedLocationId(locationId);
    }
  }, [selectedLocationId, setActiveProfile, setVpnStatus]);

  const { recordNativeStatus } = useNativeVpnWatchdog({
    activeDeviceId: activeProfileDeviceId,
    activeLocationId: selectedLocationId,
    activeProfile,
    availableLocations,
    connectProfile: connectProfileWithEndpointFallback,
    enabled: isAppActive && supportsNativeVpnWatchdog() && isAutopilotActive && Boolean(activeProfileConfig),
    failureThreshold: nativeHealthFailureThreshold,
    fetchDeviceUsage: vpnDeviceUsage,
    isRetryableConnectError: isVpnTransportFallbackError,
    isVpnBusy,
    onRecoveryFailed: setVpnError,
    onRecoveryStarted: handleNativeWatchdogRecoveryStarted,
    onRecoverySucceeded: handleNativeWatchdogRecovery,
    operationInFlightRef: vpnOperationInFlightRef,
    persistLocation: setSelectedVpnLocation,
    probeHealth: probeVpnAutopilotHealth,
    pollMs: nativeHealthPollMs,
    reconnectCooldownMs: nativeReconnectCooldownMs,
    reportConnect: reportNativeWatchdogConnect,
    resolveProfile: resolveConnectableVpnProfile,
    rotateProfile: rotateActiveProfile,
    serverSelectionMode,
    sessionAccessToken: session?.accessToken,
    setCachedProfile: cacheProfile,
    staleHandshakeSeconds: staleHandshakeReconnectSeconds,
    submitDiagnostics: submitVpnDiagnostics,
  });

  useEffect(() => {
    if (Platform.OS !== 'android') {
      return undefined;
    }
    return listenVpnStatusChanged((nextStatus) => {
      if (vpnOperationInFlightRef.current) {
        return;
      }
      setVpnStatus((current) => {
        if (recordNativeStatus(current, nextStatus)) {
          return current;
        }
        return areVpnStatusesEqual(current, nextStatus) ? current : nextStatus;
      });
    }) ?? undefined;
  }, [recordNativeStatus, setVpnStatus]);

  useEffect(() => {
    if (!isAppActive || !session || !supportsNativeStatusPolling() || Platform.OS === 'android') {
      return undefined;
    }
    const pollMs = isTauriRuntime()
      ? tauriNativeStatusPollMs
      : isConnected
        ? connectedNativeStatusPollMs
        : nativeStatusPollMs;
    const timer = setInterval(() => {
      void refreshVpnStatus('native_status_poll_failed')
        .then((nextStatus) => {
          if (!nextStatus || vpnOperationInFlightRef.current) {
            return;
          }
          setVpnStatus((current) => {
            if (recordNativeStatus(current, nextStatus)) {
              return current;
            }
            return areVpnStatusesEqual(current, nextStatus) ? current : nextStatus;
          });
        });
    }, pollMs);
    return () => clearInterval(timer);
  }, [isAppActive, isConnected, recordNativeStatus, refreshVpnStatus, session, setVpnStatus]);

  const handleVpnFailure = useCallback((error: unknown, fallbackState: VpnStatus['state']) => {
    const message = errorMessage(error, 'VPN не подключился');
    playErrorHaptic();
    setVpnStatus((current) => nextVpnStatusWithState(current, fallbackState));
    void getVpnStatus()
      .then((latest) => {
        if (latest.state === 'connected' || latest.leakProtection === 'blocking') {
          setVpnStatus(latest);
        }
      })
      .catch(() => undefined);
    if (isAuthenticationError(message)) {
      setVpnError('Проверяем сессию…');
      void refreshSession()
        .then((refreshedSession) => {
          if (refreshedSession) {
            setVpnError('Сессия обновлена. Нажмите «Подключить» ещё раз.');
          }
        })
        .catch((refreshError) => {
          const refreshMessage = errorMessage(refreshError, 'vpn_session_refresh_failed_without_logout');
          void submitClientDiagnosticsEvent('vpn_session_refresh_failed_without_logout', 'auth_error', {
            error_message: refreshMessage,
          }).catch(() => undefined);
          if (isAuthenticationError(refreshMessage)) {
            setVpnError('Сессия истекла. Войдите в аккаунт заново.');
            void signOut();
            return;
          }
          setVpnError('Не удалось проверить сессию. Проверьте интернет и повторите попытку.');
        });
    } else {
      setVpnError(message);
    }
  }, [refreshSession, setVpnStatus, signOut, submitClientDiagnosticsEvent]);

  const handlePowerPress = useCallback(async () => {
    if (isVpnBusy || vpnOperationInFlightRef.current) {
      if (connectionPhase !== 'connecting') {
        playWarningHaptic();
        return;
      }

      vpnOperationInFlightRef.current = true;
      vpnConnectGenerationRef.current += 1;
      setIsVpnBusy(true);
      setVpnError(null);
      setVpnStatus((current) => nextVpnStatusWithState(current, 'disconnecting'));
      try {
        const latestStatus = await getVpnStatus().catch(() => null);
        const nextStatus = await disconnectVpn({ releaseAntiLeak: true }).catch(disconnectedVpnStatus);
        setVpnStatus(nextStatus);
        if (session && activeProfile && (latestStatus?.state === 'connected' || latestStatus?.leakProtection === 'blocking')) {
          reportVpnDisconnectEvent(activeProfile, 'user');
        }
        playSuccessHaptic();
      } catch (error) {
        handleVpnFailure(error, 'disconnected');
      } finally {
        vpnOperationInFlightRef.current = false;
        setIsVpnBusy(false);
      }
      return;
    }

    if (isKeyRotationBusy) {
      playWarningHaptic();
      return;
    }

    vpnOperationInFlightRef.current = true;
    playMediumImpactHaptic();
    setIsVpnBusy(true);
    setVpnError(null);
    setVpnStatus((current) => nextVpnStatusWithState(current, isConnected || isLeakBlocked ? 'disconnecting' : 'connecting'));
    const connectGeneration = !isConnected && !isLeakBlocked ? vpnConnectGenerationRef.current + 1 : vpnConnectGenerationRef.current;
    vpnConnectGenerationRef.current = connectGeneration;
    try {
      if (isConnected || isLeakBlocked) {
        const nextStatus = await disconnectVpn({ releaseAntiLeak: true });
        setVpnStatus(nextStatus);
        if (session && activeProfile) {
          reportVpnDisconnectEvent(activeProfile, 'user');
        }
        playSuccessHaptic();
        return;
      }

      await connectCurrentVpn({ waitForAnimation: true });
      if (vpnConnectGenerationRef.current !== connectGeneration) {
        const nextStatus = await disconnectVpn({ releaseAntiLeak: true }).catch(disconnectedVpnStatus);
        setVpnStatus(nextStatus);
        if (session && activeProfile) {
          reportVpnDisconnectEvent(activeProfile, 'user');
        }
        return;
      }
      playSuccessHaptic();
    } catch (error) {
      handleVpnFailure(error, isConnected ? 'connected' : 'disconnected');
    } finally {
      vpnOperationInFlightRef.current = false;
      setIsVpnBusy(false);
    }
  }, [
    activeProfile,
    connectCurrentVpn,
    connectionPhase,
    handleVpnFailure,
    isConnected,
    isKeyRotationBusy,
    isLeakBlocked,
    isVpnBusy,
    reportVpnDisconnectEvent,
    session,
    setVpnStatus,
  ]);

  useEffect(() => {
    if (Platform.OS !== 'android' || autoConnectAttemptedRef.current || isVpnBusy || vpnOperationInFlightRef.current || isConnected || !session || !hasPaidEntitlement(entitlementState)) {
      return undefined;
    }

    let cancelled = false;
    getAndroidAutoConnectEnabled()
      .then(async (enabled) => {
        if (cancelled || !enabled) {
          return;
        }
        autoConnectAttemptedRef.current = true;
        vpnOperationInFlightRef.current = true;
        setIsVpnBusy(true);
        setVpnError(null);
        setVpnStatus((current) => nextVpnStatusWithState(current, 'connecting'));
        try {
          await connectCurrentVpn();
        } catch (error) {
          if (!cancelled) {
            handleVpnFailure(error, 'disconnected');
          }
        } finally {
          vpnOperationInFlightRef.current = false;
          if (!cancelled) {
            setIsVpnBusy(false);
          }
        }
      })
      .catch(() => undefined);

    return () => {
      cancelled = true;
    };
  }, [connectCurrentVpn, entitlementState, handleVpnFailure, isConnected, isVpnBusy, session, setVpnStatus]);

  const openSubscriptionModal = useCallback(() => {
    if (!session) {
      playWarningHaptic();
      setVpnError('Сначала войдите в аккаунт.');
      return;
    }
    playSelectionHaptic();
    setVpnError(null);
    router.push(SUBSCRIPTION_ROUTE);
  }, [session]);

  const closeSubscriptionModal = useCallback(() => {
    playSelectionHaptic();
    closeRouteOverlay();
  }, []);

  const handleRotateKeyPress = useCallback(async () => {
    if (!session || !activeProfile || isVpnBusy || vpnOperationInFlightRef.current || isKeyRotationBusy) {
      playWarningHaptic();
      return;
    }
    try {
      setVpnError(null);
      playMediumImpactHaptic();
      await rotateActiveProfile(activeProfile, selectedLocationId);
      playSuccessHaptic();
    } catch (error) {
      handleVpnFailure(error, vpnStatusCore.state);
    }
  }, [
    activeProfile,
    handleVpnFailure,
    isKeyRotationBusy,
    isVpnBusy,
    rotateActiveProfile,
    selectedLocationId,
    session,
    vpnStatusCore.state,
  ]);

  const switchConnectedVpnLocation = useCallback(async (targetLocationId: string) => {
    if (!session) {
      setVpnError('Сначала войдите в аккаунт.');
      return;
    }
    if (isVpnBusy || vpnOperationInFlightRef.current) {
      playWarningHaptic();
      return;
    }

    const previousLocationId = selectedLocationId;
    const previousProfile = activeProfile;
    const previousStatus = vpnStatusRef.current;

    vpnOperationInFlightRef.current = true;
    closeRouteOverlay();
    setIsVpnBusy(true);
    setIsServerSwitching(true);
    setVpnError(null);

    try {
      const cachedTargetProfile = queryClient.getQueryData<VpnProfile>(['vpn-profile', session.accessToken, targetLocationId, routingMode]);
      const result = await switchVpnLocation({
        cachedTargetProfile,
        connectProfile: connectProfileWithEndpointFallback,
        isRetryableConnectError: isVpnTransportFallbackError,
        persistLocation: setSelectedVpnLocation,
        previousLocationId,
        previousProfile,
        previousStatus,
        reportConnect: (profile) => {
          reportVpnConnectEvent(profile, 'server_switch');
        },
        reportDisconnect: (profile, reason) => {
          if (profile) {
            reportVpnDisconnectEvent(profile, reason);
          }
        },
        resolveProfile: resolveConnectableVpnProfile,
        setCachedProfile: cacheProfile,
        targetLocationId,
      });

      if (result.ok) {
        setSelectedLocationId(result.locationId);
        setActiveProfile(result.profile);
        setVpnStatus(result.status);
        playSuccessHaptic();
        return;
      }

      setSelectedLocationId(previousLocationId);
      setActiveProfile(result.profile ?? previousProfile);
      if (result.status) {
        setVpnStatus(result.status);
      }
      playErrorHaptic();

      if (result.rollback === 'unavailable') {
        setVpnStatus((current) => nextVpnStatusWithState(current, 'disconnected'));
        setVpnError('Не удалось переключиться, предыдущий профиль недоступен.');
        return;
      }
      if (result.rollback === 'failed') {
        setVpnStatus((current) => nextVpnStatusWithState(current, 'disconnected'));
        setVpnError(errorMessage(result.rollbackError, 'Не удалось вернуть предыдущий сервер.'));
        return;
      }

      const message = errorMessage(result.error, 'Не удалось переключиться на выбранный сервер.');
      setVpnError(`${message} Вернули предыдущий сервер.`);
    } catch (error) {
      setSelectedLocationId(previousLocationId);
      setActiveProfile(previousProfile);
      setVpnStatus(previousStatus);
      playErrorHaptic();
      setVpnError(errorMessage(error, 'Не удалось переключиться на выбранный сервер.'));
    } finally {
      vpnOperationInFlightRef.current = false;
      setIsServerSwitching(false);
      setIsVpnBusy(false);
    }
  }, [
    activeProfile,
    cacheProfile,
    connectProfileWithEndpointFallback,
    isVpnBusy,
    queryClient,
    reportVpnConnectEvent,
    reportVpnDisconnectEvent,
    resolveConnectableVpnProfile,
    routingMode,
    selectedLocationId,
    session,
    setActiveProfile,
    setVpnStatus,
  ]);

  const handleLocationPress = useCallback(async (locationId: string) => {
    if (isVpnBusy) {
      playWarningHaptic();
      return;
    }
    const normalizedLocationId = locationId.trim().toLowerCase() || 'de';
    playSelectionHaptic();
    try {
      const nextMode = await setServerSelectionMode('manual');
      setServerSelectionModeState(nextMode);
    } catch (error) {
      playErrorHaptic();
      setVpnError(errorMessage(error, 'Не удалось сохранить режим выбора сервера.'));
      return;
    }
    if (normalizedLocationId === selectedLocationId) {
      closeRouteOverlay();
      return;
    }

    if (isConnected) {
      await switchConnectedVpnLocation(normalizedLocationId);
      return;
    }

    const persistedLocationId = await setSelectedVpnLocation(normalizedLocationId);
    setSelectedLocationId(persistedLocationId);
    closeRouteOverlay();
    clearProfile();
    setVpnError(null);
  }, [clearProfile, isConnected, isVpnBusy, selectedLocationId, switchConnectedVpnLocation]);

  const handleAutoServerSelectionPress = useCallback(async () => {
    if (isVpnBusy) {
      playWarningHaptic();
      return;
    }
    playSelectionHaptic();
    try {
      const nextMode = await setServerSelectionMode('auto');
      setServerSelectionModeState(nextMode);
    } catch (error) {
      playErrorHaptic();
      setVpnError(errorMessage(error, 'Не удалось включить автовыбор сервера.'));
      return;
    }
    setVpnError(null);

    if (!isConnected) {
      closeRouteOverlay();
      return;
    }

    const targetLocationId = autoSwitchTargetLocationId(selectedLocationId, availableLocations);
    if (!targetLocationId) {
      closeRouteOverlay();
      return;
    }
    await switchConnectedVpnLocation(targetLocationId);
  }, [availableLocations, isConnected, isVpnBusy, selectedLocationId, switchConnectedVpnLocation]);

  const openServerPicker = useCallback(() => {
    playSelectionHaptic();
    router.push({
      pathname: SERVER_PICKER_ROUTE,
      params: {
        activeLatencyText: selectedLatencyText,
        activeLocationId: selectedLocation?.id ?? selectedLocationId,
      },
    });
  }, [selectedLatencyText, selectedLocation?.id, selectedLocationId]);

  const closeServerPicker = useCallback(() => {
    playSelectionHaptic();
    closeRouteOverlay();
  }, []);

  const openUpdateCenter = useCallback(() => {
    if (Platform.OS === 'android' || Platform.OS === 'ios') {
      router.push(UPDATE_CENTER_ROUTE);
      return;
    }
    setIsUpdateCenterVisible(true);
  }, []);

  const closeUpdateCenter = useCallback(() => {
    playSelectionHaptic();
    setIsUpdateCenterVisible(false);
  }, []);

  const handleSmartRoutingToggle = useCallback(async (next: boolean) => {
    const nextMode: VpnRoutingMode = next ? 'all_except_ru' : 'full_tunnel';
    const savedMode = await setVpnRoutingMode(nextMode);
    setRoutingMode(savedMode);
    if (vpnStatusRef.current.state !== 'connected') {
      setActiveProfile(null);
    }
    await queryClient.invalidateQueries({ queryKey: ['vpn-profile', session?.accessToken] });
    return savedMode;
  }, [queryClient, session?.accessToken, setActiveProfile]);

  return {
    session,
    vpnStatus,
    vpnError,
    isVpnBusy,
    isServerSwitching,
    clientLatencyMs,
    antiLeakEnabled,
    routingMode,
    isSmartRoutingEnabled: isSmartRoutingMode(routingMode),
    serverSelectionMode,
    selectedLocationId,
    isUpdateCenterVisible,
    isConnected,
    isAutopilotActive,
    isLeakBlocked,
    connectionPhase,
    pulseProgress,
    spinProgress,
    activeProfile,
    activeProfileConfig,
    activeProfileDeviceId,
    isKeyRotationBusy,
    accountTierLabel,
    accountSummaryText,
    selectedLocation,
    selectedLatencyText,
    canCancelConnecting,
    powerButtonDisabled,
    handleSignOut,
    handlePowerPress,
    openSubscriptionModal,
    closeSubscriptionModal,
    handleRotateKeyPress,
    handleLocationPress,
    handleAutoServerSelectionPress,
    openServerPicker,
    closeServerPicker,
    openUpdateCenter,
    closeUpdateCenter,
    handleSmartRoutingToggle,
    clearProfile,
    setVpnError,
    availableLocations,
  };
}

function vpnStatusCoreFromStatus(status: VpnStatus): VpnStatusCore {
  const {
    rxBytes: _rxBytes,
    txBytes: _txBytes,
    ...coreStatus
  } = status;
  return coreStatus;
}

function areVpnStatusCoresEqual(left: VpnStatusCore, right: VpnStatusCore): boolean {
  return left.state === right.state
    && left.latestHandshakeEpochMillis === right.latestHandshakeEpochMillis
    && left.leakProtection === right.leakProtection
    && left.verified === right.verified
    && left.verificationReason === right.verificationReason;
}
