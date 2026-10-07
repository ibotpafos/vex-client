import { submitClientDiagnostics, vexApiBaseUrl, type ClientDiagnosticsReportInput, type VpnDeviceUsage } from '@/api/vexApi';
import { getAppInfo } from '@/native/appInfo';
import * as SecureStore from '@/native/secureStore';
import { measureEndpointLatency, readNativeVpnDiagnostics, type VpnStatus } from '@/native/vexVpn';
import { probeNetworkHealth } from '@/vpn/networkHealthProbe';
import { getOtaProvenance } from './otaProvenance';
import { getVpnStatus, readVpnNetworkObservation } from '@/native/vexVpn';
import { matchingNetworkObservation, type CapturedNetworkObservation } from './networkObservation';

const queueKey = 'vex.diagnostics.client.queue.v1';
const maxQueuedReports = 10;
const networkProbeCacheTtlMs = 30_000;

export type VpnDiagnosticsSnapshot = {
  reason: string;
  status: string;
  deviceId?: string;
  endpoint?: string;
  vpnStatus: VpnStatus;
  latencyMs?: number | null;
  usage?: VpnDeviceUsage;
  routingMode?: string;
  bypassRegion?: string;
  bypassRangesCount?: number;
  routingPolicyVersion?: string;
  selectedLocationId?: string;
  connectionEvent?: ClientDiagnosticsReportInput['connectionEvent'];
  connectDurationMs?: number;
  transportFrom?: ClientDiagnosticsReportInput['transportFrom'];
  transportTo?: ClientDiagnosticsReportInput['transportTo'];
  sessionUptimeSeconds?: number;
  samples?: Record<string, unknown>;
};

let uploadChain: Promise<void> = Promise.resolve();
let capturedNetwork: CapturedNetworkObservation | null = null;
let capturedAccessToken: string | undefined;
let captureGeneration = 0;

export async function prepareClientNetworkDiagnostics(accessToken: string, deviceId: string | undefined): Promise<void> {
  const attempt = ++captureGeneration;
  const deadline = Date.now() + 1_500;
  capturedNetwork = null;
  capturedAccessToken = undefined;
  if (!deviceId) return;
  try {
    const [network, status, app] = await Promise.all([readVpnNetworkObservation(), getVpnStatus(), getAppInfo()]);
    if (!network.generation || status.state !== 'disconnected' || Date.now() >= deadline || attempt !== captureGeneration) return;
    // Never queue this seed: retrying it through a tunnel observes the VPN exit.
    const response = await submitClientDiagnostics(accessToken, {
      deviceId, platform: app.platform, appVersion: app.version, reason: 'network_before_connect', status: 'info',
      vpnState: 'disconnected', networkClass: network.networkClass, networkGeneration: network.generation,
    }, Math.min(1_000, deadline - Date.now()));
    const current = await readVpnNetworkObservation();
    if (attempt !== captureGeneration || Date.now() >= deadline || current.generation !== network.generation || current.networkClass !== network.networkClass || !response.id) return;
    capturedNetwork = { ...network, id: response.id, deviceId, capturedAt: Date.now() };
    capturedAccessToken = accessToken;
  } catch { /* Optional capture must not prevent VPN connection. */ }
}
let cachedNetworkProbe: {
  endpoint?: string;
  vpnState: VpnStatus['state'];
  networkGeneration: string;
  latestHandshakeEpochMillis?: number;
  measuredAt: number;
  result: Awaited<ReturnType<typeof probeNetworkHealth>>;
} | null = null;
let inflightNetworkProbe: Promise<Awaited<ReturnType<typeof probeNetworkHealth>>> | null = null;

export function uploadClientDiagnostics(accessToken: string, snapshot: VpnDiagnosticsSnapshot): Promise<void> {
  uploadChain = uploadChain
    .catch(() => undefined)
    .then(() => uploadClientDiagnosticsNow(accessToken, snapshot));
  return uploadChain;
}

async function uploadClientDiagnosticsNow(accessToken: string, snapshot: VpnDiagnosticsSnapshot): Promise<void> {
  const report = await buildClientDiagnosticsReport(snapshot, accessToken);
  const queuedReports = await readQueuedReports();
  const remainingReports: ClientDiagnosticsReportInput[] = [];

  for (const queued of queuedReports) {
    try {
      await submitClientDiagnostics(accessToken, queued);
    } catch {
      remainingReports.push(queued);
    }
  }

  try {
    await submitClientDiagnostics(accessToken, report);
    await writeQueuedReports(remainingReports);
  } catch {
    await writeQueuedReports([...remainingReports, report].slice(-maxQueuedReports));
  }
}

async function buildClientDiagnosticsReport(snapshot: VpnDiagnosticsSnapshot, accessToken: string): Promise<ClientDiagnosticsReportInput> {
  const appInfo = await getAppInfo();
  const nativeVpnDiagnostics = await readNativeVpnDiagnostics();
  const usage = snapshot.usage;
  const generatedAt = new Date().toISOString();
  const beforeProbe = await readVpnNetworkObservation();
  const networkProbe = await cachedDiagnosticsNetworkProbe(snapshot.endpoint, snapshot.vpnStatus, beforeProbe.generation);
  const currentNetwork = await readVpnNetworkObservation();
  const observationId = matchingNetworkObservation(capturedAccessToken === accessToken ? capturedNetwork : null, currentNetwork, snapshot.deviceId, Date.now());
  return {
    deviceId: snapshot.deviceId,
    networkClass: currentNetwork.networkClass,
    networkObservationId: observationId,
    networkGeneration: observationId ? currentNetwork.generation : undefined,
    platform: appInfo.platform,
    appVersion: appInfo.build ? `${appInfo.version}+${appInfo.build}` : appInfo.version,
    reason: snapshot.reason,
    status: snapshot.status,
    vpnState: snapshot.vpnStatus.state,
    connectionEvent: snapshot.connectionEvent,
    connectDurationMs: normalizeNumber(snapshot.connectDurationMs),
    transportFrom: snapshot.transportFrom,
    transportTo: snapshot.transportTo,
    sessionUptimeSeconds: normalizeNumber(snapshot.sessionUptimeSeconds),
    endpoint: snapshot.endpoint,
    // TODO(diagnostics-tristate): API/storage still use mandatory booleans.
    // Preserve legacy wire defaults until backend/readers support unknown;
    // samples.network_probe retains which checks were actually measured.
    dnsOk: networkProbe.dnsOk !== false,
    httpsOk: networkProbe.httpsOk !== false,
    latencyAverageMs: normalizeNumber(snapshot.latencyMs ?? networkProbe.endpointLatencyMs),
    rxBytes: usage?.rxBytes ?? snapshot.vpnStatus.rxBytes,
    txBytes: usage?.txBytes ?? snapshot.vpnStatus.txBytes,
    samples: {
      generated_at: generatedAt,
      app: {
        channel: appInfo.channel,
        core_version: appInfo.coreVersion,
        api_client_version: appInfo.apiClientVersion,
        config_schema_version: appInfo.configSchemaVersion,
      },
      vpn_status: snapshot.vpnStatus,
      native_vpn_diagnostics: nativeVpnDiagnostics,
      network_probe: networkProbe,
      usage,
      routing: {
        routing_mode: snapshot.routingMode,
        bypass_region: snapshot.bypassRegion,
        bypass_ranges_count: snapshot.bypassRangesCount,
        routing_policy_version: snapshot.routingPolicyVersion,
        selected_location_id: snapshot.selectedLocationId,
      },
      ...snapshot.samples,
      ...getOtaProvenance(),
      ...diagnosticErrorMetadata(snapshot.reason, snapshot.samples),
    },
  };
}

type DiagnosticErrorClass = 'auth' | 'entitlement' | 'network' | 'timeout' | 'profile_revoked' | 'native_connect' | 'cancelled' | 'unknown';
type DiagnosticErrorStage = 'profile_resolution' | 'hot_profile' | 'native_connect' | 'verification';

function diagnosticErrorMetadata(reason: string, samples: Record<string, unknown> | undefined): Record<string, DiagnosticErrorClass | DiagnosticErrorStage> {
  const errorText = diagnosticErrorText(samples);
  if (!errorText) return {};
  const stage = diagnosticErrorStage(reason, samples);
  return {
    diagnostic_error_class: diagnosticErrorClass(reason, errorText, samples),
    ...(stage ? { diagnostic_error_stage: stage } : {}),
  };
}

function diagnosticErrorText(samples: Record<string, unknown> | undefined): string | undefined {
  if (!samples) return undefined;
  for (const [key, value] of Object.entries(samples)) {
    if ((key === 'error' || key.endsWith('_error')) && typeof value === 'string' && value.trim()) {
      return value.toLowerCase();
    }
  }
  return undefined;
}

function diagnosticErrorClass(reason: string, errorText: string, samples: Record<string, unknown> | undefined): DiagnosticErrorClass {
  const normalizedReason = reason.toLowerCase();
  if (/401|unauthorized|authentication required/.test(errorText)) return 'auth';
  if (normalizedReason.includes('entitlement') || hasErrorKey(samples, 'entitlement_error')) return 'entitlement';
  if (normalizedReason.includes('revoked')) return 'profile_revoked';
  if (/timeout|timed out|превышено время ожидания/.test(errorText)) return 'timeout';
  if (/cancel(?:led|ed)|abort/.test(errorText)) return 'cancelled';
  if (/network request failed|unable to resolve host|fetch failed|network/.test(errorText)) return 'network';
  if (hasErrorKey(samples, 'connect_error')) return 'native_connect';
  return 'unknown';
}

function diagnosticErrorStage(reason: string, samples: Record<string, unknown> | undefined): DiagnosticErrorStage | undefined {
  const normalizedReason = reason.toLowerCase();
  if (normalizedReason.includes('hot_profile')) return 'hot_profile';
  if (normalizedReason.includes('verification')) return 'verification';
  if (hasErrorKey(samples, 'connect_error')) return 'native_connect';
  if (normalizedReason.includes('profile') || normalizedReason.includes('entitlement')) return 'profile_resolution';
  return undefined;
}

function hasErrorKey(samples: Record<string, unknown> | undefined, key: string): boolean {
  return typeof samples?.[key] === 'string' && Boolean(samples[key].trim());
}

async function cachedDiagnosticsNetworkProbe(endpoint: string | undefined, vpnStatus: VpnStatus, networkGeneration: string): Promise<Awaited<ReturnType<typeof probeNetworkHealth>>> {
  const now = Date.now();
  if (
    cachedNetworkProbe
    && cachedNetworkProbe.endpoint === endpoint
    && cachedNetworkProbe.networkGeneration === networkGeneration
    && cachedNetworkProbe.vpnState === vpnStatus.state
    && cachedNetworkProbe.latestHandshakeEpochMillis === vpnStatus.latestHandshakeEpochMillis
    && now >= cachedNetworkProbe.measuredAt
    && now - cachedNetworkProbe.measuredAt <= networkProbeCacheTtlMs
  ) {
    return cachedNetworkProbe.result;
  }
  if (inflightNetworkProbe) {
    return inflightNetworkProbe;
  }

  inflightNetworkProbe = probeNetworkHealth({
    apiBaseUrl: vexApiBaseUrl,
    endpoint,
    measureEndpointLatency,
  })
    .then((result) => {
      cachedNetworkProbe = {
        endpoint,
        vpnState: vpnStatus.state,
        networkGeneration,
        latestHandshakeEpochMillis: vpnStatus.latestHandshakeEpochMillis,
        measuredAt: Date.now(),
        result,
      };
      return result;
    })
    .finally(() => {
      inflightNetworkProbe = null;
    });

  return inflightNetworkProbe;
}

function normalizeNumber(value: number | null | undefined): number | undefined {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    return undefined;
  }
  return value;
}

async function readQueuedReports(): Promise<ClientDiagnosticsReportInput[]> {
  try {
    const raw = await SecureStore.getItemAsync(queueKey);
    if (!raw) {
      return [];
    }
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) {
      return [];
    }
    return parsed.slice(-maxQueuedReports) as ClientDiagnosticsReportInput[];
  } catch {
    return [];
  }
}

async function writeQueuedReports(reports: ClientDiagnosticsReportInput[]): Promise<void> {
  if (reports.length === 0) {
    await SecureStore.deleteItemAsync(queueKey).catch(() => undefined);
    return;
  }
  await SecureStore.setItemAsync(queueKey, JSON.stringify(reports.slice(-maxQueuedReports))).catch(() => undefined);
}
