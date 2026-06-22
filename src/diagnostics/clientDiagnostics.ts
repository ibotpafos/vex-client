import { submitClientDiagnostics, vexApiBaseUrl, type ClientDiagnosticsReportInput, type VpnDeviceUsage } from '@/api/vexApi';
import { getAppInfo } from '@/native/appInfo';
import * as SecureStore from '@/native/secureStore';
import { measureEndpointLatency, readNativeVpnDiagnostics, type VpnStatus } from '@/native/vexVpn';
import { probeNetworkHealth } from '@/vpn/networkHealthProbe';

const queueKey = 'vex.diagnostics.client.queue.v1';
const maxQueuedReports = 10;

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
  samples?: Record<string, unknown>;
};

let uploadChain: Promise<void> = Promise.resolve();

export function uploadClientDiagnostics(accessToken: string, snapshot: VpnDiagnosticsSnapshot): Promise<void> {
  uploadChain = uploadChain
    .catch(() => undefined)
    .then(() => uploadClientDiagnosticsNow(accessToken, snapshot));
  return uploadChain;
}

async function uploadClientDiagnosticsNow(accessToken: string, snapshot: VpnDiagnosticsSnapshot): Promise<void> {
  const report = await buildClientDiagnosticsReport(snapshot);
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

async function buildClientDiagnosticsReport(snapshot: VpnDiagnosticsSnapshot): Promise<ClientDiagnosticsReportInput> {
  const appInfo = await getAppInfo();
  const nativeVpnDiagnostics = await readNativeVpnDiagnostics();
  const usage = snapshot.usage;
  const generatedAt = new Date().toISOString();
  const networkProbe = await probeNetworkHealth({
    apiBaseUrl: vexApiBaseUrl,
    endpoint: snapshot.endpoint,
    measureEndpointLatency,
  });
  return {
    deviceId: snapshot.deviceId,
    platform: appInfo.platform,
    appVersion: appInfo.build ? `${appInfo.version}+${appInfo.build}` : appInfo.version,
    reason: snapshot.reason,
    status: snapshot.status,
    vpnState: snapshot.vpnStatus.state,
    endpoint: snapshot.endpoint,
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
    },
  };
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
