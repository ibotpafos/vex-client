export function managedProfileAWGVersionForPlatform(platform: string): number {
  // The embedded iOS WireGuard bridge supports AWG2 attributes only. Advertising
  // AWG3 causes the server to issue HeaderProtectionKey, which the bridge rejects
  // when the tunnel is parsed after a reconnect.
  return platform === 'ios' ? 2 : 3;
}

export function withManagedProfileAWGCapability(query: URLSearchParams, platform: string): URLSearchParams {
  const next = new URLSearchParams(query);
  next.set('awg_version', String(managedProfileAWGVersionForPlatform(platform)));
  return next;
}
