import { isNonnegativeSafeInteger } from './profileNumbers';

const keyEpochMismatchMessage = 'key_epoch does not match next device epoch';

export function isKeyEpochMismatchError(error: unknown): boolean {
  return error instanceof Error && error.message.toLowerCase().includes(keyEpochMismatchMessage);
}

export function nextManagedKeyEpoch(localGeneratedEpoch?: number, serverCurrentEpoch?: number): number {
  if (serverCurrentEpoch !== undefined) {
    if (!isNonnegativeSafeInteger(serverCurrentEpoch) || serverCurrentEpoch === Number.MAX_SAFE_INTEGER) {
      throw new Error('Невозможно безопасно определить следующую эпоху ключа VPN.');
    }
    return serverCurrentEpoch + 1;
  }
  if (localGeneratedEpoch === undefined) return 1;
  if (!isNonnegativeSafeInteger(localGeneratedEpoch)) throw new Error('Локальная эпоха ключа VPN некорректна.');
  return Math.max(1, localGeneratedEpoch);
}
