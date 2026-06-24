import { useCallback, useEffect, useRef } from 'react';
import { errorMessage } from '@/utils/error';

import type { VpnDeviceUsage, VpnLocation } from '../api/vexApi';
import type { VpnStatus } from '../native/vexVpn';
import { recoverVpnConnection, type RecoverVpnConnectionInput } from './connectionRecovery';
import { assessNativeTunnelHealth, localStatusHealthReasons } from './nativeTunnelHealth';
import type { VpnProfile } from './profile';
import { assessVpnAutopilotIssue, type VpnAutopilotProbeResult } from './vpnAutopilotAssessment';

type MutableBooleanRef = {
  current: boolean;
};

type NativeVpnWatchdogInput = {
  activeDeviceId?: string;
  activeLocationId: string;
  activeProfile: VpnProfile | null;
  availableLocations: VpnLocation[];
  connectProfile: RecoverVpnConnectionInput['connectProfile'];
  enabled: boolean;
  failureThreshold: number;
  fetchDeviceUsage: (accessToken: string) => Promise<VpnDeviceUsage[]>;
  isRetryableConnectError: RecoverVpnConnectionInput['isRetryableConnectError'];
  isVpnBusy: boolean;
  onRecoveryFailed: (message: string) => void;
  onRecoveryStarted?: (message: string) => void;
  onRecoverySucceeded: (profile: VpnProfile, status: VpnStatus, locationId: string) => void;
  operationInFlightRef: MutableBooleanRef;
  persistLocation: RecoverVpnConnectionInput['persistLocation'];
  probeHealth?: (profile: VpnProfile) => Promise<VpnAutopilotProbeResult>;
  pollMs: number;
  reconnectCooldownMs: number;
  reportConnect: (profile: VpnProfile) => void;
  resolveProfile: RecoverVpnConnectionInput['resolveProfile'];
  rotateProfile?: RecoverVpnConnectionInput['rotateProfile'];
  serverSelectionMode?: string;
  sessionAccessToken?: string;
  setCachedProfile: RecoverVpnConnectionInput['setCachedProfile'];
  staleHandshakeSeconds: number;
  submitDiagnostics: (reason: string, status: string, samples?: Record<string, unknown>) => Promise<void>;
};

type NativeVpnWatchdog = {
  recordNativeStatus: (currentStatus: VpnStatus, nextStatus: VpnStatus) => boolean;
};

export function useNativeVpnWatchdog(input: NativeVpnWatchdogInput): NativeVpnWatchdog {
  const backendHealthFailuresRef = useRef(0);
  const localHealthFailuresRef = useRef(0);
  const lastLocalDegradedStatusRef = useRef<VpnStatus | null>(null);
  const reconnectInFlightRef = useRef(false);
  const lastReconnectAtRef = useRef(0);

  const recordNativeStatus = useCallback((currentStatus: VpnStatus, nextStatus: VpnStatus) => {
    const localHealthReasons = currentStatus.state === 'connected'
      ? localStatusHealthReasons(nextStatus, Date.now(), input.staleHandshakeSeconds)
      : [];
    if (localHealthReasons.length > 0) {
      localHealthFailuresRef.current += 1;
      lastLocalDegradedStatusRef.current = nextStatus;
      return true;
    }
    localHealthFailuresRef.current = 0;
    lastLocalDegradedStatusRef.current = null;
    return false;
  }, [input.staleHandshakeSeconds]);

  useEffect(() => {
    const accessToken = input.sessionAccessToken;
    const activeDeviceId = input.activeDeviceId;
    const activeProfile = input.activeProfile;

    if (!input.enabled || !accessToken || !activeProfile || !activeDeviceId) {
      resetHealthFailures();
      return undefined;
    }

    let disposed = false;
    const checkNativeTunnelHealth = async () => {
      if (disposed || reconnectInFlightRef.current || input.isVpnBusy || input.operationInFlightRef.current) {
        return;
      }

      try {
        let activeUsage: VpnDeviceUsage | undefined;
        let usageError: string | undefined;
        try {
          const usageRows = await input.fetchDeviceUsage(accessToken);
          activeUsage = usageRows.find((usage) => usage.deviceId === activeDeviceId);
        } catch (error) {
          usageError = errorMessage(error, 'usage_check_failed');
        }

        const localStatus = lastLocalDegradedStatusRef.current ?? undefined;
        const health = assessNativeTunnelHealth({
          deviceUsage: activeUsage,
          nowMs: Date.now(),
          staleHandshakeSeconds: input.staleHandshakeSeconds,
          status: localStatus,
        });
        backendHealthFailuresRef.current = health.healthy ? 0 : backendHealthFailuresRef.current + 1;

        const healthFailureCount = Math.max(backendHealthFailuresRef.current, localHealthFailuresRef.current);
        const cooldownElapsed = Date.now() - lastReconnectAtRef.current > input.reconnectCooldownMs;
        if (healthFailureCount < input.failureThreshold || !cooldownElapsed) {
          return;
        }
        const probe = await input.probeHealth?.(activeProfile).catch((error): VpnAutopilotProbeResult => ({
          endpointProbeError: errorMessage(error, 'network_probe_failed'),
        }));
        const assessment = assessVpnAutopilotIssue({
          healthReasons: health.reasons,
          localStatus,
          probe,
          usageError,
        });

        reconnectInFlightRef.current = true;
        lastReconnectAtRef.current = Date.now();
        resetHealthFailures();
        input.onRecoveryStarted?.('Восстанавливаем VPN');
        await input.submitDiagnostics('native_watchdog_reconnect', 'degraded', {
          ...assessment.sample,
          active_usage: activeUsage,
          local_status: localStatus,
          native_health_failures: healthFailureCount,
          native_health_reasons: health.reasons,
          reconnect_cooldown_ms: input.reconnectCooldownMs,
          selection_mode: input.serverSelectionMode,
          stale_handshake_seconds: input.staleHandshakeSeconds,
          usage_error: usageError,
        }).catch(() => undefined);

        const recovery = await recoverVpnConnection({
          activeLocationId: input.activeLocationId,
          activeProfile,
          availableLocations: input.availableLocations,
          connectProfile: input.connectProfile,
          isRetryableConnectError: input.isRetryableConnectError,
          persistLocation: input.persistLocation,
          resolveProfile: input.resolveProfile,
          rotateProfile: input.rotateProfile,
          setCachedProfile: input.setCachedProfile,
        });
        if (disposed) {
          return;
        }
        if (recovery.ok) {
          input.onRecoverySucceeded(recovery.profile, recovery.status, recovery.locationId);
          input.reportConnect(recovery.profile);
          void input.submitDiagnostics('native_watchdog_reconnect_result', 'ok', {
            ...assessment.sample,
            previous_location_id: recovery.previousLocationId,
            next_location_id: recovery.locationId,
            failover_reason: recovery.outcome === 'failover_location' ? assessment.cause : undefined,
            recovery_result: recovery.outcome === 'failover_location' ? 'failover_location' : 'same_location',
            recovery_outcome: recovery.outcome,
            selection_mode: input.serverSelectionMode,
          }).catch(() => undefined);
          return;
        }

        input.onRecoveryFailed(assessment.userMessage);
        await input.submitDiagnostics('native_watchdog_reconnect_result', 'failed', {
          ...assessment.sample,
          previous_location_id: recovery.previousLocationId,
          next_location_id: recovery.locationId,
          recovery_error: errorMessage(recovery.error, 'unknown'),
          recovery_result: 'failed',
          selection_mode: input.serverSelectionMode,
        }).catch(() => undefined);
      } catch (error) {
        await input.submitDiagnostics('native_watchdog_check_failed', 'error', {
          watchdog_error: errorMessage(error, 'native_watchdog_check_failed'),
        }).catch(() => undefined);
        backendHealthFailuresRef.current = 0;
      } finally {
        reconnectInFlightRef.current = false;
      }
    };

    void checkNativeTunnelHealth();
    const timer = setInterval(() => {
      void checkNativeTunnelHealth();
    }, input.pollMs);

    return () => {
      disposed = true;
      clearInterval(timer);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [
    input.activeDeviceId,
    input.activeLocationId,
    input.activeProfile,
    input.availableLocations,
    input.connectProfile,
    input.enabled,
    input.failureThreshold,
    input.fetchDeviceUsage,
    input.isRetryableConnectError,
    input.isVpnBusy,
    input.onRecoveryFailed,
    input.onRecoveryStarted,
    input.onRecoverySucceeded,
    input.operationInFlightRef,
    input.persistLocation,
    input.probeHealth,
    input.pollMs,
    input.reconnectCooldownMs,
    input.reportConnect,
    input.resolveProfile,
    input.rotateProfile,
    input.serverSelectionMode,
    input.sessionAccessToken,
    input.setCachedProfile,
    input.staleHandshakeSeconds,
    input.submitDiagnostics,
  ]);

  function resetHealthFailures() {
    backendHealthFailuresRef.current = 0;
    localHealthFailuresRef.current = 0;
    lastLocalDegradedStatusRef.current = null;
  }

  return { recordNativeStatus };
}
