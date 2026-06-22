import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Animated, AppState, Easing, Platform } from 'react-native';
import { useQuery, useQueryClient } from '@tanstack/react-query';

import {
  entitlement,
  hasPaidEntitlement,
  registerDevicePushToken,
  reportVpnConnect,
  reportVpnDisconnect,
  vexApiBaseUrl,
  vpnDeviceUsage,
  vpnDevices,
  vpnLocations,
  type Entitlement,
  type VpnDeviceUsage,
  type VpnLocation,
} from '@/api/vexApi';
import { useSession } from '@/auth/session-context';
import { uploadClientDiagnostics } from '@/diagnostics/clientDiagnostics';
import {
  playErrorHaptic,
  playMediumImpactHaptic,
  playSelectionHaptic,
  playSuccessHaptic,
  playWarningHaptic,
} from '@/native/haptics';
import { listenTauriEvent } from '@/native/tauriEvents';
import {
  connectVpn,
  disconnectVpn,
  getVpnStatus,
  measureEndpointLatency,
  openVpnSettings,
  requestVpnPermission,
  type VpnStatus,
} from '@/native/vexVpn';
import { getExpoAccountPushRegistration } from '@/notifications/expoPush';
import {
  getAndroidAutoConnectEnabled,
  getAntiLeakEnabled,
  getSelectedVpnLocation,
  getServerSelectionMode,
  setSelectedVpnLocation,
  setServerSelectionMode,
} from '@/settings/vpnPreferences';
import {
  connectionAttemptsForProfile,
  isVpnTransportFallbackError,
  profileEndpoint,
} from '@/vpn/connectionFallback';
import { connectableLocalProfile, vpnConnectTimingSamples } from '@/vpn/connectFlow';
import { saveHotVpnProfile, withLastSuccessfulEndpoint } from '@/vpn/hotProfileCache';
import type { VpnProfile } from '@/vpn/profile';
import { probeNetworkHealth } from '@/vpn/networkHealthProbe';
import {
  autoSwitchTargetLocationId,
  chooseBestVpnLocation,
  type ServerSelectionMode,
} from '@/vpn/serverSelection';
import { switchVpnLocation } from '@/vpn/serverSwitch';
import { useNativeVpnWatchdog } from '@/vpn/useNativeVpnWatchdog';
import { useVpnProfileState, type VpnProfileRefreshEvent } from '@/vpn/useVpnProfileState';

import {
  animationKickDelayMs,
  activeDeviceRefreshMs,
  nativeStatusPollMs,
  nativeHealthPollMs,
  nativeHealthFailureThreshold,
  nativeReconnectCooldownMs,
  staleHandshakeReconnectSeconds,
  clientDiagnosticsHeartbeatMs,
  clientDiagnosticsErrorCooldownMs,
  prewarmedProfileStaleMs,
  connectAttemptTimeoutMs,
  vpnStatusChangedEvent,
  vpnProfileChangedEvent,
  DiagnosticsSnapshotRef,
  ConnectedVpnAttempt,
  ConnectionPhase,
  isTauriRuntime,
  supportsNativeLatencyProbe,
  supportsNativeVpnWatchdog,
  supportsNativeStatusPolling,
  nextVpnStatusWithState,
  areVpnStatusesEqual,
  errorMessage,
  isAuthenticationError,
  waitForAnimationKick,
  disconnectedVpnStatus,
  availableVpnLocations,
  locationLatencyText,
  subscriptionTierLabel,
  subscriptionSummaryText,
  withTimeout,
} from '../screens/home-screen-helpers';

export function useVpnConnection() {
  const queryClient = useQueryClient();
  const { session, refreshSession, signOut } = useSession();

  const [vpnStatus, setVpnStatus] = useState<VpnStatus>({ state: 'disconnected', rxBytes: 0, txBytes: 0 });
  const [vpnError, setVpnError] = useState<string | null>(null);
  const [isVpnBusy, setIsVpnBusy] = useState(false);
  const [isServerSwitching, setIsServerSwitching] = useState(false);
  const [clientLatencyMs, setClientLatencyMs] = useState<number | null>(null);
  const [isSubscriptionModalVisible, setIsSubscriptionModalVisible] = useState(false);
  const [antiLeakEnabled, setAntiLeakEnabledState] = useState(true);
  const [serverSelectionMode, setServerSelectionModeState] = useState<ServerSelectionMode>('auto');
  const [selectedLocationId, setSelectedLocationId] = useState('de');
  const [isServerPickerVisible, setIsServerPickerVisible] = useState(false);
  const [isUpdateCenterVisible, setIsUpdateCenterVisible] = useState(false);

  const isConnected = vpnStatus.state === 'connected';
  const isAutopilotActive = isConnected || vpnStatus.state === 'degraded';
  const isLeakBlocked = vpnStatus.leakProtection === 'blocking';

  const connectionPhase: ConnectionPhase = isServerSwitching
    ? 'switching'
    : isLeakBlocked
      ? 'blocked'
      : vpnStatus.state === 'degraded'
        ? 'degraded'
      : vpnStatus.state === 'verifying' || (vpnStatus.state === 'connected' && vpnStatus.verified === false)
        ? 'verifying'
      : vpnStatus.state === 'connecting'
        ? 'connecting'
        : vpnStatus.state === 'disconnecting'
          ? 'disconnecting'
          : isVpnBusy
            ? (isConnected ? 'disconnecting' : 'connecting')
            : isConnected
              ? 'connected'
              : 'idle';

  const pulseProgress = useRef(new Animated.Value(0)).current;
  const spinProgress = useRef(new Animated.Value(0)).current;
  const autoConnectAttemptedRef = useRef(false);
  const vpnOperationInFlightRef = useRef(false);
  const vpnConnectGenerationRef = useRef(0);
  const lastRegisteredPushDeviceRef = useRef('');
  const lastEntitlementDiagnosticsRef = useRef('');
  const lastClientDiagnosticsAtRef = useRef<Record<string, number>>({});

  const entitlementQuery = useQuery({
    queryKey: ['entitlement', session?.accessToken],
    queryFn: () => entitlement(session!.accessToken),
    enabled: Boolean(session?.accessToken),
    staleTime: 30_000,
    refetchInterval: 30_000,
  });

  const cachedSelectedProfile = session?.accessToken
    ? queryClient.getQueryData<VpnProfile>(['vpn-profile', session.accessToken, selectedLocationId])
    : undefined;
  const cachedEntitlement = cachedSelectedProfile?.entitlement ?? null;
  const knownEntitlement = entitlementQuery.data ?? cachedEntitlement;
  const hasVpnAccess = hasPaidEntitlement(knownEntitlement);

  const locationsQuery = useQuery({
    queryKey: ['vpn-locations', session?.accessToken],
    queryFn: () => vpnLocations(session!.accessToken),
    enabled: Boolean(session?.accessToken && hasVpnAccess),
    staleTime: 30_000,
    refetchInterval: 30_000,
  });

  const availableLocations = useMemo(() => availableVpnLocations(locationsQuery.data), [locationsQuery.data]);

  const handleProfileRevoked = useCallback(async () => {
    await disconnectVpn({ releaseAntiLeak: true }).catch(() => undefined);
    setVpnStatus({ state: 'disconnected', rxBytes: 0, txBytes: 0, leakProtection: 'off' });
    setVpnError('Устройство отключено администратором.');
  }, []);

  const handleSubscriptionRequired = useCallback(() => {
    setIsSubscriptionModalVisible(true);
  }, []);

  const submitProfileDiagnosticsEvent = useCallback(async ({ error, locationId, reason }: { error: unknown; locationId: string; reason: string }) => {
    if (!session?.accessToken) {
      return;
    }
    const message = errorMessage(error, reason);
    const diagnosticKey = `${reason}:error:${locationId}:${message}`;
    const now = Date.now();
    if (now - (lastClientDiagnosticsAtRef.current[diagnosticKey] ?? 0) < clientDiagnosticsErrorCooldownMs) {
      return;
    }
    lastClientDiagnosticsAtRef.current[diagnosticKey] = now;

    await uploadClientDiagnostics(session.accessToken, {
      reason,
      status: 'error',
      vpnStatus,
      latencyMs: clientLatencyMs,
      samples: {
        connection_phase: connectionPhase,
        error_message: message,
        location_id: locationId,
      },
    });
  }, [clientLatencyMs, connectionPhase, session?.accessToken, vpnStatus]);

  const handleProfileRefreshFailed = useCallback((event: { error: unknown; locationId: string; reason: string }) => {
    void submitProfileDiagnosticsEvent(event).catch(() => undefined);
  }, [submitProfileDiagnosticsEvent]);

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
    onProfileRefreshFailed: handleProfileRefreshFailed,
    onProfileRotationRequired: playWarningHaptic,
    onSubscriptionRequired: handleSubscriptionRequired,
    prewarmStaleMs: prewarmedProfileStaleMs,
    requestVpnPermission,
    selectedLocationId,
    userId: session?.user.id,
  });

  const devicesQuery = useQuery({
    queryKey: ['vpn-devices', session?.accessToken],
    queryFn: () => vpnDevices(session!.accessToken),
    enabled: Boolean(session?.accessToken && activeProfile?.device?.id && isConnected),
    refetchInterval: isConnected ? activeDeviceRefreshMs : false,
    staleTime: activeDeviceRefreshMs,
  });

  const activeDevice = activeProfile?.device
    ? devicesQuery.data?.find((device) => device.id === activeProfile.device?.id) ?? activeProfile.device
    : undefined;

  const diagnosticsSnapshotRef = useRef<DiagnosticsSnapshotRef>({
    vpnStatus,
    latencyMs: clientLatencyMs,
    endpoint: activeDevice?.endpoint,
    profileVersion: activeProfile?.profileVersion,
  });

  const accountTierLabel = subscriptionTierLabel(entitlementState);
  const accountSummaryText = subscriptionSummaryText(entitlementState);
  const selectedLocation = availableLocations.find((location) => location.id === selectedLocationId) ?? availableLocations[0];
  const selectedLatencyText = locationLatencyText(selectedLocation, clientLatencyMs);

  const canCancelConnecting = connectionPhase === 'connecting';
  const powerButtonDisabled = isVpnBusy && !canCancelConnecting;

  const handleSignOut = useCallback(async () => {
    await disconnectVpn({ releaseAntiLeak: true }).catch(() => undefined);
    await signOut();
    clearProfile();
    setVpnStatus({ state: 'disconnected', rxBytes: 0, txBytes: 0 });
    setVpnError(null);
  }, [signOut, clearProfile]);

  useEffect(() => {
    void Promise.all([getSelectedVpnLocation(), getServerSelectionMode(), getAntiLeakEnabled()])
      .then(([locationId, mode, enabled]) => {
        setSelectedLocationId(locationId);
        setServerSelectionModeState(mode);
        setAntiLeakEnabledState(enabled);
      })
      .catch(() => undefined);
  }, []);

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
      routingMode: activeProfile?.routingMode,
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
    selectedLocationId,
    vpnStatus,
  ]);

  const submitVpnDiagnostics = useCallback(async (reason: string, status: string, samples: Record<string, unknown> = {}) => {
    if (!session?.accessToken || !activeProfileDeviceId) {
      return;
    }
    const latest = diagnosticsSnapshotRef.current;
    const usageRows = await vpnDeviceUsage(session.accessToken).catch((): VpnDeviceUsage[] => []);
    const usage = usageRows.find((item) => item.deviceId === activeProfileDeviceId);
    await uploadClientDiagnostics(session.accessToken, {
      reason,
      status,
      deviceId: activeProfileDeviceId,
      endpoint: latest.endpoint,
      vpnStatus: latest.vpnStatus,
      latencyMs: latest.latencyMs,
      routingMode: latest.routingMode,
      bypassRegion: latest.bypassRegion,
      bypassRangesCount: latest.bypassRangesCount,
      routingPolicyVersion: latest.routingPolicyVersion,
      selectedLocationId: latest.selectedLocationId,
      usage,
      samples: {
        profile_version: latest.profileVersion,
        connection_phase: connectionPhase,
        ...samples,
      },
    });
  }, [activeProfileDeviceId, connectionPhase, session?.accessToken]);

  const submitClientDiagnosticsEvent = useCallback(async (reason: string, status: string, samples: Record<string, unknown> = {}) => {
    if (!session?.accessToken) {
      return;
    }
    const diagnosticKey = `${reason}:${status}:${String(samples.error_message ?? samples.error ?? '')}`;
    const now = Date.now();
    if (now - (lastClientDiagnosticsAtRef.current[diagnosticKey] ?? 0) < clientDiagnosticsErrorCooldownMs) {
      return;
    }
    lastClientDiagnosticsAtRef.current[diagnosticKey] = now;

    const latest = diagnosticsSnapshotRef.current;
    await uploadClientDiagnostics(session.accessToken, {
      reason,
      status,
      deviceId: activeProfileDeviceId,
      endpoint: latest.endpoint,
      vpnStatus: latest.vpnStatus,
      latencyMs: latest.latencyMs,
      routingMode: latest.routingMode,
      bypassRegion: latest.bypassRegion,
      bypassRangesCount: latest.bypassRangesCount,
      routingPolicyVersion: latest.routingPolicyVersion,
      selectedLocationId: latest.selectedLocationId,
      samples: {
        profile_version: latest.profileVersion,
        connection_phase: connectionPhase,
        ...samples,
      },
    });
  }, [activeProfileDeviceId, connectionPhase, session?.accessToken]);

  const reportVpnConnectEvent = useCallback((profile: VpnProfile, reason: string) => {
    if (!session?.accessToken) {
      return;
    }
    void reportVpnConnect(session.accessToken, profile).catch((error) => {
      void submitClientDiagnosticsEvent('vpn_connect_report_failed', 'error', {
        error_message: errorMessage(error, 'vpn_connect_report_failed'),
        report_reason: reason,
        report_device_id: profile.device?.id,
        report_location_id: profile.locationId,
        report_profile_source: profile.source,
      }).catch(() => undefined);
    });
  }, [session?.accessToken, submitClientDiagnosticsEvent]);

  const reportVpnDisconnectEvent = useCallback((profile: VpnProfile, reason: string) => {
    if (!session?.accessToken) {
      return;
    }
    void reportVpnDisconnect(session.accessToken, profile, reason).catch((error) => {
      void submitClientDiagnosticsEvent('vpn_disconnect_report_failed', 'error', {
        error_message: errorMessage(error, 'vpn_disconnect_report_failed'),
        report_reason: reason,
        report_device_id: profile.device?.id,
        report_location_id: profile.locationId,
        report_profile_source: profile.source,
      }).catch(() => undefined);
    });
  }, [session?.accessToken, submitClientDiagnosticsEvent]);

  useEffect(() => {
    if (!entitlementQuery.error) {
      return;
    }
    const message = errorMessage(entitlementQuery.error, '');
    if (session?.accessToken && lastEntitlementDiagnosticsRef.current !== message) {
      lastEntitlementDiagnosticsRef.current = message;
      void uploadClientDiagnostics(session.accessToken, {
        reason: 'entitlement_fetch_failed',
        status: isAuthenticationError(message) ? 'auth_error' : 'error',
        vpnStatus,
        latencyMs: clientLatencyMs,
        samples: {
          entitlement_error: message,
          had_cached_entitlement: Boolean(cachedEntitlement),
          cached_entitlement_active: hasPaidEntitlement(cachedEntitlement),
        },
      }).catch(() => undefined);
    }
    if (isAuthenticationError(message)) {
      refreshSession().catch(() => {
        void handleSignOut();
      });
    }
  }, [
    cachedEntitlement,
    clientLatencyMs,
    entitlementQuery.error,
    handleSignOut,
    refreshSession,
    session?.accessToken,
    vpnStatus,
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
    getVpnStatus()
      .then((nextStatus) => {
        if (!vpnOperationInFlightRef.current) {
          setVpnStatus(nextStatus);
        }
      })
      .catch((error) => {
        void submitClientDiagnosticsEvent('native_status_startup_failed', 'error', {
          error_message: errorMessage(error, 'native_status_startup_failed'),
        }).catch(() => undefined);
      });
  }, [submitClientDiagnosticsEvent]);

  useEffect(() => {
    if (!session) {
      return undefined;
    }
    const subscription = AppState.addEventListener('change', (state) => {
      if (state === 'active') {
        refreshManagedProfile({ reason: 'profile_updated' }).catch((error) => {
          void submitClientDiagnosticsEvent('profile_refresh_on_active_failed', 'error', {
            error_message: errorMessage(error, 'profile_refresh_on_active_failed'),
          }).catch(() => undefined);
        });
      }
    });
    return () => subscription.remove();
  }, [refreshManagedProfile, session, submitClientDiagnosticsEvent]);

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
  }, []);

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
    if (!supportsNativeLatencyProbe() || !activeDevice?.endpoint) {
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
  }, [activeDevice?.endpoint, isConnected]);

  useEffect(() => {
    if (!isConnected || !session?.accessToken || !activeProfileDeviceId) {
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
  }, [activeProfileDeviceId, isConnected, session?.accessToken, submitVpnDiagnostics]);

  useEffect(() => {
    pulseProgress.stopAnimation();
    pulseProgress.setValue(0);

    if (connectionPhase === 'idle') {
      return undefined;
    }

    const loop = Animated.loop(
      Animated.sequence([
        Animated.timing(pulseProgress, {
          duration: connectionPhase === 'connected' ? 1500 : 700,
          easing: Easing.inOut(Easing.quad),
          toValue: 1,
          useNativeDriver: true,
        }),
        Animated.timing(pulseProgress, {
          duration: connectionPhase === 'connected' ? 1500 : 700,
          easing: Easing.inOut(Easing.quad),
          toValue: 0,
          useNativeDriver: true,
        }),
      ]),
    );
    loop.start();

    return () => loop.stop();
  }, [connectionPhase, pulseProgress]);

  useEffect(() => {
    spinProgress.stopAnimation();
    spinProgress.setValue(0);

    if (connectionPhase !== 'connecting' && connectionPhase !== 'verifying' && connectionPhase !== 'disconnecting' && connectionPhase !== 'switching') {
      return undefined;
    }

    const loop = Animated.loop(
      Animated.timing(spinProgress, {
        duration: connectionPhase === 'disconnecting' ? 800 : 1100,
        easing: Easing.linear,
        toValue: 1,
        useNativeDriver: true,
      }),
    );
    loop.start();

    return () => loop.stop();
  }, [connectionPhase, spinProgress]);

  const connectProfileWithEndpointFallback = useCallback(async (profile: VpnProfile) => {
    let lastError: unknown;
    const endpointAttempts: string[] = [];
    for (const attempt of connectionAttemptsForProfile(profile)) {
      try {
        const endpoint = profileEndpoint(attempt);
        if (endpoint) {
          endpointAttempts.push(endpoint);
        }
        const nativeStartMs = Date.now();
        const status = await withTimeout(
          connectVpn(attempt.config, { antiLeakEnabled }),
          connectAttemptTimeoutMs,
          'VPN connect timed out.',
        );
        return {
          interfaceUpMs: Date.now(),
          endpointAttempts,
          nativeStartMs,
          profile: withLastSuccessfulEndpoint(attempt, endpoint),
          status,
        };
      } catch (error) {
        lastError = error;
        if (!isVpnTransportFallbackError(error)) {
          throw error;
        }
      }
    }
    throw lastError;
  }, [antiLeakEnabled]);

  const connectCurrentVpn = useCallback(async ({
    locationId = selectedLocationId,
    waitForAnimation = false,
  }: {
    locationId?: string;
    waitForAnimation?: boolean;
  } = {}) => {
    const tapStartedAt = Date.now();
    void waitForAnimation;

    const initialLocationId = serverSelectionMode === 'auto'
      ? chooseBestVpnLocation(availableLocations)?.id ?? locationId
      : locationId;
    let profile = connectableLocalProfile(activeProfile, initialLocationId, entitlementState);
    if (profile) {
      const permissionGranted = await requestVpnPermission();
      if (!permissionGranted) {
        throw new Error('Разрешение Android VPN не выдано.');
      }
      cacheProfile(initialLocationId, profile);
    } else {
      profile = await resolveConnectableVpnProfile(initialLocationId, { preferCached: true });
    }
    let connected: ConnectedVpnAttempt | null = null;
    let connectedLocationId = initialLocationId;
    let lastConnectError: unknown;

    try {
      connected = await connectProfileWithEndpointFallback(profile);
    } catch (error) {
      if (profile.hotProfileUsed && session?.accessToken) {
        void uploadClientDiagnostics(session.accessToken, {
          reason: 'hot_profile_connect_failed',
          status: 'failed',
          deviceId: profile.device?.id,
          endpoint: profileEndpoint(profile),
          vpnStatus,
          samples: {
            connect_error: errorMessage(error, 'hot_profile_connect_failed'),
            hot_profile_age_ms: profile.hotProfileAgeMs ?? null,
          },
        }).catch(() => undefined);
      }
      if (!isVpnTransportFallbackError(error)) {
        throw error;
      }
      lastConnectError = error;
    }

    for (const fallbackLocation of availableLocations) {
      if (connected?.status.state === 'connected' || fallbackLocation.id === initialLocationId) {
        continue;
      }
      const fallbackProfile = await resolveConnectableVpnProfile(fallbackLocation.id, {
        preferCached: true,
        requestPermission: false,
      });
      try {
        connected = await connectProfileWithEndpointFallback(fallbackProfile);
        connectedLocationId = fallbackLocation.id;
      } catch (error) {
        lastConnectError = error;
        if (!isVpnTransportFallbackError(error)) {
          throw error;
        }
        const freshFallbackProfile = await resolveConnectableVpnProfile(fallbackLocation.id, {
          forceRefresh: true,
          preferCached: false,
          requestPermission: false,
        });
        try {
          connected = await connectProfileWithEndpointFallback(freshFallbackProfile);
          connectedLocationId = fallbackLocation.id;
        } catch (freshError) {
          lastConnectError = freshError;
          if (!isVpnTransportFallbackError(freshError)) {
            throw freshError;
          }
        }
      }
    }

    if (!connected || connected.status.state !== 'connected') {
      throw lastConnectError ?? new Error('VPN не подключился.');
    }

    if (connectedLocationId !== selectedLocationId) {
      const persistedLocationId = await setSelectedVpnLocation(connectedLocationId);
      setSelectedLocationId(persistedLocationId);
      cacheProfile(persistedLocationId, connected.profile);
    }

    setActiveProfile(connected.profile);
    if (session?.user.id) {
      void saveHotVpnProfile(session.user.id, connected.profile.locationId || connectedLocationId, connected.profile, {
        lastSuccessfulEndpoint: profileEndpoint(connected.profile),
      }).catch(() => undefined);
    }
    const nextStatus = connected.status;
    setVpnStatus(nextStatus);
    if (session) {
      reportVpnConnectEvent(connected.profile, 'user');
      void uploadClientDiagnostics(session.accessToken, {
        reason: 'vpn_connect_timing',
        status: nextStatus.verified === false ? 'verifying' : 'ok',
        deviceId: connected.profile.device?.id,
        endpoint: connected.profile.device?.endpoint,
        vpnStatus: nextStatus,
        latencyMs: clientLatencyMs,
        samples: {
          ...vpnConnectTimingSamples({
            endpointAttempts: connected.endpointAttempts,
            interfaceUpMs: connected.interfaceUpMs,
            nativeStartMs: connected.nativeStartMs,
            profile: connected.profile,
            tapStartedAt,
          }),
          interface_up_to_handshake_ms: nextStatus.verified ? Math.max(0, connected.interfaceUpMs - connected.nativeStartMs) : null,
        },
      }).catch(() => undefined);
    }
  }, [
    availableLocations,
    activeProfile,
    cacheProfile,
    clientLatencyMs,
    connectProfileWithEndpointFallback,
    entitlementState,
    reportVpnConnectEvent,
    requestVpnPermission,
    resolveConnectableVpnProfile,
    selectedLocationId,
    serverSelectionMode,
    session,
    setActiveProfile,
    vpnStatus,
  ]);

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
  }, []);

  const handleNativeWatchdogRecovery = useCallback((profile: VpnProfile, status: VpnStatus, locationId: string) => {
    setActiveProfile(profile);
    setVpnStatus(status);
    if (locationId !== selectedLocationId) {
      setSelectedLocationId(locationId);
    }
  }, [selectedLocationId, setActiveProfile]);

  const { recordNativeStatus } = useNativeVpnWatchdog({
    activeDeviceId: activeProfileDeviceId,
    activeLocationId: selectedLocationId,
    activeProfile,
    availableLocations,
    connectProfile: connectProfileWithEndpointFallback,
    enabled: supportsNativeVpnWatchdog() && isAutopilotActive && Boolean(activeProfileConfig),
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
    if (!session || !supportsNativeStatusPolling()) {
      return undefined;
    }
    const timer = setInterval(() => {
      getVpnStatus()
        .then((nextStatus) => {
          if (vpnOperationInFlightRef.current) {
            return;
          }
          setVpnStatus((current) => {
            if (recordNativeStatus(current, nextStatus)) {
              return current;
            }
            return areVpnStatusesEqual(current, nextStatus) ? current : nextStatus;
          });
        })
        .catch((error) => {
          void submitClientDiagnosticsEvent('native_status_poll_failed', 'error', {
            error_message: errorMessage(error, 'native_status_poll_failed'),
          }).catch(() => undefined);
        });
    }, nativeStatusPollMs);
    return () => clearInterval(timer);
  }, [recordNativeStatus, session, submitClientDiagnosticsEvent]);

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
      refreshSession().catch(() => void handleSignOut());
      setVpnError('Сессия истекла. Авторизуйтесь заново.');
    } else {
      setVpnError(message);
    }
  }, [handleSignOut, refreshSession]);

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
        await waitForAnimationKick();
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
  ]);

  useEffect(() => {
    if (Platform.OS !== 'android' || autoConnectAttemptedRef.current || isVpnBusy || vpnOperationInFlightRef.current || isConnected || !session || !hasPaidEntitlement(entitlementState)) {
      return undefined;
    }

    let cancelled = false;
    autoConnectAttemptedRef.current = true;
    getAndroidAutoConnectEnabled()
      .then(async (enabled) => {
        if (cancelled || !enabled) {
          return;
        }
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
  }, [connectCurrentVpn, entitlementState, handleVpnFailure, isConnected, isVpnBusy, session]);

  const openSubscriptionModal = useCallback(() => {
    if (!session) {
      playWarningHaptic();
      setVpnError('Сначала войдите в аккаунт.');
      return;
    }
    playSelectionHaptic();
    setVpnError(null);
    setIsSubscriptionModalVisible(true);
    void queryClient.invalidateQueries({ queryKey: ['billing-summary'] }).catch((error) => {
      setVpnError(errorMessage(error, 'Не удалось обновить подписки.'));
    });
  }, [queryClient, session]);

  const closeSubscriptionModal = useCallback(() => {
    playSelectionHaptic();
    setIsSubscriptionModalVisible(false);
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
      handleVpnFailure(error, vpnStatus.state);
    }
  }, [
    activeProfile,
    handleVpnFailure,
    isKeyRotationBusy,
    isVpnBusy,
    rotateActiveProfile,
    selectedLocationId,
    session,
    vpnStatus.state,
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
    const previousStatus = vpnStatus;

    vpnOperationInFlightRef.current = true;
    setIsServerPickerVisible(false);
    setIsVpnBusy(true);
    setIsServerSwitching(true);
    setVpnError(null);

    try {
      await waitForAnimationKick();
      const cachedTargetProfile = queryClient.getQueryData<VpnProfile>(['vpn-profile', session.accessToken, targetLocationId]);
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
    queryClient,
    reportVpnConnectEvent,
    reportVpnDisconnectEvent,
    resolveConnectableVpnProfile,
    selectedLocationId,
    session,
    setActiveProfile,
    vpnStatus,
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
      setIsServerPickerVisible(false);
      return;
    }

    if (isConnected) {
      await switchConnectedVpnLocation(normalizedLocationId);
      return;
    }

    const persistedLocationId = await setSelectedVpnLocation(normalizedLocationId);
    setSelectedLocationId(persistedLocationId);
    setIsServerPickerVisible(false);
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
      setIsServerPickerVisible(false);
      return;
    }

    const targetLocationId = autoSwitchTargetLocationId(selectedLocationId, availableLocations);
    if (!targetLocationId) {
      setIsServerPickerVisible(false);
      return;
    }
    await switchConnectedVpnLocation(targetLocationId);
  }, [availableLocations, isConnected, isVpnBusy, selectedLocationId, switchConnectedVpnLocation]);

  const openServerPicker = useCallback(() => {
    playSelectionHaptic();
    setIsServerPickerVisible(true);
  }, []);

  const closeServerPicker = useCallback(() => {
    playSelectionHaptic();
    setIsServerPickerVisible(false);
  }, []);

  const openUpdateCenter = useCallback(() => {
    setIsUpdateCenterVisible(true);
  }, []);

  const closeUpdateCenter = useCallback(() => {
    playSelectionHaptic();
    setIsUpdateCenterVisible(false);
  }, []);

  const handleOpenVpnSettingsPress = useCallback(() => {
    playSelectionHaptic();
    void openVpnSettings().catch((error) => {
      setVpnError(errorMessage(error, 'Не удалось открыть настройки VPN.'));
    });
  }, []);

  return {
    session,
    vpnStatus,
    vpnError,
    isVpnBusy,
    isServerSwitching,
    clientLatencyMs,
    antiLeakEnabled,
    serverSelectionMode,
    selectedLocationId,
    isServerPickerVisible,
    isUpdateCenterVisible,
    isSubscriptionModalVisible,
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
    handleOpenVpnSettingsPress,
    clearProfile,
    setVpnError,
    availableLocations,
  };
}
