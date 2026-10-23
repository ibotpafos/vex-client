import { useCallback, useEffect, useRef } from 'react';
import { Platform } from 'react-native';
import { errorMessage } from '@/utils/error';

import type { ClientConnectionTelemetryInput, VpnDeviceUsage, VpnLocation } from '../api/vexApi';
import type { VpnStatus } from '../native/vexVpn';
import { recoverVpnConnection, type RecoverVpnConnectionInput } from './connectionRecovery';
import { assessNativeTunnelHealth, localStatusHealthReasons } from './nativeTunnelHealth';
import type { VpnProfile } from './profile';
import { assessVpnAutopilotIssue, type VpnAutopilotProbeResult } from './vpnAutopilotAssessment';
import { vpnTransportTelemetry, vpnUnexpectedDisconnectTelemetry } from './connectFlow';
import {
  initialRecoveryBackoffState,
  recoveryAttemptAllowed,
  recordRecoveryFailure,
  resetRecoveryBackoff,
} from './recoveryBackoff';
import { dynamicRouteRuntime } from './dynamicRouteRuntime';
import { routeTransport } from './dynamicRouteCore';

const recoveryCircuitFailureThreshold = 3;
const recoveryCircuitOpenMultiplier = 20;
const recoveryMaxBackoffMultiplier = 8;
const recoveryJitterRatio = 0.2;

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
  isCurrentSessionOperation?: () => boolean;
  beginRecoveryOperation?: () => () => boolean;
  protectFailedRecovery?: () => Promise<unknown>;
  isCurrentLocation?: (locationId: string) => boolean;
  onRecoveryFailed: (message: string) => void;
  onRecoveryStarted?: (message: string) => void;
  onRecoverySucceeded: (profile: VpnProfile, status: VpnStatus, locationId: string) => void;
  onHealthRecovered?: (previousMessage: string) => void;
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
  submitDiagnostics: (
    reason: string,
    status: string,
    samples?: Record<string, unknown>,
    telemetry?: Partial<ClientConnectionTelemetryInput>,
  ) => Promise<void>;
};

type NativeVpnWatchdog = {
  recordNativeStatus: (currentStatus: VpnStatus, nextStatus: VpnStatus) => boolean;
};

export function useNativeVpnWatchdog(input: NativeVpnWatchdogInput): NativeVpnWatchdog {
  const latestInputRef = useRef(input);
  latestInputRef.current = input;
  const activeProfileForStatus = input.activeProfile;
  const staleHandshakeSecondsForStatus = input.staleHandshakeSeconds;
  // Telemetry phase changes must not dispose the recovery that reported them.
  const telemetryRef = useRef({ submitDiagnostics: input.submitDiagnostics, reportConnect: input.reportConnect });
  telemetryRef.current = { submitDiagnostics: input.submitDiagnostics, reportConnect: input.reportConnect };
  const submitDiagnostics = useCallback((...args: Parameters<NativeVpnWatchdogInput['submitDiagnostics']>) =>
    telemetryRef.current.submitDiagnostics(...args), []);
  const reportConnect = useCallback((profile: VpnProfile) => telemetryRef.current.reportConnect(profile), []);
  const submitStatusDiagnostics = submitDiagnostics;
  const backendHealthFailuresRef = useRef(0);
  const localHealthFailuresRef = useRef(0);
  const lastLocalDegradedStatusRef = useRef<VpnStatus | null>(null);
  const lastLocalStatusRef = useRef<{status: VpnStatus; deviceId?: string; locationId?: string; profileVersion?: number} | null>(null);
  const reconnectInFlightRef = useRef(false);
  const lastReconnectAtRef = useRef(0);
  const recoveryBackoffRef = useRef(initialRecoveryBackoffState());
  const connectedAtRef = useRef<number | null>(null);
  const lastRecoveryFailureRef = useRef<{ message: string; deviceId: string; locationId: string;
    profileVersion?: number; accessToken: string } | null>(null);

  const recordNativeStatus = useCallback((currentStatus: VpnStatus, nextStatus: VpnStatus) => {
    lastLocalStatusRef.current = {status: nextStatus, deviceId: activeProfileForStatus?.device?.id, locationId: activeProfileForStatus?.locationId, profileVersion: activeProfileForStatus?.profileVersion};
    const nowMs = Date.now();
    if (nextStatus.state === 'connected' && connectedAtRef.current === null) {
      connectedAtRef.current = nowMs;
    }
    if (activeProfileForStatus && connectedAtRef.current !== null) {
      const telemetry = vpnUnexpectedDisconnectTelemetry({
        connectedAtMs: connectedAtRef.current,
        nextState: nextStatus.state,
        nowMs,
        profile: activeProfileForStatus,
        previousState: currentStatus.state,
      });
      if (telemetry) {
        connectedAtRef.current = null;
        const failedRoute = Platform.OS === 'android'
          ? dynamicRouteRuntime.recordActiveFailure(activeProfileForStatus)
          : null;
        void submitStatusDiagnostics('native_unexpected_disconnect', 'degraded', {
          previous_state: currentStatus.state,
          next_state: nextStatus.state,
        }, failedRoute ? {
          connectionEvent: 'unexpected_disconnect',
          transportFrom: routeTransport(failedRoute),
        } : telemetry).catch(() => undefined);
      }
    }
    const localHealthReasons = currentStatus.state === 'connected'
      ? localStatusHealthReasons(nextStatus, nowMs, staleHandshakeSecondsForStatus)
      : [];
    if (localHealthReasons.length > 0) {
      localHealthFailuresRef.current += 1;
      lastLocalDegradedStatusRef.current = nextStatus;
      return true;
    }
    localHealthFailuresRef.current = 0;
    lastLocalDegradedStatusRef.current = null;
    return false;
  }, [activeProfileForStatus, staleHandshakeSecondsForStatus, submitStatusDiagnostics]);

  useEffect(() => {
    const accessToken = input.sessionAccessToken;
    const activeDeviceId = input.activeDeviceId;
    const activeProfile = input.activeProfile;

    if (!input.enabled || !accessToken || !activeProfile || !activeDeviceId) {
      resetHealthFailures();
      return undefined;
    }

    let disposed = false;
    const isCurrent = () => !disposed && !latestInputRef.current.isVpnBusy &&
      input.isCurrentSessionOperation?.() !== false &&
      activeProfile.locationId === input.activeLocationId &&
      input.isCurrentLocation?.(input.activeLocationId) !== false;
    const checkNativeTunnelHealth = async () => {
      const input = latestInputRef.current;
      const activeProfile = input.activeProfile;
      const activeDeviceId = input.activeDeviceId;
      const accessToken = input.sessionAccessToken;
      if (!activeProfile || !activeDeviceId || !accessToken) return;
      if (!isCurrent() || reconnectInFlightRef.current || input.operationInFlightRef.current) {
        return;
      }

      // Serialize health checks as well as recovery; an older check must not
      // clear the lease of a newer check while its network requests are pending.
      reconnectInFlightRef.current = true;
      let ownsOperation = false;
      let acceptedRecovery = false;
      let recoveryOwnerIsCurrent: (() => boolean) | undefined;
      const recoveryIsCurrent = () => recoveryOwnerIsCurrent?.() !== false &&
        input.isCurrentSessionOperation?.() !== false &&
        latestInputRef.current.activeLocationId === input.activeLocationId &&
        latestInputRef.current.activeDeviceId === activeDeviceId && !latestInputRef.current.isVpnBusy;
      try {
        let activeUsage: VpnDeviceUsage | undefined;
        let usageError: string | undefined;
        try {
          const usageRows = localHealthFailuresRef.current >= input.failureThreshold
            ? []
            : await input.fetchDeviceUsage(accessToken);
          activeUsage = usageRows.find((usage) => usage.deviceId === activeDeviceId);
        } catch (error) {
          usageError = errorMessage(error, 'usage_check_failed');
        }

        if (!isCurrent() || input.operationInFlightRef.current) return;
        const latestLocal = lastLocalStatusRef.current;
        const localStatus = latestLocal?.deviceId === activeDeviceId && latestLocal?.locationId === input.activeLocationId && latestLocal?.profileVersion === activeProfile.profileVersion
          ? latestLocal.status
          : lastLocalDegradedStatusRef.current ?? undefined;
        const health = assessNativeTunnelHealth({
          deviceUsage: activeUsage,
          nowMs: Date.now(),
          staleHandshakeSeconds: input.staleHandshakeSeconds,
          status: localStatus,
        });
        backendHealthFailuresRef.current = health.healthy ? 0 : backendHealthFailuresRef.current + 1;
        if (health.healthy && localHealthFailuresRef.current === 0) {
          recoveryBackoffRef.current = resetRecoveryBackoff();
          const failure = lastRecoveryFailureRef.current;
          if (failure && input.onHealthRecovered && input.probeHealth &&
              failure.deviceId === activeDeviceId && failure.locationId === input.activeLocationId &&
              failure.profileVersion === activeProfile.profileVersion && failure.accessToken === accessToken &&
              localStatus?.state === 'connected') {
            const recovered = await input.probeHealth(activeProfile).catch(() => null);
            const confirmed = lastLocalStatusRef.current;
            // A fresh HTTPS result may clear only this watchdog's warning for
            // the same session/profile. User actions and later local failures win.
            if (isCurrent() && !input.operationInFlightRef.current &&
                lastRecoveryFailureRef.current === failure && localHealthFailuresRef.current === 0 &&
                recovered?.httpsOk === true && recovered.dnsOk !== false &&
                confirmed?.deviceId === activeDeviceId && confirmed.locationId === input.activeLocationId &&
                confirmed.profileVersion === activeProfile.profileVersion && confirmed.status.state === 'connected' &&
                localStatusHealthReasons(confirmed.status, Date.now(), input.staleHandshakeSeconds).length === 0) {
              lastRecoveryFailureRef.current = null;
              input.onHealthRecovered(failure.message);
            }
          }
          return;
        }

        const healthFailureCount = Math.max(backendHealthFailuresRef.current, localHealthFailuresRef.current);
        const nowMs = Date.now();
        const cooldownElapsed = nowMs - lastReconnectAtRef.current > input.reconnectCooldownMs;
        if (healthFailureCount < input.failureThreshold || !cooldownElapsed || !recoveryAttemptAllowed(recoveryBackoffRef.current, nowMs)) {
          return;
        }
        const probe = localHealthFailuresRef.current >= input.failureThreshold ? undefined : await input.probeHealth?.(activeProfile).catch((error): VpnAutopilotProbeResult => ({
          endpointProbeError: errorMessage(error, 'network_probe_failed'),
        }));
        if (!isCurrent() || input.operationInFlightRef.current) return;
        const assessment = assessVpnAutopilotIssue({
          healthReasons: health.reasons,
          localStatus,
          probe,
          usageError,
        });

        // Claim the same lease used by explicit connect/switch operations before
        // any awaited diagnostics or native mutation can overlap user intent.
        input.operationInFlightRef.current = true;
        ownsOperation = true;
        recoveryOwnerIsCurrent = input.beginRecoveryOperation?.() ?? (() =>
          input.sessionAccessToken === latestInputRef.current.sessionAccessToken);
        const failedRoute = Platform.OS === 'android'
          ? dynamicRouteRuntime.recordActiveFailure(activeProfile)
          : null;
        if (failedRoute) {
          void input.submitDiagnostics('dynamic_route', 'degraded', {}, {
            connectionEvent: 'unexpected_disconnect',
            transportFrom: routeTransport(failedRoute),
          }).catch(() => undefined);
        }

        const reconnectStartedAt = Date.now();
        lastReconnectAtRef.current = Date.now();
        resetHealthFailures();
        input.onRecoveryStarted?.('Восстанавливаем VPN');
        void submitDiagnostics('native_watchdog_reconnect', 'degraded', {
          ...assessment.sample,
          active_usage: activeUsage,
          local_status: localStatus,
          native_health_failures: healthFailureCount,
          native_health_reasons: health.reasons,
          reconnect_cooldown_ms: input.reconnectCooldownMs,
          selection_mode: input.serverSelectionMode,
          stale_handshake_seconds: input.staleHandshakeSeconds,
          usage_error: usageError,
        }, {
          connectionEvent: 'reconnect_started',
          transportFrom: vpnTransportTelemetry(activeProfile),
        }).catch(() => undefined);

        if (!recoveryIsCurrent()) return;
        const recovery = await recoverVpnConnection({
          isCurrentOperation: recoveryIsCurrent,
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
        // Catalog/profile renders and AppState blur retire the polling timer,
        // not an operation already changing the native exit. Only its owner,
        // account or explicit location intent may cancel that operation.
        if (!recoveryIsCurrent()) {
          return;
        }
        if (recovery.ok) {
          lastRecoveryFailureRef.current = null;
          recoveryBackoffRef.current = resetRecoveryBackoff();
          acceptedRecovery = true;
          input.onRecoverySucceeded(recovery.profile, recovery.status, recovery.locationId);
          reportConnect(recovery.profile);
          void submitDiagnostics('native_watchdog_reconnect_result', 'ok', {
            ...assessment.sample,
            previous_location_id: recovery.previousLocationId,
            next_location_id: recovery.locationId,
            failover_reason: recovery.outcome === 'failover_location' ? assessment.cause : undefined,
            recovery_result: recovery.outcome === 'failover_location' ? 'failover_location' : 'same_location',
            recovery_outcome: recovery.outcome,
            selection_mode: input.serverSelectionMode,
          }, {
            connectionEvent: 'reconnect_succeeded',
            connectDurationMs: Math.max(0, Date.now() - reconnectStartedAt),
            transportFrom: vpnTransportTelemetry(activeProfile),
            transportTo: vpnTransportTelemetry(recovery.profile),
          }).catch(() => undefined);
          return;
        }

        await input.protectFailedRecovery?.();
        if (!recoveryIsCurrent()) return;
        lastRecoveryFailureRef.current = { message: assessment.userMessage, deviceId: activeDeviceId,
          locationId: input.activeLocationId, profileVersion: activeProfile.profileVersion, accessToken };
        input.onRecoveryFailed(assessment.userMessage);
        recoveryBackoffRef.current = recordRecoveryFailure(recoveryBackoffRef.current, Date.now(), {
          baseDelayMs: input.reconnectCooldownMs,
          circuitFailureThreshold: recoveryCircuitFailureThreshold,
          circuitOpenMs: input.reconnectCooldownMs * recoveryCircuitOpenMultiplier,
          jitterRatio: recoveryJitterRatio,
          maxDelayMs: input.reconnectCooldownMs * recoveryMaxBackoffMultiplier,
        });
        void submitDiagnostics('native_watchdog_reconnect_result', 'failed', {
          ...assessment.sample,
          previous_location_id: recovery.previousLocationId,
          next_location_id: recovery.locationId,
          recovery_error: errorMessage(recovery.error, 'unknown'),
          recovery_result: 'failed',
          recovery_backoff_failures: recoveryBackoffRef.current.consecutiveFailures,
          recovery_circuit_open_until_ms: recoveryBackoffRef.current.circuitOpenUntilMs || null,
          recovery_next_attempt_at_ms: recoveryBackoffRef.current.nextAttemptAtMs,
          selection_mode: input.serverSelectionMode,
        }, {
          connectionEvent: 'reconnect_failed',
          connectDurationMs: Math.max(0, Date.now() - reconnectStartedAt),
          transportFrom: vpnTransportTelemetry(activeProfile),
        }).catch(() => undefined);
      } catch (error) {
        if (ownsOperation ? !recoveryIsCurrent() : !isCurrent()) return;
        if (ownsOperation) {
          await input.protectFailedRecovery?.().catch(() => undefined);
          if (!recoveryIsCurrent()) return;
          input.onRecoveryFailed(errorMessage(error, 'Не удалось восстановить VPN.'));
        }
        void submitDiagnostics('native_watchdog_check_failed', 'error', {
          watchdog_error: errorMessage(error, 'native_watchdog_check_failed'),
        }).catch(() => undefined);
        backendHealthFailuresRef.current = 0;
      } finally {
        // A location-only user intent can retire this recovery without
        // starting another native operation. Retain protection for that case;
        // a newer generation owns its own teardown and must never be touched.
        if (ownsOperation && !acceptedRecovery && recoveryOwnerIsCurrent?.() !== false && !recoveryIsCurrent()) {
          await input.protectFailedRecovery?.().catch(() => undefined);
        }
        if (ownsOperation && recoveryOwnerIsCurrent?.() !== false) input.operationInFlightRef.current = false;
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
    input.enabled,
    input.failureThreshold,
    input.isVpnBusy,
    input.operationInFlightRef,
    input.pollMs,
    input.reconnectCooldownMs,
    reportConnect,
    input.serverSelectionMode,
    input.sessionAccessToken,
    input.staleHandshakeSeconds,
    submitDiagnostics,
  ]);

  function resetHealthFailures() {
    backendHealthFailuresRef.current = 0;
    localHealthFailuresRef.current = 0;
    lastLocalDegradedStatusRef.current = null;
  }

  return { recordNativeStatus };
}
