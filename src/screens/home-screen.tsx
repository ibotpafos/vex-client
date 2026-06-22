import { StatusBar } from 'expo-status-bar';
import { router } from 'expo-router';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import {
  ArrowDown,
  ArrowUp,
  CheckCircle2,
  ChevronRight,
  Gauge,
  MapPin,
  RefreshCw,
  Settings,
  X,
  User,
} from 'lucide-react-native';
import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  ActivityIndicator,
  Animated,
  AppState,
  Easing,
  Modal,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { entitlement, hasPaidEntitlement, registerDevicePushToken, reportVpnConnect, reportVpnDisconnect, vexApiBaseUrl, vpnDeviceUsage, vpnDevices, vpnLocations, type Entitlement, type VpnDeviceUsage, type VpnLocation } from '@/api/vexApi';
import { useSession } from '@/auth/session-context';
import { HomeNativeHeader } from '@/components/home-native-header';
import { SubscriptionContent } from '@/components/subscription-content';
import { UpdateCenterButton } from '@/components/update-center';
import { uploadClientDiagnostics } from '@/diagnostics/clientDiagnostics';
import { playErrorHaptic, playMediumImpactHaptic, playSelectionHaptic, playSuccessHaptic, playWarningHaptic } from '@/native/haptics';
import { listenTauriEvent } from '@/native/tauriEvents';
import { connectVpn, disconnectVpn, getVpnStatus, measureEndpointLatency, openVpnSettings, requestVpnPermission, type VpnStatus } from '@/native/vexVpn';
import { getExpoAccountPushRegistration } from '@/notifications/expoPush';
import { getAndroidAutoConnectEnabled, getAntiLeakEnabled, getSelectedVpnLocation, getServerSelectionMode, setSelectedVpnLocation, setServerSelectionMode } from '@/settings/vpnPreferences';
import { VexScreen, vexSharedStyles } from '@/ui/vex-ui';
import { connectionAttemptsForProfile, isVpnTransportFallbackError, profileEndpoint } from '@/vpn/connectionFallback';
import { vpnConnectTimingSamples } from '@/vpn/connectFlow';
import { saveHotVpnProfile, withLastSuccessfulEndpoint } from '@/vpn/hotProfileCache';
import type { VpnProfile } from '@/vpn/profile';
import { probeNetworkHealth } from '@/vpn/networkHealthProbe';
import { autoSwitchTargetLocationId, chooseBestVpnLocation, type ServerSelectionMode } from '@/vpn/serverSelection';
import { switchVpnLocation } from '@/vpn/serverSwitch';
import { useNativeVpnWatchdog } from '@/vpn/useNativeVpnWatchdog';
import { useVpnProfileState, type VpnProfileRefreshEvent } from '@/vpn/useVpnProfileState';

const vexLogo = require('../../assets/vex-logo-header.png');

const maxContentWidth = 430;
const vpnStatusChangedEvent = 'vpn-status-changed';
const vpnProfileChangedEvent = 'vpn-profile-changed';
const animationKickDelayMs = 80;
const activeDeviceRefreshMs = 15_000;
const nativeStatusPollMs = 2_500;
const nativeHealthPollMs = 30_000;
const nativeHealthFailureThreshold = 2;
const nativeReconnectCooldownMs = 120_000;
const staleHandshakeReconnectSeconds = 180;
const clientDiagnosticsHeartbeatMs = 5 * 60_000;
const clientDiagnosticsErrorCooldownMs = 60_000;
const prewarmedProfileStaleMs = 2 * 60_000;
const connectAttemptTimeoutMs = 25_000;

type DiagnosticsSnapshotRef = {
  vpnStatus: VpnStatus;
  latencyMs: number | null;
  endpoint?: string;
  profileVersion?: number;
  routingMode?: string;
  bypassRegion?: string;
  bypassRangesCount?: number;
  routingPolicyVersion?: string;
  selectedLocationId?: string;
};

type ConnectedVpnAttempt = {
  endpointAttempts: string[];
  interfaceUpMs: number;
  nativeStartMs: number;
  profile: VpnProfile;
  status: VpnStatus;
};

type ConnectionPhase = 'idle' | 'connecting' | 'connected' | 'verifying' | 'degraded' | 'disconnecting' | 'switching' | 'blocked';

function isTauriRuntime() {
  return Platform.OS === 'web' && typeof window !== 'undefined' && ('__TAURI_INTERNALS__' in window || '__TAURI__' in window || '__TAURI_INVOKE__' in window);
}

function supportsNativeLatencyProbe() {
  return isTauriRuntime() || Platform.OS === 'android';
}

function supportsNativeVpnWatchdog() {
  return isTauriRuntime() || Platform.OS === 'android';
}

function supportsNativeStatusPolling() {
  return isTauriRuntime() || Platform.OS === 'android' || Platform.OS === 'ios';
}

function nextVpnStatusWithState(current: VpnStatus, state: VpnStatus['state']): VpnStatus {
  return { ...current, state };
}

function areVpnStatusesEqual(left: VpnStatus, right: VpnStatus) {
  return left.state === right.state && left.rxBytes === right.rxBytes && left.txBytes === right.txBytes;
}

function errorMessage(error: unknown, fallback: string): string {
  if (error instanceof Error && typeof error.message === 'string' && error.message.trim()) {
    return error.message;
  }
  if (typeof error === 'string' && error.trim()) {
    return error;
  }
  return fallback;
}

function timeoutError(message: string): Error {
  const error = new Error(message);
  error.name = 'TimeoutError';
  return error;
}

function withTimeout<T>(promise: Promise<T>, timeoutMs: number, message: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(timeoutError(message)), timeoutMs);
    promise.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (error) => {
        clearTimeout(timer);
        reject(error);
      },
    );
  });
}

function isAuthenticationError(message: string): boolean {
  return message.includes('401') || message.includes('Unauthorized') || message.includes('authentication required');
}

function waitForAnimationKick() {
  return new Promise<void>((resolve) => {
    if (typeof window !== 'undefined' && typeof window.requestAnimationFrame === 'function') {
      window.requestAnimationFrame(() => {
        window.setTimeout(resolve, animationKickDelayMs);
      });
      return;
    }
    setTimeout(resolve, animationKickDelayMs);
  });
}

function disconnectedVpnStatus(): VpnStatus {
  return {
    state: 'disconnected',
    rxBytes: 0,
    txBytes: 0,
    leakProtection: 'off',
  };
}

export default function App() {
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
  const powerButtonText = connectionPhase === 'switching'
    ? 'Переключение'
    : connectionPhase === 'blocked'
      ? 'Отключить'
    : connectionPhase === 'degraded'
      ? 'Восстанавливаем'
    : connectionPhase === 'verifying'
      ? 'Проверяем'
    : connectionPhase === 'connecting'
    ? 'Отменить'
    : connectionPhase === 'disconnecting'
      ? 'Отключение'
      : connectionPhase === 'connected'
        ? 'Подключено'
        : 'Подключить';
  const powerSubtext = connectionPhase === 'connected'
    ? 'VPN активен'
    : connectionPhase === 'blocked'
      ? 'Интернет заблокирован'
    : connectionPhase === 'degraded'
      ? 'Чиним туннель'
    : connectionPhase === 'verifying'
      ? 'Ждем handshake'
    : connectionPhase === 'switching'
      ? 'Меняем сервер'
    : connectionPhase === 'connecting'
      ? 'Запускаем'
      : connectionPhase === 'disconnecting'
        ? 'Завершаем'
        : 'VPN выключен';
  const animatedScale = pulseProgress.interpolate({
    inputRange: [0, 1],
    outputRange: [1, connectionPhase === 'connected' ? 1.045 : 1.02],
  });
  const glowScale = pulseProgress.interpolate({
    inputRange: [0, 1],
    outputRange: [1, connectionPhase === 'idle' ? 1 : 1.12],
  });
  const glowOpacity = pulseProgress.interpolate({
    inputRange: [0, 1],
    outputRange: [connectionPhase === 'idle' ? 0.55 : 0.72, connectionPhase === 'connected' ? 0.92 : 0.78],
  });
  const orbitOpacity = connectionPhase === 'idle' ? 0 : 1;
  const orbitRotation = spinProgress.interpolate({
    inputRange: [0, 1],
    outputRange: ['0deg', '360deg'],
  });
  const handleSignOut = useCallback(async () => {
    await disconnectVpn({ releaseAntiLeak: true }).catch(() => undefined);
    await signOut();
    clearProfile();
    setVpnStatus({ state: 'disconnected', rxBytes: 0, txBytes: 0 });
    setVpnError(null);
  }, [signOut]);

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
  }, [activeDevice?.endpoint, activeProfile?.bypassRangesCount, activeProfile?.bypassRegion, activeProfile?.profileVersion, activeProfile?.routingMode, activeProfile?.routingPolicyVersion, clientLatencyMs, selectedLocationId, vpnStatus]);

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
  }, [cachedEntitlement, clientLatencyMs, entitlementQuery.error, handleSignOut, refreshSession, session?.accessToken, vpnStatus]);

  useEffect(() => {
    if (Platform.OS === 'web' || !session?.accessToken || !activeProfileDeviceId) {
      return;
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
    const profile = await resolveConnectableVpnProfile(initialLocationId, { preferCached: true });
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
  }, [availableLocations, cacheProfile, clientLatencyMs, clearProfile, connectProfileWithEndpointFallback, reportVpnConnectEvent, resolveConnectableVpnProfile, selectedLocationId, serverSelectionMode, session, setActiveProfile, vpnStatus]);

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
  }, [activeProfile, connectCurrentVpn, connectionPhase, handleVpnFailure, isConnected, isKeyRotationBusy, isLeakBlocked, isVpnBusy, reportVpnDisconnectEvent, session]);

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
  }, [activeProfile, handleVpnFailure, isKeyRotationBusy, isVpnBusy, rotateActiveProfile, selectedLocationId, session, vpnStatus.state]);

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
  }, [activeProfile, cacheProfile, connectProfileWithEndpointFallback, queryClient, reportVpnConnectEvent, reportVpnDisconnectEvent, resolveConnectableVpnProfile, selectedLocationId, session, setActiveProfile, vpnStatus]);

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

  return (
    <VexScreen contentStyle={styles.shell}>
        <StatusBar style="light" />
            <HomeNativeHeader
              logoSource={vexLogo}
              planLabel={accountTierLabel}
              showPlan={Boolean(session && accountTierLabel)}
	              actions={(
	                <View style={styles.topActions}>
	                <UpdateCenterButton
	                  visible={isUpdateCenterVisible}
	                  onClose={closeUpdateCenter}
	                  onOpen={openUpdateCenter}
	                />
	                <Pressable
                  onPress={() => {
                    playSelectionHaptic();
                    router.push('/settings');
                  }}
                  style={vexSharedStyles.iconButton}
                  accessibilityLabel="Настройки"
                >
                  <Settings color="#A7B9BD" size={25} strokeWidth={2.4} />
                </Pressable>
              </View>
              )}
            />

            {!session ? (
              <View style={styles.centerState}>
                <ActivityIndicator color="#22D3EE" size="large" />
                <Text style={styles.centerStateText}>Загружаем VEX</Text>
              </View>
            ) : (
            <View style={styles.mainContent}>
              <Pressable onPress={openSubscriptionModal} style={styles.accountCard}>
                <View style={styles.accountHeader}>
                  <View style={styles.userBadge}>
                    <User color="#22D3EE" size={25} strokeWidth={2.5} />
                  </View>
                  <View style={styles.accountCopy}>
                    <Text numberOfLines={1} style={styles.accountEmail}>{session.user.email}</Text>
                    <View style={styles.accountStatusRow}>
                      <View style={[styles.accountStatusDot, hasVpnAccess && styles.accountStatusDotActive]} />
                      <Text numberOfLines={1} style={styles.accountMeta}>{accountSummaryText}</Text>
                    </View>
                  </View>
                  <View style={styles.accountActionWrap}>
                    <Text style={styles.accountAction}>Управлять</Text>
                    <ChevronRight color="#22D3EE" size={18} strokeWidth={2.6} />
                  </View>
                </View>
              </Pressable>

              <View style={styles.hero}>
                <View pointerEvents="none" style={styles.heroBackdrop}>
                  <View style={[styles.heroNode, styles.heroNodeTopLeft]} />
                  <View style={[styles.heroNode, styles.heroNodeTopRight]} />
                  <View style={[styles.heroLink, styles.heroLinkOne]} />
                </View>
                <Animated.View
                  pointerEvents="none"
                  style={[styles.heroGlow, { opacity: glowOpacity, transform: [{ scale: glowScale }] }]}
                />
                <View
                  pointerEvents="none"
                  style={styles.heroRing}
                />
                <Animated.View
                  pointerEvents="none"
                  style={[styles.heroRingOuter, { opacity: glowOpacity, transform: [{ scale: glowScale }] }]}
                />
                <Animated.View style={[styles.powerButtonFrame, isConnected && styles.powerButtonFrameActive, isVpnBusy && styles.powerButtonBusy, { transform: [{ scale: animatedScale }] }]}>
                  <Pressable
                    disabled={powerButtonDisabled}
                    onPress={handlePowerPress}
                    style={styles.powerButton}
                    accessibilityRole="button"
                    accessibilityLabel={connectionPhase === 'connecting' ? 'Отменить подключение VPN' : isConnected ? 'Отключить VPN' : 'Подключить VPN'}
                  >
                    <Animated.View
                      pointerEvents="none"
                      style={[styles.powerOrbit, { opacity: orbitOpacity, transform: [{ rotate: orbitRotation }] }]}
	                    />
	                    <Text numberOfLines={1} adjustsFontSizeToFit style={styles.powerText}>{powerButtonText}</Text>
	                    <Text style={styles.powerSubtext}>{powerSubtext}</Text>
	                  </Pressable>
	                </Animated.View>
	              </View>

              <ServerChip
                disabled={isVpnBusy}
                isAutoMode={serverSelectionMode === 'auto'}
                latencyText={selectedLatencyText}
                location={selectedLocation}
                onPress={openServerPicker}
              />
              <TrafficStats rxBytes={vpnStatus.rxBytes} txBytes={vpnStatus.txBytes} />

              <View pointerEvents="none" style={styles.protocolSpacer} />
              {activeProfile?.rotationRequired ? (
                <Pressable disabled={isKeyRotationBusy || isVpnBusy} onPress={handleRotateKeyPress} style={styles.rotationNotice}>
                  <Text numberOfLines={2} style={styles.vpnNoticeText}>
                    {isKeyRotationBusy ? 'Обновляем VPN-ключ...' : 'Ключ VPN устарел. Нажмите, чтобы обновить.'}
                  </Text>
                </Pressable>
              ) : null}
              {Platform.OS === 'android' && antiLeakEnabled ? (
                <Pressable disabled={isVpnBusy} onPress={handleOpenVpnSettingsPress} style={styles.rotationNotice}>
                  <Text numberOfLines={2} style={styles.vpnNoticeText}>
                    Для максимальной защиты включите Always-on VPN и блокировку без VPN в настройках Android.
                  </Text>
                </Pressable>
              ) : null}
              {vpnError ? <Text numberOfLines={2} style={styles.vpnErrorText}>{vpnError}</Text> : null}

              <ServerPickerModal
                currentLatencyText={selectedLatencyText}
                isVpnBusy={isVpnBusy}
                locations={availableLocations}
                selectionMode={serverSelectionMode}
                selectedLocationId={selectedLocationId}
                visible={isServerPickerVisible}
                onAutoSelect={handleAutoServerSelectionPress}
                onClose={closeServerPicker}
                onSelect={handleLocationPress}
              />
              <SubscriptionModal
                visible={isSubscriptionModalVisible}
                onClose={closeSubscriptionModal}
              />

            </View>
            )}
    </VexScreen>
  );
}

function ServerChip({
  disabled,
  isAutoMode,
  latencyText,
  location,
  onPress,
}: {
  disabled: boolean;
  isAutoMode: boolean;
  latencyText: string;
  location?: VpnLocation;
  onPress: () => void;
}) {
  const locationLabel = location ? serverLocationLabel(location) : 'Не выбран';
  const serverLabel = isAutoMode && location ? `Авто: ${locationLabel}` : locationLabel;
  const visibleServerLabel = locationLabel;
  return (
    <Pressable
      disabled={disabled}
      onPress={onPress}
      style={[styles.serverChip, disabled && styles.serverChipDisabled]}
      accessibilityRole="button"
      accessibilityLabel={`Выбрать сервер. Сейчас ${serverLabel}, задержка ${latencyText}`}
    >
      <View style={styles.serverChipIcon}>
        <MapPin color="#22D3EE" size={18} strokeWidth={2.5} />
      </View>
      <View style={styles.serverChipCopy}>
        <Text style={styles.serverChipCaption}>{isAutoMode ? 'Сервер · авто' : 'Сервер'}</Text>
        <Text numberOfLines={1} style={styles.serverChipLabel}>
          {visibleServerLabel}
        </Text>
      </View>
      <View style={styles.serverLatencyPill}>
        <Gauge color="#B9FBFF" size={13} strokeWidth={2.6} />
        <Text numberOfLines={1} style={styles.serverLatencyText}>{latencyText}</Text>
      </View>
      <ChevronRight color="#78969C" size={19} strokeWidth={2.6} />
    </Pressable>
  );
}

function TrafficStats({ rxBytes, txBytes }: { rxBytes: number; txBytes: number }) {
  return (
    <View style={styles.trafficStats} accessibilityLabel={`Трафик. Получено ${formatBytes(rxBytes)}, отправлено ${formatBytes(txBytes)}`}>
      <View style={styles.trafficItem}>
        <Text style={styles.trafficLabel}>Получено</Text>
        <View style={styles.trafficValueRow}>
          <Text numberOfLines={1} adjustsFontSizeToFit style={styles.trafficValue}>{formatBytes(rxBytes)}</Text>
          <View style={styles.trafficDirectionBadge}>
            <ArrowDown color="#22D3EE" size={13} strokeWidth={3} />
          </View>
        </View>
      </View>
      <View style={styles.trafficDivider} />
      <View style={styles.trafficItem}>
        <Text style={styles.trafficLabel}>Отправлено</Text>
        <View style={styles.trafficValueRow}>
          <Text numberOfLines={1} adjustsFontSizeToFit style={styles.trafficValue}>{formatBytes(txBytes)}</Text>
          <View style={styles.trafficDirectionBadge}>
            <ArrowUp color="#22D3EE" size={13} strokeWidth={3} />
          </View>
        </View>
      </View>
    </View>
  );
}

function ServerPickerModal({
  currentLatencyText,
  isVpnBusy,
  locations,
  selectionMode,
  selectedLocationId,
  visible,
  onAutoSelect,
  onClose,
  onSelect,
}: {
  currentLatencyText: string;
  isVpnBusy: boolean;
  locations: VpnLocation[];
  selectionMode: ServerSelectionMode;
  selectedLocationId: string;
  visible: boolean;
  onAutoSelect: () => void;
  onClose: () => void;
  onSelect: (locationId: string) => void;
}) {
  const autoSelected = selectionMode === 'auto';
  return (
    <Modal animationType="slide" onRequestClose={onClose} presentationStyle="fullScreen" visible={visible}>
      <View style={styles.serverModal}>
        <View style={styles.serverModalHeader}>
          <View>
            <Text style={styles.serverModalEyebrow}>VEX VPN</Text>
            <Text style={styles.serverModalTitle}>Серверы</Text>
            <Text style={styles.serverModalSubtitle}>Ближайший стабильный узел для текущей сессии.</Text>
          </View>
          <Pressable onPress={onClose} style={styles.serverModalClose} accessibilityLabel="Закрыть выбор сервера">
            <X color="#A7B9BD" size={24} strokeWidth={2.5} />
          </Pressable>
        </View>

        <ScrollView contentContainerStyle={styles.serverModalList} showsVerticalScrollIndicator={false}>
          <Pressable
            disabled={isVpnBusy}
            onPress={onAutoSelect}
            style={[styles.serverRow, autoSelected && styles.serverRowSelected, isVpnBusy && !autoSelected && styles.serverRowDisabled]}
            accessibilityRole="button"
            accessibilityState={{ selected: autoSelected, disabled: isVpnBusy }}
            accessibilityLabel="Автоматически выбирать лучший сервер"
          >
            <View style={styles.serverRowMain}>
              <View style={styles.serverRowFlagBox}>
                <RefreshCw color="#22D3EE" size={18} strokeWidth={2.7} />
              </View>
              <View style={styles.serverRowCopy}>
                <Text numberOfLines={1} style={[styles.serverRowName, autoSelected && styles.serverRowNameSelected]}>Автоматически</Text>
                <View style={styles.serverRowStatusLine}>
                  <View style={[styles.serverHealthDot, styles.serverHealthDotActive]} />
                  <Text numberOfLines={1} style={styles.serverRowStatus}>Лучший доступный сервер</Text>
                </View>
              </View>
            </View>
            <View style={styles.serverRowSide}>
              <Text style={[styles.serverRowLatency, autoSelected && styles.serverRowLatencySelected]}>Авто</Text>
              {autoSelected ? <CheckCircle2 color="#22D3EE" size={20} strokeWidth={2.7} /> : null}
            </View>
          </Pressable>
          {locations.map((location) => {
            const selected = selectionMode === 'manual' && location.id === selectedLocationId;
            const disabled = isVpnBusy;
            return (
              <Pressable
                key={location.id}
                disabled={disabled}
                onPress={() => onSelect(location.id)}
                style={[styles.serverRow, selected && styles.serverRowSelected, disabled && !selected && styles.serverRowDisabled]}
                accessibilityRole="button"
                accessibilityState={{ selected, disabled }}
                accessibilityLabel={`Подключаться к серверу ${serverLocationLabel(location)}, задержка ${selected ? currentLatencyText : locationLatencyText(location)}`}
              >
                <View style={styles.serverRowMain}>
                  <View style={styles.serverRowFlagBox}>
                    <Text style={styles.serverRowFlag}>{location.flagEmoji || location.countryCode}</Text>
                  </View>
                  <View style={styles.serverRowCopy}>
                    <Text numberOfLines={1} style={[styles.serverRowName, selected && styles.serverRowNameSelected]}>{location.city}</Text>
                    <View style={styles.serverRowStatusLine}>
                      <View style={[styles.serverHealthDot, location.healthyNodes > 0 && styles.serverHealthDotActive]} />
                      <Text numberOfLines={1} style={styles.serverRowStatus}>{locationStatusText(location)}</Text>
                    </View>
                  </View>
                </View>
                <View style={styles.serverRowSide}>
                  <Text style={[styles.serverRowLatency, selected && styles.serverRowLatencySelected]}>
                    {selected ? currentLatencyText : locationLatencyText(location)}
                  </Text>
                  {selected ? <CheckCircle2 color="#22D3EE" size={20} strokeWidth={2.7} /> : null}
                </View>
              </Pressable>
            );
          })}
        </ScrollView>
      </View>
    </Modal>
  );
}

function SubscriptionModal({
  visible,
  onClose,
}: {
  visible: boolean;
  onClose: () => void;
}) {
  return (
    <Modal animationType="slide" onRequestClose={onClose} presentationStyle="fullScreen" visible={visible}>
      <SubscriptionContent onClose={onClose} />
    </Modal>
  );
}

function deviceLatencyText(latencyMs?: number | null) {
  if (typeof latencyMs === 'number' && Number.isFinite(latencyMs)) {
    return `${Math.max(0, Math.round(latencyMs))} мс`;
  }
  return '-- мс';
}

function locationLatencyText(location: VpnLocation | undefined, liveLatencyMs?: number | null) {
  if (typeof liveLatencyMs === 'number' && Number.isFinite(liveLatencyMs)) {
    return deviceLatencyText(liveLatencyMs);
  }
  return deviceLatencyText(location?.latencyMs);
}

function availableVpnLocations(locations?: VpnLocation[]): VpnLocation[] {
  const source = locations?.length ? locations : fallbackVpnLocations;
  return source.filter((location) => location.availability !== 'retired');
}

function serverLocationLabel(location: VpnLocation): string {
  return `${location.flagEmoji ? `${location.flagEmoji} ` : ''}${location.city}`;
}

function locationStatusText(location: VpnLocation): string {
  if (location.status === 'healthy' && location.healthyNodes > 0) {
    return 'Доступен';
  }
  if (location.healthyNodes > 0) {
    return 'Доступен';
  }
  return 'Недоступен';
}

function formatBytes(value: number) {
  const safeValue = Math.max(0, value);
  if (safeValue < 1024) return `${safeValue} Б`;
  const kb = safeValue / 1024;
  if (kb < 1024) return `${kb.toFixed(kb >= 100 ? 0 : 1)} КБ`;
  const mb = kb / 1024;
  if (mb < 1024) return `${mb.toFixed(mb >= 100 ? 0 : 1)} МБ`;
  return `${(mb / 1024).toFixed(1)} ГБ`;
}

const fallbackVpnLocations: VpnLocation[] = [
  {
    id: 'de',
    countryCode: 'DE',
    city: 'Germany',
    flagEmoji: '🇩🇪',
    availability: 'available',
    status: 'healthy',
    healthyNodes: 1,
  },
  {
    id: 'fi',
    countryCode: 'FI',
    city: 'Finland',
    flagEmoji: '🇫🇮',
    availability: 'available',
    status: 'healthy',
    healthyNodes: 1,
  },
];

function subscriptionTierLabel(entitlementState: Entitlement | null): string | null {
  if (!hasPaidEntitlement(entitlementState)) {
    return null;
  }

  return planChipLabel(
    entitlementState.tier,
    entitlementState.planId,
    entitlementState.subscriptionTitle,
    entitlementState.displayName,
  );
}

function planChipLabel(...values: Array<string | undefined>): string {
  for (const value of values) {
    const normalized = normalizePlanLabel(value);
    if (normalized) {
      return normalized;
    }
  }
  return 'Active';
}

function normalizePlanLabel(value?: string): string | null {
  const raw = value?.trim();
  if (!raw) {
    return null;
  }

  const lower = raw.toLowerCase();
  if (lower.includes('team')) return 'Team';
  if (lower.includes('pro')) return 'Pro';
  if (lower.includes('basic')) return 'Basic';

  const firstToken = raw
    .replace(/аккаунт/gi, '')
    .replace(/подписка/gi, '')
    .replace(/[_-]+/g, ' ')
    .trim()
    .split(/\s+/)[0];
  if (!firstToken) {
    return null;
  }
  return firstToken.charAt(0).toUpperCase() + firstToken.slice(1);
}

function subscriptionSummaryText(entitlementState: Entitlement | null) {
  if (!entitlementState) return 'Управление доступом'
  if (entitlementState.active) return 'Доступ активен'
  return entitlementState.subscriptionSubtitle || entitlementState.accountStatus || 'Управление доступом'
}

const styles = StyleSheet.create({
  shell: {
    gap: 10,
  },
  topActions: {
    alignItems: 'center',
    flexDirection: 'row',
    gap: 8,
  },
  mainContent: {
    flex: 1,
    gap: 10,
    justifyContent: 'space-between',
  },
  centerState: {
    alignItems: 'center',
    flex: 1,
    justifyContent: 'center',
  },
  centerStateText: {
    color: '#A7B9BD',
    fontSize: 16,
    fontWeight: '700',
    marginTop: 16,
  },
  authPanel: {
    alignItems: 'stretch',
    backgroundColor: 'rgba(7,17,19,0.88)',
    borderColor: 'rgba(96,118,123,0.42)',
    borderRadius: 28,
    borderWidth: 1,
    gap: 14,
    marginTop: 32,
    padding: 20,
  },
  authIcon: {
    alignItems: 'center',
    alignSelf: 'center',
    height: 82,
    justifyContent: 'center',
    width: 82,
  },
  authLogo: {
    height: 96,
    width: 96,
  },
  authTitle: {
    color: '#F4FCFD',
    fontSize: 27,
    fontWeight: '900',
    textAlign: 'center',
  },
  authSubtitle: {
    color: '#A7B9BD',
    fontSize: 15,
    lineHeight: 21,
    textAlign: 'center',
  },
  input: {
    backgroundColor: 'rgba(2,10,11,0.78)',
    borderColor: 'rgba(96,118,123,0.46)',
    borderRadius: 18,
    borderWidth: 1,
    color: '#F4FCFD',
    fontSize: 17,
    minHeight: 56,
    paddingHorizontal: 16,
  },
  authError: {
    color: '#FF7A7A',
    fontSize: 14,
    fontWeight: '700',
    textAlign: 'center',
  },
  primaryButton: {
    alignItems: 'center',
    backgroundColor: '#22D3EE',
    borderRadius: 18,
    justifyContent: 'center',
    minHeight: 56,
  },
  primaryButtonText: {
    color: '#031012',
    fontSize: 18,
    fontWeight: '900',
  },
  modeButton: {
    alignItems: 'center',
    minHeight: 42,
    justifyContent: 'center',
  },
  modeButtonText: {
    color: '#22D3EE',
    fontSize: 15,
    fontWeight: '800',
  },
  accountCard: {
    alignItems: 'stretch',
    alignSelf: 'center',
    backgroundColor: 'rgba(8,25,29,0.82)',
    borderColor: 'rgba(126,233,245,0.18)',
    borderRadius: 24,
    borderWidth: 1,
    justifyContent: 'center',
    maxWidth: maxContentWidth,
    minHeight: 72,
    paddingHorizontal: 12,
    paddingVertical: 10,
    shadowColor: '#22D3EE',
    shadowOpacity: 0.16,
    shadowRadius: 22,
    width: '100%',
  },
  accountHeader: {
    alignItems: 'center',
    flexDirection: 'row',
    gap: 10,
    minHeight: 50,
  },
  userBadge: {
    alignItems: 'center',
    backgroundColor: 'rgba(34,211,238,0.13)',
    borderColor: 'rgba(34,211,238,0.2)',
    borderRadius: 17,
    borderWidth: 1,
    height: 48,
    justifyContent: 'center',
    width: 48,
  },
  accountCopy: {
    flex: 1,
    minWidth: 0,
  },
  accountEmail: {
    color: '#EAF7F8',
    fontSize: 14,
    fontWeight: '900',
  },
  accountMeta: {
    color: '#B6CACE',
    fontSize: 13,
    fontWeight: '800',
    minWidth: 0,
  },
  accountStatusRow: {
    alignItems: 'center',
    flexDirection: 'row',
    gap: 6,
    marginTop: 2,
    minWidth: 0,
  },
  accountStatusDot: {
    backgroundColor: '#78969C',
    borderRadius: 5,
    height: 10,
    width: 10,
  },
  accountStatusDotActive: {
    backgroundColor: '#22D3EE',
  },
  accountActionWrap: {
    alignItems: 'center',
    flexDirection: 'row',
    gap: 2,
    justifyContent: 'center',
    minHeight: 46,
    minWidth: 88,
  },
  accountAction: {
    color: '#22D3EE',
    fontSize: 14,
    fontWeight: '900',
  },
  hero: {
    alignItems: 'center',
    flex: 1,
    minHeight: 292,
    justifyContent: 'center',
    overflow: 'visible',
  },
  heroBackdrop: {
    alignItems: 'center',
    height: 292,
    justifyContent: 'center',
    opacity: 0.34,
    position: 'absolute',
    width: '100%',
  },
  heroNode: {
    backgroundColor: '#22D3EE',
    borderColor: 'rgba(185,251,255,0.5)',
    borderRadius: 5,
    borderWidth: 1,
    height: 10,
    position: 'absolute',
    shadowColor: '#22D3EE',
    shadowOpacity: 0.7,
    shadowRadius: 10,
    width: 10,
  },
  heroNodeTopLeft: {
    left: 28,
    top: 54,
  },
  heroNodeTopRight: {
    right: 42,
    top: 36,
  },
  heroLink: {
    backgroundColor: 'rgba(34,211,238,0.22)',
    height: 1,
    position: 'absolute',
    width: 168,
  },
  heroLinkOne: {
    left: 26,
    top: 86,
    transform: [{ rotate: '24deg' }],
  },
  heroGlow: {
    backgroundColor: 'rgba(34,211,238,0.16)',
    borderRadius: 124,
    height: 222,
    position: 'absolute',
    shadowColor: '#22D3EE',
    shadowOpacity: 0.74,
    shadowRadius: 28,
    width: 222,
  },
  heroRing: {
    borderColor: 'rgba(34,211,238,0.34)',
    borderRadius: 122,
    borderWidth: 1,
    height: 228,
    position: 'absolute',
    width: 228,
  },
  heroRingOuter: {
    borderColor: 'rgba(185,251,255,0.08)',
    borderRadius: 134,
    borderWidth: 6,
    height: 242,
    position: 'absolute',
    width: 242,
  },
  powerButtonFrame: {
    alignItems: 'center',
    backgroundColor: 'rgba(3,17,20,0.94)',
    borderColor: '#35E6F4',
    borderRadius: 104,
    borderWidth: 7,
    height: 204,
    justifyContent: 'center',
    shadowColor: '#22D3EE',
    shadowOpacity: 0.94,
    shadowRadius: 24,
    width: 204,
  },
  powerButtonFrameActive: {
    backgroundColor: 'rgba(4,24,27,0.96)',
    borderColor: '#35E6F4',
    shadowColor: '#22D3EE',
  },
  powerButtonBusy: {
    opacity: 0.72,
  },
  powerButton: {
    alignItems: 'center',
    borderRadius: 102,
    height: '100%',
    justifyContent: 'center',
    overflow: 'hidden',
    width: '100%',
  },
  powerOrbit: {
    borderColor: 'transparent',
    borderBottomColor: 'rgba(34,211,238,0.22)',
    borderRadius: 89,
    borderRightColor: 'rgba(34,211,238,0.2)',
    borderTopColor: '#B9FBFF',
    borderWidth: 4,
    height: 174,
    position: 'absolute',
    width: 174,
  },
  powerText: {
    color: '#F4FCFD',
    fontSize: 21,
    fontWeight: '900',
    lineHeight: 28,
    maxWidth: 176,
    minWidth: 0,
    textAlign: 'center',
  },
  powerSubtext: {
    color: '#A8D8DE',
    fontSize: 15,
    fontWeight: '800',
    marginTop: 8,
    textAlign: 'center',
  },
  protocolSpacer: {
    alignSelf: 'center',
    minHeight: 2,
  },
  serverChip: {
    alignItems: 'center',
    alignSelf: 'center',
    backgroundColor: 'rgba(8,25,29,0.84)',
    borderColor: 'rgba(126,233,245,0.2)',
    borderRadius: 24,
    borderWidth: 1,
    flexDirection: 'row',
    gap: 10,
    maxWidth: maxContentWidth,
    minHeight: 76,
    paddingHorizontal: 12,
    shadowColor: '#22D3EE',
    shadowOpacity: 0.14,
    shadowRadius: 20,
    width: '100%',
  },
  serverChipDisabled: {
    opacity: 0.72,
  },
  serverChipIcon: {
    alignItems: 'center',
    backgroundColor: 'rgba(34,211,238,0.13)',
    borderColor: 'rgba(34,211,238,0.2)',
    borderRadius: 17,
    borderWidth: 1,
    height: 44,
    justifyContent: 'center',
    width: 44,
  },
  serverChipCopy: {
    flex: 1,
    minWidth: 0,
  },
  serverChipCaption: {
    color: '#8FBEC6',
    fontSize: 12,
    fontWeight: '900',
    textTransform: 'uppercase',
  },
  serverChipLabel: {
    color: '#EAF7F8',
    fontSize: 18,
    fontWeight: '900',
    marginTop: 4,
    minWidth: 0,
  },
  serverLatencyPill: {
    alignItems: 'center',
    backgroundColor: 'rgba(34,211,238,0.11)',
    borderColor: 'rgba(34,211,238,0.44)',
    flexDirection: 'row',
    gap: 6,
    borderRadius: 999,
    borderWidth: 1,
    justifyContent: 'center',
    minWidth: 68,
    paddingHorizontal: 8,
    paddingVertical: 7,
  },
  serverLatencyText: {
    color: '#B9FBFF',
    fontSize: 15,
    fontWeight: '900',
  },
  trafficStats: {
    alignItems: 'center',
    alignSelf: 'center',
    backgroundColor: 'rgba(8,25,29,0.76)',
    borderColor: 'rgba(126,233,245,0.18)',
    borderRadius: 22,
    borderWidth: 1,
    flexDirection: 'row',
    maxWidth: maxContentWidth,
    minHeight: 82,
    paddingHorizontal: 18,
    shadowColor: '#22D3EE',
    shadowOpacity: 0.1,
    shadowRadius: 18,
    width: '100%',
  },
  trafficItem: {
    flex: 1,
    minWidth: 0,
  },
  trafficLabel: {
    color: '#8FBEC6',
    fontSize: 13,
    fontWeight: '900',
    textTransform: 'uppercase',
  },
  trafficValueRow: {
    alignItems: 'center',
    flexDirection: 'row',
    gap: 10,
    marginTop: 8,
  },
  trafficValue: {
    color: '#F4FCFD',
    fontSize: 24,
    fontWeight: '900',
  },
  trafficDirectionBadge: {
    alignItems: 'center',
    backgroundColor: 'rgba(34,211,238,0.12)',
    borderRadius: 12,
    height: 24,
    justifyContent: 'center',
    width: 24,
  },
  trafficDivider: {
    backgroundColor: 'rgba(126,233,245,0.2)',
    height: 48,
    marginHorizontal: 18,
    width: 1,
  },
  serverModal: {
    backgroundColor: '#020A0B',
    flex: 1,
    paddingHorizontal: 12,
    paddingTop: Platform.OS === 'android' ? 34 : 46,
  },
  serverModalHeader: {
    alignItems: 'center',
    flexDirection: 'row',
    justifyContent: 'space-between',
    marginBottom: 10,
  },
  serverModalEyebrow: {
    color: '#22D3EE',
    fontSize: 12,
    fontWeight: '900',
    letterSpacing: 0,
    marginBottom: 4,
  },
  serverModalTitle: {
    color: '#F4FCFD',
    fontSize: 20,
    fontWeight: '900',
  },
  serverModalSubtitle: {
    color: '#8FBEC6',
    fontSize: 11,
    fontWeight: '700',
    lineHeight: 15,
    marginTop: 4,
    maxWidth: 240,
  },
  serverModalClose: {
    alignItems: 'center',
    backgroundColor: 'rgba(255,255,255,0.06)',
    borderColor: 'rgba(255,255,255,0.1)',
    borderRadius: 14,
    borderWidth: 1,
    height: 40,
    justifyContent: 'center',
    width: 40,
  },
  serverModalList: {
    gap: 7,
    paddingBottom: 18,
  },
  serverRow: {
    alignItems: 'center',
    backgroundColor: 'rgba(7,17,19,0.84)',
    borderColor: 'rgba(96,118,123,0.3)',
    borderRadius: 14,
    borderWidth: 1,
    flexDirection: 'row',
    gap: 8,
    justifyContent: 'space-between',
    minHeight: 56,
    paddingHorizontal: 10,
  },
  serverRowSelected: {
    backgroundColor: 'rgba(34,211,238,0.14)',
    borderColor: '#22D3EE',
  },
  serverRowDisabled: {
    opacity: 0.62,
  },
  serverRowMain: {
    alignItems: 'center',
    flex: 1,
    flexDirection: 'row',
    gap: 8,
    minWidth: 0,
  },
  serverRowFlag: {
    fontSize: 20,
    textAlign: 'center',
  },
  serverRowFlagBox: {
    alignItems: 'center',
    backgroundColor: 'rgba(2,10,11,0.56)',
    borderRadius: 12,
    height: 34,
    justifyContent: 'center',
    width: 34,
  },
  serverRowCopy: {
    flex: 1,
    minWidth: 0,
  },
  serverRowName: {
    color: '#CFE4E8',
    fontSize: 15,
    fontWeight: '900',
  },
  serverRowNameSelected: {
    color: '#F4FCFD',
  },
  serverRowStatus: {
    color: '#8FBEC6',
    fontSize: 12,
    fontWeight: '700',
  },
  serverRowStatusLine: {
    alignItems: 'center',
    flexDirection: 'row',
    gap: 6,
    marginTop: 4,
    minWidth: 0,
  },
  serverHealthDot: {
    backgroundColor: '#78969C',
    borderRadius: 4,
    height: 8,
    width: 8,
  },
  serverHealthDotActive: {
    backgroundColor: '#22D3EE',
  },
  serverRowLatency: {
    color: '#A7B9BD',
    fontSize: 13,
    fontWeight: '900',
    textAlign: 'right',
  },
  serverRowSide: {
    alignItems: 'center',
    flexDirection: 'row',
    gap: 6,
    minWidth: 76,
    justifyContent: 'flex-end',
  },
  serverRowLatencySelected: {
    color: '#B9FBFF',
  },
  serverModalHint: {
    color: '#8FBEC6',
    fontSize: 13,
    fontWeight: '700',
    lineHeight: 18,
    paddingBottom: 18,
    textAlign: 'center',
  },
  vpnErrorText: {
    alignSelf: 'center',
    color: '#FF9F9F',
    fontSize: 12,
    fontWeight: '700',
    maxWidth: maxContentWidth - 32,
    textAlign: 'center',
  },
  vpnNoticeText: {
    alignSelf: 'center',
    color: '#F8D477',
    fontSize: 12,
    fontWeight: '700',
    maxWidth: maxContentWidth - 32,
    textAlign: 'center',
  },
  rotationNotice: {
    alignSelf: 'center',
    borderRadius: 14,
    paddingHorizontal: 10,
    paddingVertical: 4,
  },
});
