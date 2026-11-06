import { NativeModules, Platform } from 'react-native';
import { getAppInfo, getOrCreateDeviceId } from '@/native/appInfo';
import { androidExperimentalRoutingEnabled, androidProfilePlatform } from '@/vpn/androidRoutingSafety';
import { ApiRequestError, isMaintenanceStatus, normalizeApiRequestError } from './error';
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

export const vexApiBaseUrl = trimTrailingSlash(process.env.EXPO_PUBLIC_VEX_API_BASE_URL || 'https://vexguard.app');
const apiRequestBaseUrl = vexApiBaseUrl;

let profileRecoveryDepth = 0;
let recoveryRequestSequence = 0;
type RecoveryReply = { status: number; statusText: string; body: string; headers: Record<string, string> };
type RecoveryModule = {
  requestApiRecovery(id: string, url: string, method: string, headers: Record<string, string>, body: string | null, deadline: number): Promise<RecoveryReply>;
  cancelApiRecovery(id: string): void;
};
type ApiResponse = Pick<Response, 'ok' | 'status' | 'statusText' | 'text'> & { headers: Pick<Headers, 'get'> };

/** Retain VPN capture while a failed connection obtains a fresh first-party profile. */
export async function withProfileRecoveryTransport<T>(operation: () => Promise<T>): Promise<T> {
  profileRecoveryDepth++;
  try { return await operation(); }
  finally { profileRecoveryDepth--; }
}

function recoveryModule(url: string): RecoveryModule | undefined {
  if (Platform.OS !== 'android' || typeof NativeModules === 'undefined') return undefined;
  const module = NativeModules?.VexVpn as RecoveryModule | undefined;
  if (typeof module?.requestApiRecovery !== 'function' || typeof module.cancelApiRecovery !== 'function') return undefined;
  try {
    const parsed = new URL(url);
    if (parsed.protocol !== 'https:' || !['vexguard.app', 'www.vexguard.app', 'api.vexguard.app'].includes(parsed.hostname)
      || (parsed.port !== '' && parsed.port !== '443') || parsed.username || parsed.password || parsed.hash
      || !parsed.pathname.startsWith('/v1/') || decodeURIComponent(parsed.pathname).split('/').some(part => part === '.' || part === '..')) return undefined;
    return module;
  } catch { return undefined; }
}

function recoveryRequest(module: RecoveryModule, url: string, method: string, headers: Record<string, string>,
  body: string | null, signal: AbortSignal, deadline: number): Promise<ApiResponse> {
  requireRequestTime(signal, deadline);
  const id = `api-${Date.now()}-${++recoveryRequestSequence}`;
  return new Promise((resolve, reject) => {
    const abort = () => {
      try { module.cancelApiRecovery(id); } catch { /* Cancellation must still settle the caller. */ }
      reject(new ApiRequestError('Превышено время ожидания API.', { code: 'request_timeout' }));
    };
    signal.addEventListener('abort', abort, { once: true });
    if (signal.aborted) { abort(); signal.removeEventListener('abort', abort); return; }
    Promise.resolve().then(() => {
      requireRequestTime(signal, deadline);
      return module.requestApiRecovery(id, url, method, headers, body, Math.min(deadline, Date.now() + 120_000));
    }).then(reply => {
      requireRequestTime(signal, deadline);
      if (!Number.isInteger(reply?.status) || reply.status < 100 || reply.status > 599 || typeof reply.body !== 'string'
        || !reply.headers || typeof reply.headers !== 'object' || Array.isArray(reply.headers)
        || !Object.values(reply.headers).every(value => typeof value === 'string')) throw new TypeError('Invalid recovery API response');
      resolve({
        ok: reply.status >= 200 && reply.status < 300, status: reply.status, statusText: reply.statusText ?? '',
        text: async () => reply.body,
        headers: { get: name => Object.entries(reply.headers).find(([key]) => key.toLowerCase() === name.toLowerCase())?.[1] ?? null },
      });
    }).catch(error => reject(signal.aborted ? new ApiRequestError('Превышено время ожидания API.', { code: 'request_timeout' }) : error))
      .finally(() => signal.removeEventListener('abort', abort));
  });
}

export async function jsonRequest<T>(path: string, options: RequestOptions = {}): Promise<T> {
  return JSON.parse(await rawRequest(path, options)) as T;
}

export async function rawRequest(path: string, options: RequestOptions = {}): Promise<string> {
  const controller = new AbortController();
  const timeoutMs = options.timeout ?? requestTimeoutMs;
  const deadline = Date.now() + timeoutMs;
  // Capture once; a concurrent recovery ending must not move an in-flight retry.
  const useRecoveryTransport = profileRecoveryDepth > 0;
  let timeout: ReturnType<typeof setTimeout>;
  const expired = new Promise<never>((_, reject) => {
    timeout = setTimeout(() => {
      controller.abort();
      reject(new ApiRequestError('Превышено время ожидания API.', { code: 'request_timeout' }));
    }, timeoutMs);
  });
  try {
    return await Promise.race([requestWithinDeadline(path, options, controller.signal, deadline, useRecoveryTransport), expired]);
  } catch (error) {
    throw normalizeApiRequestError(error);
  } finally {
    clearTimeout(timeout!);
  }
}

function requireRequestTime(signal: AbortSignal, deadline: number): void {
  if (signal.aborted || Date.now() >= deadline) {
    throw new ApiRequestError('Превышено время ожидания API.', { code: 'request_timeout' });
  }
}

async function requestWithinDeadline(path: string, options: RequestOptions, signal: AbortSignal, deadline: number, useRecoveryTransport = false): Promise<string> {
  const method = options.method ?? 'GET';
  const maxAttempts = method === 'GET' ? Math.max(0, Math.min(getRequestRetryCount, options.retryCount ?? getRequestRetryCount)) + 1 : 1;
  let lastError: unknown;

  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    try {
      requireRequestTime(signal, deadline);
      return await rawRequestAttempt(path, options, method, signal, deadline, useRecoveryTransport);
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

async function rawRequestAttempt(path: string, options: RequestOptions, method: string, signal: AbortSignal, deadline: number, useRecoveryTransport = false): Promise<string> {
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
  };

  if (options.body) {
    headers['Content-Type'] = 'application/json';
    init.body = JSON.stringify(options.body);
  }

  try {
    let response;
    if (shouldLogApiRequests && !options.suppressErrorLog) {
      logApiDebug(`API Request: [${init.method || 'GET'}] ${apiRequestBaseUrl}${path}`);
    }
    
    const url = `${apiRequestBaseUrl}${path}`;
    const native = useRecoveryTransport ? recoveryModule(url) : undefined;
    response = native
      ? await recoveryRequest(native, url, method, headers, typeof init.body === 'string' ? init.body : null, signal, deadline)
      : await fetch(url, { ...init, signal });
    requireRequestTime(signal, deadline);
    
    if (shouldLogApiRequests && !options.suppressErrorLog) {
      logApiDebug(`API Response: ${response.status} ${response.statusText}`);
    }
    const text = await response.text();
    requireRequestTime(signal, deadline);
    if (!response.ok) {
      if (shouldLogApiRequests && !options.suppressErrorLog) {
        logApiDebug(`API Error Response: ${text}`);
      }
      const apiError = parseApiErrorPayload(text);
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
  return parseApiErrorPayload(text).message ?? null;
}

function parseApiErrorPayload(text: string): { code?: string; message?: string } {
  try {
    const parsed = JSON.parse(text) as { code?: string; message?: string; error?: string };
    return {
      code: parsed.code?.trim() || undefined,
      message: parsed.message?.trim() || parsed.error?.trim() || undefined,
    };
  } catch {
    const message = text.trim();
    return { message: message || undefined };
  }
}


export function trimTrailingSlash(value: string): string {
  return value.replace(/\/+$/, '');
}

export function absolutizeUrl(value: string): string {
  if (!value) {
    return '';
  }
  if (/^https?:\/\//i.test(value)) {
    return value;
  }
  if (value.startsWith('/')) {
    return `${vexApiBaseUrl}${value}`;
  }
  return `${vexApiBaseUrl}/${value}`;
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
