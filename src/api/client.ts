import { fetch as expoFetch } from 'expo/fetch';
import { Platform } from 'react-native';
import { getAppInfo, getOrCreateDeviceId } from '@/native/appInfo';
import { androidExperimentalRoutingEnabled, androidProfilePlatform } from '@/vpn/androidRoutingSafety';
import { apiRequestUrl } from './config';
import { ApiRequestError, isMaintenanceStatus, normalizeApiRequestError, readApiErrorPayload } from './error';
export { trimTrailingSlash, vexApiBaseUrl } from './config';
export { isMaintenanceStatus, isTechnicalWorksError, normalizeApiRequestError, technicalWorksMessage } from './error';

export type RequestOptions = {
  accessToken?: string;
  body?: Record<string, unknown>;
  headers?: Record<string, string>;
  idempotencyKey?: string;
  method?: string;
  retryCount?: number;
  suppressErrorLog?: boolean;
  timeout?: number;
};

const requestTimeoutMs = 30000;
const getRequestRetryCount = 2;
const requestRetryDelayMs = 600;
const shouldLogApiRequests = typeof __DEV__ !== 'undefined' && __DEV__;


export async function jsonRequest<T>(path: string, options: RequestOptions = {}): Promise<T> {
  return JSON.parse(await rawRequest(path, options)) as T;
}

export async function rawRequest(path: string, options: RequestOptions = {}): Promise<string> {
  const url = apiRequestUrl(path);
  const controller = new AbortController();
  const timeoutMs = options.timeout ?? requestTimeoutMs;
  const deadline = Date.now() + timeoutMs;
  let timeout: ReturnType<typeof setTimeout>;
  const expired = new Promise<never>((_, reject) => {
    timeout = setTimeout(() => {
      controller.abort();
      reject(new ApiRequestError('Превышено время ожидания API.', { code: 'request_timeout' }));
    }, timeoutMs);
  });
  try {
    return await Promise.race([requestWithinDeadline(url, options, controller.signal, deadline), expired]);
  } catch (error) {
    throw normalizeApiRequestError(error);
  } finally {
    clearTimeout(timeout!);
    // Retire unread responses as well as the timer; in particular a blocked
    // redirect must not leave its native body/request alive.
    controller.abort();
  }
}

function requireRequestTime(signal: AbortSignal, deadline: number): void {
  if (signal.aborted || Date.now() >= deadline) {
    throw new ApiRequestError('Превышено время ожидания API.', { code: 'request_timeout' });
  }
}

async function requestWithinDeadline(url: string, options: RequestOptions, signal: AbortSignal, deadline: number): Promise<string> {
  const method = options.method ?? 'GET';
  const maxAttempts = method === 'GET' ? Math.max(0, Math.min(getRequestRetryCount, options.retryCount ?? getRequestRetryCount)) + 1 : 1;
  let lastError: unknown;

  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    try {
      requireRequestTime(signal, deadline);
      return await rawRequestAttempt(url, options, method, signal, deadline);
    } catch (error) {
      lastError = error;
      if (signal.aborted || Date.now() >= deadline || attempt >= maxAttempts || !isRetryableRequestError(error)) {
        throw normalizeApiRequestError(error);
      }
      const retryDelayMs = Math.max(requestRetryDelayMs * attempt,
        error instanceof ApiRequestError ? error.retryAfterMs ?? 0 : 0);
      // Preserve the server error when its requested wait cannot fit. Starting
      // another request early would violate throttling and amplify an outage.
      if (retryDelayMs >= deadline - Date.now()) {
        throw normalizeApiRequestError(error);
      }
      await delay(retryDelayMs);
    }
  }

  throw normalizeApiRequestError(lastError);
}

async function rawRequestAttempt(url: string, options: RequestOptions, method: string, signal: AbortSignal, deadline: number): Promise<string> {
  const headers: Record<string, string> = {
    Accept: 'application/json',
  };
  if (options.accessToken) {
    headers.Authorization = `Bearer ${options.accessToken}`;
  }
  if (options.idempotencyKey) {
    headers['Idempotency-Key'] = options.idempotencyKey;
  }
  
  // Merge client headers
  const versionHeaders = await clientVersionHeaders();
  requireRequestTime(signal, deadline);
  Object.assign(headers, versionHeaders);
  
  if (options.headers) {
    Object.assign(headers, options.headers);
  }

  const init: RequestInit = {
    headers,
    method,
    // Neither credentials nor a mutation body may be replayed by the platform.
    redirect: 'manual',
  };

  if (options.body) {
    headers['Content-Type'] = 'application/json';
    init.body = JSON.stringify(options.body);
  }

  try {
    let response;
    if (shouldLogApiRequests && !options.suppressErrorLog) {
      logApiDebug(`API Request: [${init.method || 'GET'}] ${url}`);
    }
    
    // Preserve global instrumentation (including Sentry) on the SDK default.
    // Legacy RN fetch ignores redirect policy, so use the installed Expo API
    // only when that explicit native opt-out is enabled.
    const useLegacyRNFetch = Platform.OS !== 'web' && (
      process.env.EXPO_PUBLIC_USE_RN_FETCH === '1' || process.env.EXPO_PUBLIC_USE_RN_FETCH === 'true'
    );
    response = useLegacyRNFetch
      ? await expoFetch(url, { ...init, signal })
      : await fetch(url, { ...init, signal });
    requireRequestTime(signal, deadline);
    if (response.type === 'opaqueredirect' || [301, 302, 303, 307, 308].includes(response.status)) {
      throw new ApiRequestError('Не удалось выполнить запрос. Попробуйте позже.', {
        status: response.status || undefined,
        code: 'api_redirect_blocked',
      });
    }
    
    if (shouldLogApiRequests && !options.suppressErrorLog) {
      logApiDebug(`API Response: ${response.status} ${response.statusText}`);
    }
    const text = await response.text();
    requireRequestTime(signal, deadline);
    if (!response.ok) {
      const apiError = readApiErrorPayload(text);
      throw new ApiRequestError(apiError.message ?? `HTTP ${response.status}`, {
        status: response.status,
        code: apiError.code,
        retryAfterMs: parseRetryAfterMs(response.headers?.get('Retry-After') ?? null),
      });
    }
    return text;
  } catch (error: unknown) {
    if (shouldLogApiRequests && !options.suppressErrorLog) {
      const message = error instanceof Error ? error.message : String(error);
      logApiDebug('API Outer Catch Error:', message);
    }
    if (error instanceof Error && error.name === 'AbortError') {
      throw new ApiRequestError('Превышено время ожидания API.', { code: 'request_timeout' });
    }
    throw error;
  }
}

function isRetryableRequestError(error: unknown): boolean {
  if (!(error instanceof Error)) {
    return false;
  }
  if (error instanceof ApiRequestError) {
    if (error.status) {
      return error.status === 429 || isMaintenanceStatus(error.status);
    }
    if (error.code === 'network_unavailable' || error.code === 'request_timeout') {
      return true;
    }
  }
  const message = error.message.toLowerCase();
  return error.name === 'AbortError'
    || message.includes('fetch request has been canceled')
    || message.includes('превышено время ожидания api')
    || message.includes('network request failed')
    || message.includes('failed to fetch')
    || message.includes('load failed')
    || message.includes('unable to resolve host')
    || message.includes('could not connect')
    || message.includes('connection refused')
    || message.includes('connection reset');
}

export function parseRetryAfterMs(value: string | null, now = Date.now()): number | undefined {
  const trimmed = value?.trim();
  if (!trimmed) return undefined;
  if (/^\d+$/.test(trimmed)) {
    const milliseconds = Number(trimmed) * 1000;
    return Number.isFinite(milliseconds) ? milliseconds : undefined;
  }
  // HTTP-date form; reject malformed numeric values rather than interpreting
  // them as dates (Date.parse accepts values such as "-1").
  if (!/^[A-Za-z]{3},\s/.test(trimmed)) return undefined;
  const timestamp = Date.parse(trimmed);
  return Number.isFinite(timestamp) ? Math.max(0, timestamp - now) : undefined;
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function logApiDebug(...items: unknown[]) {
  console.log(...items);
}

export function parseApiError(text: string): string | null {
  return readApiErrorPayload(text).message ?? null;
}



export function absolutizeUrl(value: string): string {
  if (!value) {
    return '';
  }
  if (/^https?:\/\//i.test(value)) {
    return value;
  }
  if (value.startsWith('/')) {
    return apiRequestUrl(value);
  }
  return apiRequestUrl(`/${value}`);
}

export async function clientVersionHeaders(): Promise<Record<string, string>> {
  const [appInfo, deviceId] = await Promise.all([getAppInfo(), getOrCreateDeviceId()]);
  const experimentalAndroidRouting = androidExperimentalRoutingEnabled(
    Platform.OS,
    process.env.EXPO_PUBLIC_VEX_ANDROID_EXPERIMENTAL_ROUTING,
  );
  return {
    'X-Vex-Platform': androidProfilePlatform(appInfo.platform, experimentalAndroidRouting),
    'X-Vex-App-Version': appInfo.version,
    'X-Vex-Build-Number': appInfo.build || '0',
    'X-Vex-Core-Version': appInfo.coreVersion,
    'X-Vex-Channel': appInfo.channel,
    'X-Vex-Device-ID': deviceId,
    'X-Vex-OS-Version': `${appInfo.platform} ${String(Platform.Version ?? '')}`,
    'X-Vex-API-Client-Version': appInfo.apiClientVersion,
    'X-Vex-Config-Schema-Version': String(appInfo.configSchemaVersion),
  };
}
