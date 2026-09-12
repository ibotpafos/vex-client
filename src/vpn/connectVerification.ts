import type { VpnStatus } from '@/native/vexVpn';

type HandshakeVerificationOptions = {
  attempts?: number;
  minimumHandshakeEpochMillis?: number;
  pollMs?: number;
  timeoutMs?: number;
  now?: () => number;
  wait?: (delayMs: number) => Promise<void>;
};

const defaultHandshakeAttempts = 20;
const defaultHandshakePollMs = 250;

export async function waitForVerifiedVpnConnection(
  initialStatus: VpnStatus,
  readStatus: () => Promise<VpnStatus>,
  options: HandshakeVerificationOptions = {},
): Promise<VpnStatus> {
  if (initialStatus.state !== 'connected') {
    throw new Error('VPN backend did not enter the connected state.');
  }
  if (isHandshakeVerifiedForAttempt(initialStatus, options.minimumHandshakeEpochMillis)) {
    return initialStatus;
  }

  const attempts = Math.max(1, options.attempts ?? defaultHandshakeAttempts);
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
    if (budget <= 0) throw new Error('VPN handshake timed out.');
    return budget;
  };
  let latestStatus = initialStatus;

  for (let attempt = 0; attempt < attempts; attempt += 1) {
    if (attempt > 0) await withDeadline(() => wait(pollMs), remaining());
    latestStatus = await withDeadline(readStatus, remaining());
    remaining();
    // Android can emit a transition snapshot while the native status reader
    // holds tunnelMutex. It is not a terminal disconnect, and must not roll a
    // working server switch back. Keep the same bounded verification budget.
    if (latestStatus.state === 'connecting' || latestStatus.state === 'verifying') {
      continue;
    }
    if (latestStatus.state !== 'connected') {
      throw new Error(`VPN disconnected before the handshake completed (${latestStatus.state}).`);
    }
    if (isHandshakeVerifiedForAttempt(latestStatus, options.minimumHandshakeEpochMillis)) {
      return latestStatus;
    }
  }

  throw new Error('VPN handshake timed out.');
}

async function withDeadline<T>(operation: () => Promise<T>, timeoutMs: number): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      Promise.resolve().then(operation),
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error('VPN handshake timed out.')), timeoutMs);
      }),
    ]);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}

function isHandshakeVerifiedForAttempt(status: VpnStatus, minimumHandshakeEpochMillis?: number): boolean {
  if (minimumHandshakeEpochMillis === undefined) {
    return status.verified !== false;
  }
  return status.verified !== false &&
    typeof status.latestHandshakeEpochMillis === 'number' &&
    status.latestHandshakeEpochMillis >= minimumHandshakeEpochMillis;
}

function delay(delayMs: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, delayMs));
}
