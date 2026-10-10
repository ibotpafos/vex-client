export const technicalWorksMessage = 'Идут технические работы. Мы уже переключаем сервисы, попробуйте через пару минут.';

export class ApiRequestError extends Error {
  status?: number;
  code?: string;
  retryAfterMs?: number;

  constructor(message: string, options: { status?: number; code?: string; retryAfterMs?: number } = {}) {
    super(message);
    this.name = 'ApiRequestError';
    this.status = options.status;
    this.code = options.code;
    this.retryAfterMs = options.retryAfterMs;
  }
}

export function normalizeApiRequestError(error: unknown): Error {
  if (isTechnicalWorksError(error)) {
    if (error instanceof ApiRequestError) {
      return new ApiRequestError(technicalWorksMessage, { status: error.status, code: error.code, retryAfterMs: error.retryAfterMs });
    }
    const message = error instanceof Error ? error.message.toLowerCase() : '';
    const code = message.includes('превышено время ожидания api') ? 'request_timeout'
      : /network request failed|failed to fetch|load failed|fetch request has been canceled|unable to resolve host|could not connect|connection refused|connection reset/.test(message)
        ? 'network_unavailable' : undefined;
    return new ApiRequestError(technicalWorksMessage, { code });
  }
  if (error instanceof Error) {
    return error;
  }
  return new Error(String(error));
}

export function isMaintenanceStatus(status: number): boolean {
  return status === 502 || status === 503 || status === 504;
}

export function isTechnicalWorksError(error: unknown): boolean {
  if (!(error instanceof Error)) {
    return false;
  }
  if (error instanceof ApiRequestError) {
    if (error.code === 'maintenance' || (error.status && isMaintenanceStatus(error.status))) {
      return true;
    }
  }
  const message = error.message.toLowerCase();
  return message.includes('идут технические работы')
    || message.includes('network request failed')
    || message.includes('failed to fetch')
    || message.includes('load failed')
    || message.includes('fetch request has been canceled')
    || message.includes('unable to resolve host')
    || message.includes('could not connect')
    || message.includes('connection refused')
    || message.includes('connection reset')
    || message.includes('превышено время ожидания api');
}
