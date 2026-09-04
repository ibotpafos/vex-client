import type { FcmPushRegistration } from './pushRegistration';

type RegistrationLoopDeps = {
  getRegistration: (allowPermissionPrompt: boolean) => Promise<FcmPushRegistration | null>;
  register: (registration: FcmPushRegistration) => Promise<void>;
  schedule?: (callback: () => void, delayMs: number) => unknown;
  cancel?: (timer: unknown) => void;
};

/** One foreground/session/device-scoped worker; token values never reach logs. */
export function startPushRegistrationLoop(deps: RegistrationLoopDeps) {
  const schedule = deps.schedule ?? ((callback, delay) => setTimeout(callback, delay));
  const cancel = deps.cancel ?? (timer => clearTimeout(timer as ReturnType<typeof setTimeout>));
  let stopped = false;
  let timer: unknown;
  let registeredToken: string | undefined;
  let firstAttempt = true;
  let failures = 0;
  const run = async () => {
    if (stopped) return;
    let delay = 60_000;
    const allowPrompt = firstAttempt;
    firstAttempt = false;
    try {
      const registration = await deps.getRegistration(allowPrompt);
      if (stopped) return;
      if (registration && registration.token !== registeredToken) {
        await deps.register(registration);
        if (stopped) return;
        // Only successful server registration may suppress a later retry.
        registeredToken = registration.token;
      }
      failures = 0;
    } catch {
      delay = Math.min(60_000, 5_000 * 2 ** Math.min(failures++, 4));
    } finally {
      if (!stopped) timer = schedule(() => { void run(); }, delay);
    }
  };
  void run();
  return {
    stop() {
      stopped = true;
      if (timer !== undefined) cancel(timer);
    },
  };
}
