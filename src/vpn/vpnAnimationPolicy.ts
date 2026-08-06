export function vpnConnectionAnimationsEnabled(platform: string): boolean {
  return platform !== 'android';
}
