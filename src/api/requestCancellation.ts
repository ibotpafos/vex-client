import { requestCancelledError, requireRequestActive } from './error';

// Cancel a borrower's wait even when a native setup call or shared transaction
// cannot be interrupted. The operation still owns its cleanup and durable writes.
export async function withRequestCancellation<T>(operation: () => Promise<T>, signal?: AbortSignal): Promise<T> {
  requireRequestActive(signal);
  if (!signal) return operation();
  let onAbort!: () => void;
  const cancelled = new Promise<never>((_, reject) => {
    onAbort = () => reject(requestCancelledError());
    signal.addEventListener('abort', onAbort, { once: true });
  });
  try {
    requireRequestActive(signal);
    const pending = Promise.resolve().then(() => {
      requireRequestActive(signal);
      return operation();
    });
    return await Promise.race([pending, cancelled]);
  } finally {
    signal.removeEventListener('abort', onAbort);
  }
}
