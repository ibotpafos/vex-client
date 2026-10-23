import type { VpnStatus } from '@/native/vexVpn';

type HandshakeVerificationOptions = {
  attempts?: number;
  minimumHandshakeEpochMillis?: number;
  previousHandshakeEpochMillis?: number;
  pollMs?: number;
  timeoutMs?: number;
  now?: () => number;
  wait?: (delayMs: number) => Promise<void>;
  assertCurrent?: () => void;
  requireDataPlane?: boolean;
};

const defaultHandshakePollMs = 250;

export async function waitForVerifiedVpnConnection(
  initialStatus: VpnStatus,
  readStatus: () => Promise<VpnStatus>,
  options: HandshakeVerificationOptions = {},
): Promise<VpnStatus> {
  const timeoutMessage = options.requireDataPlane ? 'VPN DNS/HTTPS verification timed out.' : 'VPN handshake timed out.';
  options.assertCurrent?.();
  if (initialStatus.state !== 'connected' && initialStatus.state !== 'connecting' && initialStatus.state !== 'verifying') {
    throw new Error('VPN backend did not enter the connected state.');
  }
  if (initialStatus.state === 'connected' && isHandshakeVerifiedForAttempt(initialStatus, options)) {
    return initialStatus;
  }

  // A default attempt cap can expire before WireGuard's first retry (~5s).
  // Use the elapsed-time deadline unless the caller explicitly limits reads.
  const attempts = options.attempts === undefined ? Infinity : Math.max(1, options.attempts);
  const pollMs = Math.max(0, options.pollMs ?? defaultHandshakePollMs);
  const wait = options.wait ?? delay;
  const now = options.now ?? Date.now;
  const timeoutMs = options.timeoutMs ?? 10_000;
  if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) {
    throw new Error('VPN handshake timeout must be positive.');
  }
  const deadline = now() + timeoutMs;
  const remaining = () => {
    const budget = deadline - now();
    if (budget <= 0) throw new Error(timeoutMessage);
    return budget;
  };
  let latestStatus = initialStatus;

  for (let attempt = 0; attempt < attempts; attempt += 1) {
    options.assertCurrent?.();
    if (attempt > 0) await withDeadline(() => wait(Math.min(pollMs, remaining())), remaining(), timeoutMessage);
    options.assertCurrent?.();
    latestStatus = await withDeadline(readStatus, remaining(), timeoutMessage);
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
    if (isHandshakeVerifiedForAttempt(latestStatus, options)) {
      return latestStatus;
    }
  }

  throw new Error(timeoutMessage);
}

async function withDeadline<T>(operation: () => Promise<T>, timeoutMs: number, timeoutMessage: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      Promise.resolve().then(operation),
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error(timeoutMessage)), timeoutMs);
      }),
    ]);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}

function isHandshakeVerifiedForAttempt(status: VpnStatus, options: HandshakeVerificationOptions): boolean {
  if (options.requireDataPlane && status.dataPlaneVerified !== true) return false;
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

function delay(delayMs: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, delayMs));
}
