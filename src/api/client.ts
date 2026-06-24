import { Platform } from 'react-native';
import { getAppInfo, getOrCreateDeviceId } from '@/native/appInfo';
import { isTauriRuntime } from '@/native/tauriPlatform';
export { isTauriRuntime };

export type RequestOptions = {
  accessToken?: string;
  body?: Record<string, unknown>;
  headers?: Record<string, string>;
  idempotencyKey?: string;
  method?: string;
  suppressErrorLog?: boolean;
  timeout?: number;
};

const requestTimeoutMs = 30000;
const getRequestRetryCount = 2;
const requestRetryDelayMs = 600;
const shouldLogApiRequests = typeof __DEV__ !== 'undefined' && __DEV__;
let tauriFetchPromise: Promise<typeof import('@tauri-apps/plugin-http').fetch> | null = null;

export const vexApiBaseUrl = trimTrailingSlash(process.env.EXPO_PUBLIC_VEX_API_BASE_URL || 'https://vexguard.app');
const apiRequestBaseUrl = vexApiBaseUrl;


async function tauriHttpFetch() {
  tauriFetchPromise ??= import('@tauri-apps/plugin-http').then((module) => module.fetch);
  return tauriFetchPromise;
}

export async function jsonRequest<T>(path: string, options: RequestOptions = {}): Promise<T> {
  return JSON.parse(await rawRequest(path, options)) as T;
}

export async function rawRequest(path: string, options: RequestOptions = {}): Promise<string> {
  const method = options.method ?? 'GET';
  const maxAttempts = method === 'GET' ? getRequestRetryCount + 1 : 1;
  let lastError: unknown;

  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    try {
      return await rawRequestAttempt(path, options, method);
    } catch (error) {
      lastError = error;
      if (attempt >= maxAttempts || !isRetryableRequestError(error)) {
        throw error;
      }
      await delay(requestRetryDelayMs * attempt);
    }
  }

  throw lastError;
}

async function rawRequestAttempt(path: string, options: RequestOptions, method: string): Promise<string> {
  const controller = new AbortController();
  const timeoutMs = options.timeout ?? requestTimeoutMs;
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
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
    const isTauri = isTauriRuntime();
    if (shouldLogApiRequests && !options.suppressErrorLog) {
      logApiDebug(`API Request: [${init.method || 'GET'}] ${apiRequestBaseUrl}${path} isTauri: ${isTauri}`);
    }
    
    if (isTauri) {
      try {
        const tauriFetch = await tauriHttpFetch();
        response = await withTimeout(
          tauriFetch(`${apiRequestBaseUrl}${path}`, { headers, method, body: init.body, connectTimeout: timeoutMs }),
          timeoutMs,
        );
      } catch (err: unknown) {
        if (shouldLogApiRequests && !options.suppressErrorLog) {
          const message = err instanceof Error ? err.message : String(err);
          logApiDebug('Tauri fetch error details:', message);
        }
        throw err;
      }
    } else {
      response = await fetch(`${apiRequestBaseUrl}${path}`, { ...init, signal: controller.signal });
    }
    
    if (shouldLogApiRequests && !options.suppressErrorLog) {
      logApiDebug(`API Response: ${response.status} ${response.statusText}`);
    }
    const text = await response.text();
    if (!response.ok) {
      if (shouldLogApiRequests && !options.suppressErrorLog) {
        logApiDebug(`API Error Response: ${text}`);
      }
      throw new Error(parseApiError(text) ?? `HTTP ${response.status}`);
    }
    return text;
  } catch (error: unknown) {
    if (shouldLogApiRequests && !options.suppressErrorLog) {
      const message = error instanceof Error ? error.message : String(error);
      logApiDebug('API Outer Catch Error:', message);
    }
    if (error instanceof Error && error.name === 'AbortError') {
      throw new Error('Превышено время ожидания API.');
    }
    throw error;
  } finally {
    clearTimeout(timeout);
  }
}

function isRetryableRequestError(error: unknown): boolean {
  if (!(error instanceof Error)) {
    return false;
  }
  const message = error.message.toLowerCase();
  return error.name === 'AbortError'
    || message.includes('fetch request has been canceled')
    || message.includes('превышено время ожидания api')
    || message.includes('network request failed')
    || message.includes('unable to resolve host');
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function withTimeout<T>(promise: Promise<T>, timeoutMs: number): Promise<T> {
  let timeout: ReturnType<typeof setTimeout> | null = null;
  const timeoutPromise = new Promise<never>((_, reject) => {
    timeout = setTimeout(() => reject(new Error('Превышено время ожидания API.')), timeoutMs);
  });
  return Promise.race([promise, timeoutPromise]).finally(() => {
    if (timeout) {
      clearTimeout(timeout);
    }
  });
}

function logApiDebug(...items: unknown[]) {
  console.log(...items);
}

export function parseApiError(text: string): string | null {
  try {
    const parsed = JSON.parse(text) as { message?: string };
    return parsed.message?.trim() || null;
  } catch {
    return null;
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
  return {
    'X-Vex-Platform': appInfo.platform,
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
