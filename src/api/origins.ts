/** Fixed trust roots. API routing must never expand update or website trust. */
export const productionApiOrigins = ['https://api.vexguard.app', 'https://api2.vexguard.app'] as const;
export const canonicalWebsiteOrigin = 'https://vexguard.app';
export const trustedUpdateBaseUrl = canonicalWebsiteOrigin;

export function resolveApiOrigins(configured?: string): readonly string[] {
  if (!configured || [canonicalWebsiteOrigin, 'https://www.vexguard.app', ...productionApiOrigins].includes(configured.replace(/\/+$/, ''))) {
    return productionApiOrigins;
  }
  const url = new URL(configured);
  const local = ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname);
  if (!local || !['http:', 'https:'].includes(url.protocol) || url.username || url.password
    || url.search || url.hash || url.pathname !== '/') {
    throw new Error('Untrusted API origin');
  }
  // Explicit local proxy configuration is isolated: never send its credentials to production.
  return [url.origin];
}

export function apiRequestUrl(origin: string, path: string): string {
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
