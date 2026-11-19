import { validatedApiBaseUrl, vexApiBaseUrl } from '../api/config';

export function vexWebsiteUrl(path: string, baseUrl = vexApiBaseUrl): string {
  if (!path.startsWith('/')) {
    throw new Error('Website path must start with /');
  }
  const website = validatedApiBaseUrl(baseUrl);
  const target = new URL(path, website);
  if (target.origin !== website.origin) {
    throw new Error('Website path must stay on the VEX website');
  }
  return target.toString();
}

export const vexWebsite = {
  testing: () => vexWebsiteUrl('/dashboard/testing'),
  dashboard: () => vexWebsiteUrl('/dashboard'),
  support: () => vexWebsiteUrl('/support'),
} as const;
