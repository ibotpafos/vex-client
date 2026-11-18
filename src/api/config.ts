import { ApiRequestError } from './error';

/** Fixed trust roots. API routing must never expand update or website trust. */
export const productionApiOrigins = ['https://api.vexguard.app', 'https://api2.vexguard.app'] as const;
export const canonicalWebsiteOrigin = 'https://vexguard.app';
export const trustedUpdateBaseUrl = canonicalWebsiteOrigin;

export function trimTrailingSlash(value: string): string {
  return value.replace(/\/+$/, '');
}

export function resolveApiOrigins(configured?: string): readonly string[] {
  if (!configured || [canonicalWebsiteOrigin, 'https://www.vexguard.app', ...productionApiOrigins].includes(configured.replace(/\/+$/, ''))) {
    return productionApiOrigins;
  }
  const url = new URL(configured);
  const local = ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname);
  if (!local || !['http:', 'https:'].includes(url.protocol) || url.username || url.password
    || url.search || url.hash || url.pathname !== '/') {
    throw new ApiRequestError('Untrusted API origin', { code: 'invalid_api_base_url' });
  }
  // Explicit local proxy configuration is isolated: never send its credentials to production.
  return [url.origin];
}

// Origin-first builder used by the transport client. Strict /v1/ path validation.
export function apiUrlFromOrigin(origin: string, path: string): string {
  // Only relative, canonical API paths. Reject URL parser normalization and encoded separators.
  if (!path.startsWith('/v1/') || /[\\#\s]/.test(path)) throw new Error('Invalid API path');
  const pathname = path.split('?')[0];
  const decoded = decodeURIComponent(pathname);
  if (decoded.includes('\\') || /%|\/\//.test(decoded)
    || decoded.split('/').some(part => part === '.' || part === '..')
    || /%2f/i.test(pathname)) throw new Error('Invalid API path');
  const url = new URL(path, origin);
  if (url.origin !== origin || url.pathname !== pathname) throw new Error('Invalid API path');
  return url.href;
}

// A local proxy override wins over the production default; it never joins failover.
const legacyApiBase = process.env.EXPO_PUBLIC_VEX_API_BASE_URL;

export let apiOrigins: readonly string[];
try {
  apiOrigins = resolveApiOrigins(legacyApiBase && /^(https?:\/\/)(localhost|127\.0\.0\.1|\[::1\])(?=[:/]|$)/.test(legacyApiBase)
    ? legacyApiBase : process.env.EXPO_PUBLIC_VEX_API_ORIGIN || legacyApiBase);
} catch {
  // A misconfigured origin must not crash the client bundle at import time.
  // Fall back to the fixed production trust roots; an untrusted origin is never used.
  apiOrigins = productionApiOrigins;
}
// A configured local proxy also overrides the base used for absolute URLs, so
// development and fixture transports hit it instead of production. Fixtures that
// also set EXPO_PUBLIC_VEX_API_BASE_URL must reach their own base path.
export const vexApiBaseUrl = /^https?:\/\/(localhost|127\.0\.0\.1|\[::1\])(?=[:/]|$)/.test(legacyApiBase ?? '')
  ? legacyApiBase!.replace(/\/+$/, '')
  : canonicalWebsiteOrigin;
// SSE keeps legacy production routing, while local development must stay on its proxy.
export const realtimeApiBaseUrl = apiOrigins.length === 1 ? apiOrigins[0] : canonicalWebsiteOrigin;

export function validatedApiBaseUrl(value = vexApiBaseUrl): URL {
  try {
    const url = new URL(value.trim());
    if (!['http:', 'https:'].includes(url.protocol) || !url.hostname || url.username || url.password
      || value.includes('?') || value.includes('#')) {
      throw new Error('invalid API base');
    }
    return url;
  } catch {
    // Do not include configuration text: an invalid URL can contain credentials.
    throw new ApiRequestError('Неверно настроен адрес API.', { code: 'invalid_api_base_url' });
  }
}

export function apiRequestUrl(path: string, baseUrl = vexApiBaseUrl): string {
  const base = validatedApiBaseUrl(baseUrl);
  if (!path.startsWith('/') || path.startsWith('//') || path.includes('\\') || path.includes('#')) {
    throw new ApiRequestError('Некорректный путь API.', { code: 'invalid_api_path' });
  }
  return new URL(`${trimTrailingSlash(base.toString())}${path}`).toString();
}

export function absolutizeUrl(value: string): string {
  if (!value) {
    return '';
  }
  if (/^https?:\/\//i.test(value)) {
    return value;
  }
  if (value.startsWith('/')) {
    return `${vexApiBaseUrl}${value}`;
  }
  return `${vexApiBaseUrl}/${value}`;
}
