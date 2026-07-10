export type VpnApplicationRoutingMode = 'all' | 'selected';

export function normalizePackageNames(packageNames: string[]): string[] {
  return [...new Set(packageNames
    .map((value) => value.trim())
    .filter((value) => /^[a-zA-Z][a-zA-Z0-9_]*(?:\.[a-zA-Z0-9_]+)+$/.test(value)))]
    .sort();
}

