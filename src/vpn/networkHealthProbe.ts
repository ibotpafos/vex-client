import type { VpnAutopilotProbeResult } from './vpnAutopilotAssessment';
import { errorMessage } from '@/utils/error';

type NetworkHealthProbeInput = {
  apiBaseUrl: string;
  endpoint?: string;
  fetchImpl?: typeof fetch;
  measureEndpointLatency?: (endpoint: string) => Promise<number | null>;
  timeoutMs?: number;
};

const defaultProbeTimeoutMs = 5000;

export async function probeNetworkHealth(input: NetworkHealthProbeInput): Promise<VpnAutopilotProbeResult> {
  const timeoutMs = input.timeoutMs ?? defaultProbeTimeoutMs;
  if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) {
    throw new Error('Network probe timeout must be positive.');
  }
  const controller = new AbortController();
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<void>((resolve) => {
    timer = setTimeout(() => { resolve(); controller.abort(); }, timeoutMs);
  });
  try {
    const [endpointProbe, httpsProbe] = await Promise.all([
      Promise.race([
        probeEndpoint(input),
        deadline.then((): VpnAutopilotProbeResult => ({ endpointLatencyMs: null, endpointProbeError: 'endpoint_probe_timeout' })),
      ]),
      Promise.race([
        probeHttps(input, controller.signal),
        deadline.then((): VpnAutopilotProbeResult => ({ httpsOk: false, httpsProbeError: 'https_probe_timeout' })),
      ]),
    ]);
    return { ...endpointProbe, ...httpsProbe };
  } finally {
    clearTimeout(timer);
  }
}

async function probeEndpoint(input: NetworkHealthProbeInput): Promise<VpnAutopilotProbeResult> {
  if (!input.endpoint || !input.measureEndpointLatency) {
    return {};
  }
  try {
    const endpointLatencyMs = await input.measureEndpointLatency(input.endpoint);
    return {
      // Latency can target an IP directly. A missing measurement is not
      // evidence that DNS failed, and a successful one is not a DNS probe.
      endpointLatencyMs,
    };
  } catch (error) {
    return {
      dnsOk: errorLooksLikeDns(error) ? false : undefined,
      endpointLatencyMs: null,
      endpointProbeError: errorMessage(error, 'network_probe_failed'),
    };
  }
}

async function probeHttps(input: NetworkHealthProbeInput, signal: AbortSignal): Promise<VpnAutopilotProbeResult> {
  const fetchImpl = input.fetchImpl ?? globalThis.fetch;
  if (!fetchImpl || !input.apiBaseUrl) {
    return {};
  }
  try {
    const response = await fetchImpl(probeUrl(input.apiBaseUrl), {
      cache: 'no-store',
      method: 'GET',
      signal,
    });
    return { httpsOk: response.ok || response.status < 500 };
  } catch (error) {
    return {
      httpsOk: false,
      httpsProbeError: signal.aborted ? 'https_probe_timeout' : errorMessage(error, 'network_probe_failed'),
    };
  }
}

function probeUrl(apiBaseUrl: string): string {
  try {
    const url = new URL(apiBaseUrl);
    url.pathname = '/v1/app/remote-config';
    url.search = '';
    url.hash = '';
    return url.toString();
  } catch {
    return apiBaseUrl;
  }
}

function errorLooksLikeDns(error: unknown): boolean {
  const message = errorMessage(error).toLowerCase();
  return message.includes('dns') ||
    message.includes('lookup') ||
    message.includes('resolve') ||
    message.includes('name resolution') ||
    message.includes('unable to resolve host');
}
