export type AuthCallbackInput = {
  code?: string | null;
  state?: string | null;
};

export type AuthCallbackAttempt<T> = {
  key: string;
  promise: Promise<T>;
};

export function authCallbackAttemptKey(input: AuthCallbackInput): string {
  return `${input.code?.trim() || ''}\u0000${input.state?.trim() || ''}`;
}

export function getOrCreateAuthCallbackAttempt<T>(
  current: AuthCallbackAttempt<T> | null,
  key: string,
  start: () => Promise<T>,
): AuthCallbackAttempt<T> {
  if (current?.key === key) {
    return current;
  }
  return { key, promise: start() };
}

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
