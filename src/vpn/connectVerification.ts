import type { VpnStatus } from '@/native/vexVpn';

type HandshakeVerificationOptions = {
  transport?: 'amneziawg' | 'vless';
  expectedConnectionId?: string;
  previousConnectionId?: string;
  minimumVerificationEpochMillis?: number;
  attempts?: number;
  minimumHandshakeEpochMillis?: number;
  previousHandshakeEpochMillis?: number;
  pollMs?: number;
  timeoutMs?: number;
  now?: () => number;
  wait?: (delayMs: number) => Promise<void>;
  scheduleTimeout?: (delayMs: number, onTimeout: () => void) => () => void;
  assertCurrent?: () => void;
};

const defaultHandshakePollMs = 250;

export async function waitForVerifiedVpnConnection(
  initialStatus: VpnStatus,
  readStatus: () => Promise<VpnStatus>,
  options: HandshakeVerificationOptions = {},
): Promise<VpnStatus> {
  const proofOptions = { ...options, expectedConnectionId: options.expectedConnectionId ?? initialStatus.connectionId };
  options.assertCurrent?.();
  if (initialStatus.state !== 'connected' && initialStatus.state !== 'connecting' && initialStatus.state !== 'verifying') {
    throw new Error('VPN backend did not enter the connected state.');
  }
  if (initialStatus.state === 'connected' && isHandshakeVerifiedForAttempt(initialStatus, proofOptions)) {
    return initialStatus;
  }

  // A default attempt cap can expire before WireGuard's first retry (~5s).
  // Use the elapsed-time deadline unless the caller explicitly limits reads.
  const attempts = options.attempts === undefined ? Infinity : Math.max(1, options.attempts);
  const pollMs = Math.max(0, options.pollMs ?? defaultHandshakePollMs);
  const scheduleTimeout = options.scheduleTimeout ?? scheduleJsTimeout;
  const wait = options.wait ?? ((delayMs: number) => new Promise<void>((resolve) => {
    scheduleTimeout(delayMs, resolve);
  }));
  const now = options.now ?? Date.now;
  const timeoutMs = options.timeoutMs ?? 10_000;
  if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) {
    throw new Error('VPN handshake timeout must be positive.');
  }
  const deadline = now() + timeoutMs;
  const remaining = () => {
    const budget = deadline - now();
    if (budget <= 0) throw new Error('VPN handshake timed out.');
    return budget;
  };
  let latestStatus = initialStatus;

  for (let attempt = 0; attempt < attempts; attempt += 1) {
    options.assertCurrent?.();
    if (attempt > 0) await withDeadline(() => wait(Math.min(pollMs, remaining())), remaining(), scheduleTimeout);
    options.assertCurrent?.();
    latestStatus = await withDeadline(readStatus, remaining(), scheduleTimeout);
    options.assertCurrent?.();
    remaining();
    // Native tunnel activation and status reads can return a pending snapshot.
    // Keep the same bounded budget until a connected handshake is verified.
    if (latestStatus.state === 'connecting' || latestStatus.state === 'verifying') {
      continue;
    }
    if (latestStatus.state !== 'connected') {
      throw new Error(`VPN disconnected before the handshake completed (${latestStatus.state}).`);
    }
    if (isHandshakeVerifiedForAttempt(latestStatus, proofOptions)) {
      return latestStatus;
    }
  }

  throw new Error('VPN handshake timed out.');
}

async function withDeadline<T>(operation: () => Promise<T>, timeoutMs: number,
  scheduleTimeout: (delayMs: number, onTimeout: () => void) => () => void): Promise<T> {
  let cancel: (() => void) | undefined;
  try {
    return await Promise.race([
      Promise.resolve().then(operation),
      new Promise<never>((_, reject) => {
        cancel = scheduleTimeout(timeoutMs, () => reject(new Error('VPN handshake timed out.')));
      }),
    ]);
  } finally {
    cancel?.();
  }
}

function isHandshakeVerifiedForAttempt(status: VpnStatus, options: HandshakeVerificationOptions): boolean {
  if (options.transport === 'amneziawg' && status.transport === 'vless') return false;
  if (options.transport === 'vless' || status.transport === 'vless') {
    const now = options.now?.() ?? Date.now();
    return status.transport === 'vless' && status.verified === true &&
      typeof status.connectionId === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(status.connectionId) &&
      status.connectionId === options.expectedConnectionId && status.connectionId !== options.previousConnectionId &&
      typeof status.verificationEpochMillis === 'number' && Number.isFinite(status.verificationEpochMillis) &&
      status.verificationEpochMillis >= (options.minimumVerificationEpochMillis ?? 1) && status.verificationEpochMillis <= now;
  }
  const { minimumHandshakeEpochMillis, previousHandshakeEpochMillis } = options;
  if (minimumHandshakeEpochMillis === undefined) {
    return status.verified !== false &&
      (previousHandshakeEpochMillis === undefined ||
        (typeof status.latestHandshakeEpochMillis === 'number' &&
          status.latestHandshakeEpochMillis > previousHandshakeEpochMillis));
  }
  return status.verified !== false &&
    typeof status.latestHandshakeEpochMillis === 'number' &&
    status.latestHandshakeEpochMillis >= minimumHandshakeEpochMillis &&
    (previousHandshakeEpochMillis === undefined ||
      status.latestHandshakeEpochMillis > previousHandshakeEpochMillis);
}

function scheduleJsTimeout(delayMs: number, onTimeout: () => void): () => void {
  const timer = setTimeout(onTimeout, delayMs);
  return () => clearTimeout(timer);
}
