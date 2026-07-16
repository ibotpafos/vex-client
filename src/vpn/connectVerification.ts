import type { VpnStatus } from '@/native/vexVpn';

type HandshakeVerificationOptions = {
  attempts?: number;
  minimumHandshakeEpochMillis?: number;
  pollMs?: number;
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
  let latestStatus = initialStatus;

  for (let attempt = 0; attempt < attempts; attempt += 1) {
    await wait(pollMs);
    latestStatus = await readStatus();
    if (latestStatus.state !== 'connected') {
      throw new Error('VPN disconnected before the handshake completed.');
    }
    if (isHandshakeVerifiedForAttempt(latestStatus, options.minimumHandshakeEpochMillis)) {
      return latestStatus;
    }
  }

  throw new Error('VPN handshake timed out.');
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
