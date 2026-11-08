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
      if (['network_unavailable', 'request_timeout', 'recovery_status_ambiguous', 'native_transport_update_required', 'native_mutation_origin_unsupported'].includes(error.code ?? '')) return false;
    }
    return true;
  };
}
