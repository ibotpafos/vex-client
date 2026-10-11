export function shouldUseMemoryOnlySensitiveWebStorage(
  platformOS: string,
  key: string,
  sensitiveKeys: readonly string[],
): boolean {
  return platformOS === 'web' && (sensitiveKeys.includes(key) || key.startsWith('vex.vpn.account_keys.v1.') || key.startsWith('vex.vpn.account_registration.v1.'));
}
