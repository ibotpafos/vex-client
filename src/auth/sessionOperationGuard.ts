export function isCurrentSessionOperation(
  expectedRevision: number,
  currentRevision: number,
  expectedUserId: string | undefined,
  currentUserId: string | undefined,
  blocked: boolean,
): boolean {
  return Boolean(expectedUserId) && !blocked && expectedRevision === currentRevision && expectedUserId === currentUserId;
}
