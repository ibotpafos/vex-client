/** Tokens remain transient: only the verified VEX session is persisted. */
export async function exchangeNativeGoogleCredential<T>(
  getCredential: () => Promise<string>,
  exchange: (idToken: string) => Promise<T>,
): Promise<T> {
  const idToken = await getCredential();
  if (!idToken.trim()) throw new Error('Google не вернул подтверждение входа.');
  return exchange(idToken);
}

export function isGoogleSignInCancelled(error: unknown): boolean {
  return typeof error === 'object' && error !== null
    && 'code' in error && error.code === 'GOOGLE_SIGN_IN_CANCELLED';
}
