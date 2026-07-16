import { useCallback } from 'react';
import { Platform } from 'react-native';

import {
  saveHotVpnProfile,
  withLastSuccessfulEndpoint,
} from '@/vpn/hotProfileCache';
import {
  connectionAttemptsForProfile,
  isVpnTransportFallbackError,
  profileEndpoint,
} from '@/vpn/connectionFallback';
import {
  explicitConnectProfileResolutionOptions,
  vpnConnectTimingSamples,
} from '@/vpn/connectFlow';
import {
  connectAttemptTimeoutMs,
  type ConnectedVpnAttempt,
  errorMessage,
  withTimeout,
} from '@/screens/home-screen-helpers';
import {
  connectVpn,
  disconnectVpn,
  getVpnStatus,
  type VpnStatus,
} from '@/native/vexVpn';
import { waitForVerifiedVpnConnection } from '@/vpn/connectVerification';
import { cleanupFailedVpnConnection } from '@/vpn/failedConnectionCleanup';
import { profileResolutionOrder } from '@/vpn/profileResolutionFallback';
import { androidVpnProfileWithinBinderBudget } from '@/vpn/androidRoutingSafety';
import { vpnProfileAddressMatchesDevice } from '@/vpn/profileConsistency';
import {
  getVpnApplicationSelection,
  setSelectedVpnLocation,
} from '@/settings/vpnPreferences';
import {
  chooseBestVpnLocation,
  type ServerSelectionMode,
} from '@/vpn/serverSelection';
import { uploadClientDiagnostics } from '@/diagnostics/clientDiagnostics';
import type { VpnLocation } from '@/api/vexApi';
import type { VpnProfile } from '@/vpn/profile';
import type { VpnRoutingMode } from '@/vpn/routingPolicy';

type UseVpnConnectionFlowInput = {
  antiLeakEnabled: boolean;
  routingMode: VpnRoutingMode;
  selectedLocationId: string;
  serverSelectionMode: ServerSelectionMode;
  availableLocations: VpnLocation[];
  requestVpnPermission: () => Promise<boolean>;
  cacheProfile: (locationId: string, profile: VpnProfile) => void;
  resolveConnectableVpnProfile: (
    locationId: string,
    options?: {
      preferCached?: boolean;
      forceRefresh?: boolean;
      requestPermission?: boolean;
    }
  ) => Promise<VpnProfile>;
  vpnStatus: VpnStatus;
  clientLatencyMs: number | null;
  reportVpnConnectEvent: (profile: VpnProfile, reason: string) => void;
  setSelectedLocationId: (locationId: string) => void;
  setActiveProfile: (profile: VpnProfile | null) => void;
  setVpnStatus: React.Dispatch<React.SetStateAction<VpnStatus>>;
  session: { accessToken: string; user: { id: string } } | null;
};

export function useVpnConnectionFlow({
  antiLeakEnabled,
  routingMode,
  selectedLocationId,
  serverSelectionMode,
  availableLocations,
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
}: UseVpnConnectionFlowInput) {

  const connectProfileWithEndpointFallback = useCallback(async (profile: VpnProfile) => {
    if (!vpnProfileAddressMatchesDevice(profile)) {
      throw new Error('VPN connection failed: cached profile address does not match its device assignment.');
    }
    if (!androidVpnProfileWithinBinderBudget(Platform.OS, profile.config)) {
      throw new Error('Android VPN profile exceeds the safe route limit. Refresh the profile before connecting.');
    }
    let lastError: unknown;
    const endpointAttempts: string[] = [];
    const applicationSelection = await getVpnApplicationSelection();
    for (const attempt of connectionAttemptsForProfile(profile)) {
      try {
        const endpoint = profileEndpoint(attempt);
        if (endpoint) {
          endpointAttempts.push(endpoint);
        }
        const nativeStartMs = Date.now();
        const startedStatus = await withTimeout(
          connectVpn(attempt.config, {
            antiLeakEnabled,
            applicationRoutingMode: applicationSelection.mode,
            selectedApplications: applicationSelection.packageNames,
          }),
          connectAttemptTimeoutMs,
          'VPN connect timed out.',
        );
        const status = await waitForVerifiedVpnConnection(startedStatus, getVpnStatus, {
          // The native backend can briefly expose the previous peer timestamp
          // while replacing a tunnel. Require activity from this attempt. The
          // small tolerance covers second-resolution backend timestamps.
          minimumHandshakeEpochMillis: nativeStartMs - 2_000,
        });
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
    let profile: VpnProfile | null = null;
    let profileLocationId = initialLocationId;
    let lastProfileError: unknown;
    for (const candidate of profileResolutionOrder(initialLocationId, availableLocations)) {
      try {
        // A cached managed profile can outlive its server-side device. Using it
        // before validation makes Android report a connected TUN even after the
        // peer has been revoked, which fail-closes all user traffic. An explicit
        // connect must therefore resolve an authoritative profile first.
        profile = await resolveConnectableVpnProfile(candidate.id, explicitConnectProfileResolutionOptions);
        profileLocationId = candidate.id;
        break;
      } catch (error) {
        lastProfileError = error;
      }
    }
    if (!profile) {
      throw lastProfileError ?? new Error('VPN-профиль недоступен.');
    }
    if (!androidVpnProfileWithinBinderBudget(Platform.OS, profile.config)) {
      throw new Error('Android VPN profile exceeds the safe route limit. Refresh the profile before connecting.');
    }
    let connected: ConnectedVpnAttempt | null = null;
    let connectedLocationId = profileLocationId;
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
      if (connected?.status.state === 'connected' || fallbackLocation.id === profileLocationId) {
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
      await cleanupFailedVpnConnection(antiLeakEnabled, disconnectVpn).catch(() => undefined);
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
    antiLeakEnabled,
    availableLocations,
    cacheProfile,
    clientLatencyMs,
    connectProfileWithEndpointFallback,
    reportVpnConnectEvent,
    resolveConnectableVpnProfile,
    selectedLocationId,
    setSelectedLocationId,
    serverSelectionMode,
    session,
    setActiveProfile,
    setVpnStatus,
    vpnStatus,
  ]);

  return {
    connectProfileWithEndpointFallback,
    connectCurrentVpn,
  };
}
