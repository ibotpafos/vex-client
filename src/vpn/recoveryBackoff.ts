export type RecoveryBackoffState = {
  consecutiveFailures: number;
  nextAttemptAtMs: number;
  circuitOpenUntilMs: number;
};

export type RecoveryBackoffOptions = {
  baseDelayMs: number;
  circuitFailureThreshold: number;
  circuitOpenMs: number;
  jitterRatio: number;
  maxDelayMs: number;
};

export function initialRecoveryBackoffState(): RecoveryBackoffState {
  return { consecutiveFailures: 0, nextAttemptAtMs: 0, circuitOpenUntilMs: 0 };
}

export function recoveryAttemptAllowed(state: RecoveryBackoffState, nowMs: number): boolean {
  return nowMs >= Math.max(state.nextAttemptAtMs, state.circuitOpenUntilMs);
}

export function recordRecoveryFailure(
  state: RecoveryBackoffState,
  nowMs: number,
  options: RecoveryBackoffOptions,
  random: () => number = Math.random,
): RecoveryBackoffState {
  const consecutiveFailures = state.consecutiveFailures + 1;
  const exponentialDelay = Math.min(
    positive(options.maxDelayMs),
    positive(options.baseDelayMs) * 2 ** Math.max(0, consecutiveFailures - 1),
  );
  const jitterRatio = Math.min(1, Math.max(0, options.jitterRatio));
  const randomUnit = Math.min(1, Math.max(0, random()));
  const jitterMultiplier = 1 - jitterRatio + randomUnit * jitterRatio * 2;
  const nextAttemptAtMs = nowMs + Math.round(exponentialDelay * jitterMultiplier);
  const circuitOpenUntilMs = consecutiveFailures >= positiveInteger(options.circuitFailureThreshold)
    ? nowMs + positive(options.circuitOpenMs)
    : 0;

  return { consecutiveFailures, nextAttemptAtMs, circuitOpenUntilMs };
}

export function resetRecoveryBackoff(): RecoveryBackoffState {
  return initialRecoveryBackoffState();
}

function positive(value: number): number {
  return Number.isFinite(value) ? Math.max(1, value) : 1;
}

function positiveInteger(value: number): number {
  return Math.max(1, Math.floor(positive(value)));
}
