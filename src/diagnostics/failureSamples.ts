import { ApiRequestError } from '../api/error';

export type DiagnosticErrorClass = 'auth' | 'entitlement' | 'network' | 'timeout' | 'profile_revoked'
  | 'native_connect' | 'cancelled' | 'http' | 'response_parse' | 'unknown';

// Only fixed categories and a numeric HTTP status cross the diagnostics boundary.
// Error messages, server codes, names, URLs and request bodies are never copied.
export function diagnosticFailureSamples(error: unknown): {
  diagnostic_error_class: DiagnosticErrorClass;
  diagnostic_http_status?: number;
} {
  if (error instanceof ApiRequestError) {
    const status = error.status;
    if (typeof status === 'number' && Number.isInteger(status) && status >= 400 && status <= 599) {
      return { diagnostic_error_class: 'http', diagnostic_http_status: status };
    }
    if (error.code === 'request_timeout') return { diagnostic_error_class: 'timeout' };
    if (error.code === 'network_unavailable') return { diagnostic_error_class: 'network' };
  }
  if (error instanceof Error && error.name === 'AbortError') return { diagnostic_error_class: 'cancelled' };
  if (error instanceof SyntaxError) return { diagnostic_error_class: 'response_parse' };
  return { diagnostic_error_class: 'unknown' };
}
