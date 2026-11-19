/** Identity integers must survive JSON/JavaScript round trips without aliasing. */
export function isNonnegativeSafeInteger(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0;
}

export function isPositiveSafeInteger(value: unknown): value is number {
  return isNonnegativeSafeInteger(value) && value > 0;
}
