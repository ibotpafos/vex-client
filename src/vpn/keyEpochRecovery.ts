const keyEpochMismatchMessage = 'key_epoch does not match next device epoch';

export function isKeyEpochMismatchError(error: unknown): boolean {
  return error instanceof Error && error.message.toLowerCase().includes(keyEpochMismatchMessage);
}
