export function vpnConnectionAnimationsEnabled(platform: string, tauriRuntime: boolean): boolean {
  return platform !== 'android' && !tauriRuntime;
}
