export function shouldUseMemoryOnlySensitiveWebStorage(
  platformOS: string,
  key: string,
  sensitiveKeys: readonly string[],
): boolean {
  return platformOS === 'web' && sensitiveKeys.includes(key);
}
