export function isCurrentSessionMutation(
  expectedRevision: number,
  currentRevision: number,
  expectedAccessToken: string,
  currentAccessToken?: string,
): boolean {
  return expectedRevision === currentRevision && expectedAccessToken === currentAccessToken;
}
