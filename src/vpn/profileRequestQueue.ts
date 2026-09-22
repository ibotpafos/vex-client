// Profile issuance mutates the backend peer placement for this installation.
// Serialize it; a stale background read must never move a just-connected peer.
// Foreground connects are latency-sensitive, so they may jump ahead of queued
// background revalidations while the currently running request is left intact.
export type ProfileRequestPriority = 'foreground' | 'background';

type QueuedProfileRequest = {
  coalesceKey: string;
  followers: QueuedProfileRequest[];
  isCurrent: () => boolean;
  operation: () => Promise<unknown>;
  priority: ProfileRequestPriority;
  reject: (reason?: unknown) => void;
  resolve: (value: unknown) => void;
};

const foregroundQueue: QueuedProfileRequest[] = [];
const backgroundQueue: QueuedProfileRequest[] = [];
let requestInFlight: QueuedProfileRequest | null = null;

export class ProfileRequestSupersededError extends Error {
  constructor() { super('Background profile request superseded'); }
}

export function runProfileRequest<T>(
  operation: () => Promise<T>,
  isCurrent: () => boolean = () => true,
  priority: ProfileRequestPriority = 'foreground',
  coalesceKey = '',
): Promise<T> {
  let resolveResult!: (value: T | PromiseLike<T>) => void;
  let rejectResult!: (reason?: unknown) => void;
  const result = new Promise<T>((resolve, reject) => {
    resolveResult = resolve;
    rejectResult = reject;
  });

  const queued: QueuedProfileRequest = {
    coalesceKey: coalesceKey.trim(),
    followers: [],
    isCurrent,
    operation,
    priority,
    reject: rejectResult,
    resolve: (value) => resolveResult(value as T),
  };
  if (
    priority === 'foreground' &&
    queued.coalesceKey &&
    requestInFlight?.priority === 'background' &&
    requestInFlight.coalesceKey === queued.coalesceKey
  ) {
    requestInFlight.followers.push(queued);
    return result;
  }

  (priority === 'background' ? backgroundQueue : foregroundQueue).push(queued);
  drainProfileRequestQueue();
  return result;
}

function drainProfileRequestQueue(): void {
  if (requestInFlight) return;
  const next = foregroundQueue.shift() ?? backgroundQueue.shift();
  if (!next) return;

  requestInFlight = next;
  Promise.resolve()
    .then(() => {
      if (!next.isCurrent()) throw new ProfileRequestSupersededError();
      return next.operation();
    })
    .then((value) => {
      requestInFlight = null;
      next.resolve(value);
      for (const follower of next.followers) {
        if (follower.isCurrent()) follower.resolve(value);
        else follower.reject(new ProfileRequestSupersededError());
      }
      drainProfileRequestQueue();
    }, (error) => {
      requestInFlight = null;
      next.reject(error);
      // A foreground connect that joined a failed speculative background
      // request still gets its own attempt, ahead of queued revalidations.
      if (next.followers.length > 0) {
        foregroundQueue.unshift(...next.followers);
      }
      drainProfileRequestQueue();
    });
}
