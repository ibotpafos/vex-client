import { requestCancelledError, requireRequestActive } from '../api/error';

// Profile issuance mutates the backend peer placement for this installation.
// Serialize it; a stale background read must never move a just-connected peer.
// Foreground connects are latency-sensitive, so they may jump ahead of queued
// background revalidations while the currently running request is left intact.
export type ProfileRequestPriority = 'foreground' | 'background';

type QueuedProfileRequest = {
  cancelled: boolean;
  controller: AbortController;
  coalesceKey: string;
  followers: QueuedProfileRequest[];
  isCurrent: () => boolean;
  operation: (signal: AbortSignal) => Promise<unknown>;
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
  operation: (signal: AbortSignal) => Promise<T>,
  isCurrent: () => boolean = () => true,
  priority: ProfileRequestPriority = 'foreground',
  coalesceKey = '',
  signal?: AbortSignal,
): Promise<T> {
  if (signal?.aborted) return Promise.reject(requestCancelledError());
  let resolveResult!: (value: T | PromiseLike<T>) => void;
  let rejectResult!: (reason?: unknown) => void;
  const result = new Promise<T>((resolve, reject) => {
    resolveResult = resolve;
    rejectResult = reject;
  });

  const queued: QueuedProfileRequest = {
    cancelled: false,
    controller: new AbortController(),
    coalesceKey: coalesceKey.trim(),
    followers: [],
    isCurrent,
    operation,
    priority,
    reject: (error) => { signal?.removeEventListener('abort', onAbort); rejectResult(error); },
    resolve: (value) => { signal?.removeEventListener('abort', onAbort); resolveResult(value as T); },
  };
  const onAbort = () => {
    queued.cancelled = true;
    queued.reject(requestCancelledError());
    const owner = requestInFlight === queued || requestInFlight?.followers.includes(queued) ? requestInFlight : queued;
    // A foreground connect may borrow a background issuance. Only the last
    // cancelled borrower can stop its reads; durable writes still finish under
    // their session owner before the serialization slot is released.
    if (owner && owner.cancelled && owner.followers.every(item => item.cancelled)) owner.controller.abort();
  };
  signal?.addEventListener('abort', onAbort, { once: true });
  if (
    priority === 'foreground' &&
    queued.coalesceKey &&
    requestInFlight?.priority === 'background' &&
    !requestInFlight.controller.signal.aborted &&
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
      requireRequestActive(next.controller.signal);
      if (!next.isCurrent()) throw new ProfileRequestSupersededError();
      return next.operation(next.controller.signal);
    })
    .then((value) => {
      requestInFlight = null;
      next.resolve(value);
      for (const follower of next.followers) {
        if (follower.cancelled) continue;
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
        foregroundQueue.unshift(...next.followers.filter(item => !item.cancelled));
      }
      drainProfileRequestQueue();
    });
}
