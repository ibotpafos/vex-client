import { useCallback, useEffect, useRef } from 'react';

import {
  hasPaidEntitlement,
  reportVpnConnect,
  reportVpnDisconnect,
  vpnDeviceUsage,
  type VpnDeviceUsage,
} from '@/api/vexApi';
import { uploadClientDiagnostics } from '@/diagnostics/clientDiagnostics';
import type { VpnStatus } from '@/native/vexVpn';
import type { VpnProfile } from '@/vpn/profile';
import {
  clientDiagnosticsErrorCooldownMs,
  type ConnectionPhase,
  type DiagnosticsSnapshotRef,
  errorMessage,
  isAuthenticationError,
} from '@/screens/home-screen-helpers';

type UseVpnDiagnosticsInput = {
  session: { accessToken: string; user: { id: string } } | null;
  activeProfileDeviceId: string | undefined;
  connectionPhase: ConnectionPhase;
  clientLatencyMs: number | null;
  vpnStatus: VpnStatus;
  diagnosticsSnapshotRef: React.RefObject<DiagnosticsSnapshotRef>;
  entitlementQueryError: unknown;
  cachedEntitlement: any;
  refreshSession: () => Promise<any>;
  handleSignOut: () => Promise<void>;
};

export function useVpnDiagnostics({
  session,
  activeProfileDeviceId,
  connectionPhase,
  clientLatencyMs,
  vpnStatus,
  diagnosticsSnapshotRef,
  entitlementQueryError,
  cachedEntitlement,
  refreshSession,
  handleSignOut,
}: UseVpnDiagnosticsInput) {
  const lastClientDiagnosticsAtRef = useRef<Record<string, number>>({});
  const lastEntitlementDiagnosticsRef = useRef('');

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

  const submitVpnDiagnostics = useCallback(async (reason: string, status: string, samples: Record<string, unknown> = {}) => {
    if (!session?.accessToken || !activeProfileDeviceId) {
      return;
    }
    const latest = diagnosticsSnapshotRef.current;
    if (!latest) {
      return;
    }
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
  }, [activeProfileDeviceId, connectionPhase, diagnosticsSnapshotRef, session?.accessToken]);

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
    if (!latest) {
      return;
    }
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
  }, [activeProfileDeviceId, connectionPhase, diagnosticsSnapshotRef, session?.accessToken]);

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
    if (!entitlementQueryError) {
      return;
    }
    const message = errorMessage(entitlementQueryError, '');
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
    entitlementQueryError,
    handleSignOut,
    refreshSession,
    session?.accessToken,
    vpnStatus,
  ]);

  return {
    submitVpnDiagnostics,
    submitClientDiagnosticsEvent,
    reportVpnConnectEvent,
    reportVpnDisconnectEvent,
    handleProfileRefreshFailed,
  };
}
