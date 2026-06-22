import { useCallback } from 'react';

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
  connectableLocalProfile,
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
  type VpnStatus,
} from '@/native/vexVpn';
import {
  setSelectedVpnLocation,
} from '@/settings/vpnPreferences';
import {
  chooseBestVpnLocation,
  type ServerSelectionMode,
} from '@/vpn/serverSelection';
import { uploadClientDiagnostics } from '@/diagnostics/clientDiagnostics';
import type { VpnLocation } from '@/api/vexApi';
import type { VpnProfile } from '@/vpn/profile';

type UseVpnConnectionFlowInput = {
  antiLeakEnabled: boolean;
  selectedLocationId: string;
  serverSelectionMode: ServerSelectionMode;
  availableLocations: VpnLocation[];
  activeProfile: VpnProfile | null;
  entitlementState: any;
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
}: UseVpnConnectionFlowInput) {

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
    activeProfile,
    availableLocations,
    cacheProfile,
    clientLatencyMs,
    connectProfileWithEndpointFallback,
    entitlementState,
    reportVpnConnectEvent,
    requestVpnPermission,
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
