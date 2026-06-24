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
  const endpointProbe = await probeEndpoint(input);
  const httpsProbe = await probeHttps(input);
  return {
    ...endpointProbe,
    ...httpsProbe,
  };
}

async function probeEndpoint(input: NetworkHealthProbeInput): Promise<VpnAutopilotProbeResult> {
  if (!input.endpoint || !input.measureEndpointLatency) {
    return {};
  }
  try {
    const endpointLatencyMs = await input.measureEndpointLatency(input.endpoint);
    return {
      dnsOk: endpointLatencyMs !== null,
      endpointLatencyMs,
    };
  } catch (error) {
    return {
      dnsOk: !errorLooksLikeDns(error),
      endpointLatencyMs: null,
      endpointProbeError: errorMessage(error, 'network_probe_failed'),
    };
  }
}

async function probeHttps(input: NetworkHealthProbeInput): Promise<VpnAutopilotProbeResult> {
  const fetchImpl = input.fetchImpl ?? globalThis.fetch;
  if (!fetchImpl || !input.apiBaseUrl) {
    return {};
  }
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), input.timeoutMs ?? defaultProbeTimeoutMs);
  try {
    const response = await fetchImpl(probeUrl(input.apiBaseUrl), {
      cache: 'no-store',
      method: 'GET',
      signal: controller.signal,
    });
    return { httpsOk: response.ok || response.status < 500 };
  } catch (error) {
    return {
      httpsOk: false,
      httpsProbeError: errorMessage(error, 'network_probe_failed'),
    };
  } finally {
    clearTimeout(timeout);
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

