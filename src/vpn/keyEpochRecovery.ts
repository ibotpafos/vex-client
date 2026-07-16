const keyEpochMismatchMessage = 'key_epoch does not match next device epoch';

export function isKeyEpochMismatchError(error: unknown): boolean {
  return error instanceof Error && error.message.toLowerCase().includes(keyEpochMismatchMessage);
}

export function nextManagedKeyEpoch(localGeneratedEpoch?: number, serverCurrentEpoch?: number): number {
  if (Number.isFinite(serverCurrentEpoch)) {
    return Math.max(1, Math.trunc(serverCurrentEpoch!) + 1);
  }
  return Number.isFinite(localGeneratedEpoch) ? Math.max(1, Math.trunc(localGeneratedEpoch!)) : 1;
}
