export function managedProfileAWGVersionForPlatform(_platform: string): number {
  // iOS and Android both embed AWG3-capable WireGuard bridges. Keep the capability
  // explicit at the app boundary so the API can safely select AWG3 for either client.
  return 3;
}

export function withManagedProfileAWGCapability(query: URLSearchParams, platform: string): URLSearchParams {
  const next = new URLSearchParams(query);
  next.set('awg_version', String(managedProfileAWGVersionForPlatform(platform)));
  return next;
}
