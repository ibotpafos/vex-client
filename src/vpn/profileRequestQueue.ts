// Profile issuance mutates the backend peer placement for this installation.
// Serialize it; a stale background read must never move a just-connected peer.
let tail: Promise<unknown> = Promise.resolve();

export class ProfileRequestSupersededError extends Error {
  constructor() { super('Background profile request superseded'); }
}

export function runProfileRequest<T>(operation: () => Promise<T>, isCurrent: () => boolean = () => true): Promise<T> {
  const result = tail.then(() => {
    if (!isCurrent()) throw new ProfileRequestSupersededError();
    return operation();
  });
  tail = result.catch(() => undefined);
  return result;
}
