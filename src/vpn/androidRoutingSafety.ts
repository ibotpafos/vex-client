export function androidExperimentalRoutingEnabled(platform: string, flag: string | undefined): boolean {
  return platform === 'android' && flag === '1';
}

export function androidProfilePlatform(platform: string, experimentalRouting: boolean): string {
  return platform === 'android' && experimentalRouting ? 'android-smart-v1' : platform;
}

// Android publishes every VPN route through LinkProperties. A 5,300-route
// profile produced ~721 KiB Binder parcels on a real Android 9 device and
// broke system network callbacks, so reject stale oversized profiles well
// before the platform transaction ceiling.
export const androidVpnRouteLimit = 1_500;

export function vpnProfileRouteCount(config: string): number {
  return config
    .split(/\r?\n/)
    .filter((line) => /^AllowedIPs\s*=/i.test(line.trim()))
    .reduce((count, line) => count + line
      .substring(line.indexOf('=') + 1)
      .split(',')
      .map((route) => route.trim())
      .filter(Boolean).length, 0);
}

export function androidVpnProfileWithinBinderBudget(
  platform: string,
  config: string,
  routeLimit = androidVpnRouteLimit,
): boolean {
  return platform !== 'android' || vpnProfileRouteCount(config) <= routeLimit;
}
