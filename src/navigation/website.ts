const defaultWebsiteBaseUrl = process.env.EXPO_PUBLIC_VEX_API_BASE_URL || 'https://vexguard.app';

export function vexWebsiteUrl(path: string, baseUrl = defaultWebsiteBaseUrl): string {
  if (!path.startsWith('/')) {
    throw new Error('Website path must start with /');
  }
  const website = new URL(baseUrl);
  const target = new URL(path, website);
  if (target.origin !== website.origin) {
    throw new Error('Website path must stay on the VEX website');
  }
  return target.toString();
}

export const vexWebsite = {
  dashboard: () => vexWebsiteUrl('/dashboard'),
  support: () => vexWebsiteUrl('/support'),
} as const;
