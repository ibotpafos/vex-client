// Profile issuance mutates the backend peer placement for this installation.
// Serialize it; a stale background read must never move a just-connected peer.
// Foreground connects are latency-sensitive, so they may jump ahead of queued
// background revalidations while the currently running request is left intact.
export type ProfileRequestPriority = 'foreground' | 'background';

type QueuedProfileRequest = {
  isCurrent: () => boolean;
  operation: () => Promise<unknown>;
  reject: (reason?: unknown) => void;
  resolve: (value: unknown) => void;
};

const foregroundQueue: QueuedProfileRequest[] = [];
const backgroundQueue: QueuedProfileRequest[] = [];
let requestInFlight = false;

export class ProfileRequestSupersededError extends Error {
  constructor() { super('Background profile request superseded'); }
}

export function runProfileRequest<T>(
  operation: () => Promise<T>,
  isCurrent: () => boolean = () => true,
  priority: ProfileRequestPriority = 'foreground',
): Promise<T> {
  const result = new Promise<T>((resolve, reject) => {
    const queued: QueuedProfileRequest = {
      isCurrent,
      operation,
      reject,
      resolve: (value) => resolve(value as T),
    };
    (priority === 'background' ? backgroundQueue : foregroundQueue).push(queued);
    drainProfileRequestQueue();
  });
  return result;
}

function drainProfileRequestQueue(): void {
  if (requestInFlight) return;
  const next = foregroundQueue.shift() ?? backgroundQueue.shift();
  if (!next) return;

  requestInFlight = true;
  Promise.resolve()
    .then(() => {
      if (!next.isCurrent()) throw new ProfileRequestSupersededError();
      return next.operation();
    })
    .then(next.resolve, next.reject)
    .finally(() => {
      requestInFlight = false;
      drainProfileRequestQueue();
    });
}
