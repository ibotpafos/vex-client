export type AuthCallbackInput = {
  code?: string | null;
  state?: string | null;
};

export function resolveAuthCallbackExchange(
  input: AuthCallbackInput,
  savedState: string | null,
  savedVerifier: string | null,
): { code: string; verifier: string } {
  const code = input.code?.trim() || '';
  const state = input.state?.trim() || '';
  if (!code || !state) {
    throw new Error('Сайт вернул неполные параметры входа.');
  }
  if (!savedState || state !== savedState) {
    throw new Error('Проверка безопасности входа не прошла. Запустите вход заново.');
  }
  if (!savedVerifier) {
    throw new Error('Сессия входа устарела. Запустите вход заново.');
  }
  return { code, verifier: savedVerifier };
}
