import { ApiRequestError, isMaintenanceStatus } from './error';

// rawRequest owns the retry budget and deadline for transport failures. Starting
// a new request here would reset that budget or bypass a server Retry-After.
export function createApiQueryRetry(maxRetries: number) {
  return (failureCount: number, error: unknown): boolean => {
    if (failureCount >= maxRetries) return false;
    if (error instanceof ApiRequestError) {
      if (error.status === 429 || (error.retryAfterMs ?? 0) > 0) return false;
      if (error.status && error.status >= 400 && error.status < 500 && error.status !== 408) return false;
      if (error.status && isMaintenanceStatus(error.status)) return false;
      if (error.code === 'network_unavailable' || error.code === 'request_timeout') return false;
    }
    return true;
  };
}
