import type { VpnProfile } from './profile';

const endpointFallbackPorts = [443, 51820];

export function isVpnTransportFallbackError(error: unknown): boolean {
  const message = errorText(error).toLowerCase();
  return message.includes('handshake') ||
    message.includes('vpn connection failed') ||
    message.includes('vpn_connect_failed') ||
    message.includes('network') ||
    message.includes('timeout') ||
    message.includes('timed out');
}

export function connectionAttemptsForProfile(profile: VpnProfile): VpnProfile[] {
  const attempts = profile.lastSuccessfulEndpoint
    ? [profileWithEndpoint(profile, profile.lastSuccessfulEndpoint) ?? profile]
    : [profile];
  if (!attempts.some((attempt) => profileEndpoint(attempt) === profileEndpoint(profile))) {
    attempts.push(profile);
  }
  for (const port of endpointFallbackPorts) {
    const fallback = profileWithEndpointPort(profile, port);
    if (fallback && !attempts.some((attempt) => profileEndpoint(attempt) === profileEndpoint(fallback))) {
      attempts.push(fallback);
    }
  }
  return attempts;
}

function profileWithEndpoint(profile: VpnProfile, endpoint: string): VpnProfile | null {
  const nextEndpoint = endpoint.trim();
  if (!nextEndpoint) {
    return null;
  }
  const nextConfig = replaceConfigEndpoint(profile.config, nextEndpoint);
  if (!nextConfig) {
    return null;
  }
  return {
    ...profile,
    config: nextConfig,
    device: profile.device ? { ...profile.device, endpoint: nextEndpoint } : profile.device,
  };
}

export function profileEndpoint(profile: VpnProfile): string | undefined {
  return profile.device?.endpoint || configEndpoint(profile.config);
}

function profileWithEndpointPort(profile: VpnProfile, port: number): VpnProfile | null {
  const endpoint = profileEndpoint(profile);
  const parsed = parseEndpoint(endpoint);
  if (!parsed || parsed.port === port) {
    return null;
  }

  const nextEndpoint = formatEndpoint(parsed.host, port);
  const nextConfig = replaceConfigEndpoint(profile.config, nextEndpoint);
  if (!nextConfig) {
    return null;
  }

  return {
    ...profile,
    config: nextConfig,
    device: profile.device ? { ...profile.device, endpoint: nextEndpoint } : profile.device,
  };
}

function configEndpoint(config: string): string | undefined {
  return /^Endpoint\s*=\s*(.+)$/m.exec(config)?.[1]?.trim();
}

function replaceConfigEndpoint(config: string, endpoint: string): string | null {
  if (!/^Endpoint\s*=/m.test(config)) {
    return null;
  }
  return config.replace(/^Endpoint\s*=\s*.+$/m, `Endpoint = ${endpoint}`);
}

function parseEndpoint(endpoint?: string): { host: string; port?: number } | null {
  const value = endpoint?.trim();
  if (!value) {
    return null;
  }
  if (value.startsWith('[') && value.includes(']:')) {
    const host = value.slice(1, value.indexOf(']')).trim();
    const port = Number(value.slice(value.lastIndexOf(':') + 1));
    return host && Number.isFinite(port) ? { host, port } : null;
  }
  const lastColon = value.lastIndexOf(':');
  if (lastColon <= 0 || lastColon === value.length - 1 || value.indexOf(':') !== lastColon) {
    return { host: value };
  }
  const host = value.slice(0, lastColon).trim();
  const port = Number(value.slice(lastColon + 1));
  return host && Number.isFinite(port) ? { host, port } : null;
}

function formatEndpoint(host: string, port: number): string {
  return host.includes(':') && !host.startsWith('[') ? `[${host}]:${port}` : `${host}:${port}`;
}

function errorText(error: unknown): string {
  if (error instanceof Error && typeof error.message === 'string') {
    return error.message.trim();
  }
  return typeof error === 'string' ? error.trim() : '';
}
