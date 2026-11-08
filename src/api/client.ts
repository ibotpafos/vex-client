import { fetch as expoFetch } from 'expo/fetch';
import { apiRequestUrl, canonicalWebsiteOrigin, resolveApiOrigins } from './origins';
import { NativeModules, Platform } from 'react-native';
import { getAppInfo, getOrCreateDeviceId } from '@/native/appInfo';
import { androidExperimentalRoutingEnabled, androidProfilePlatform } from '@/vpn/androidRoutingSafety';
import { ApiRequestError, isMaintenanceStatus, normalizeApiRequestError } from './error';
export { isMaintenanceStatus, isTechnicalWorksError, normalizeApiRequestError, technicalWorksMessage } from './error';

export type RequestOptions = {
  signal?: AbortSignal;
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
const shouldLogApiRequests = Platform.OS === 'web' && typeof __DEV__ !== 'undefined' && __DEV__;

// Public web/auth/billing callers retain their canonical origin. Transport is separate.
export const vexApiBaseUrl = canonicalWebsiteOrigin;
// A local proxy override wins over the production default; it never joins failover.
const legacyApiBase = process.env.EXPO_PUBLIC_VEX_API_BASE_URL;
const apiOrigins = resolveApiOrigins(legacyApiBase && /^(https?:\/\/)(localhost|127\.0\.0\.1|\[::1\])(?=[:/]|$)/.test(legacyApiBase)
  ? legacyApiBase : process.env.EXPO_PUBLIC_VEX_API_ORIGIN || legacyApiBase);
// SSE keeps legacy production routing, while local development must stay on its proxy.
export const realtimeApiBaseUrl = apiOrigins.length === 1 ? apiOrigins[0] : canonicalWebsiteOrigin;

let profileRecoveryDepth = 0;
let recoveryRequestSequence = 0;
type RecoveryReply = { status: number; statusText: string; body: string; headers: Record<string, string> };
type RecoveryModule = {
  apiRecoveryHosts?: readonly string[];
  apiRecoveryPreservesHttpErrors?: boolean;
  requestApiRecovery(id: string, url: string, method: string, headers: Record<string, string>, body: string | null, deadline: number): Promise<RecoveryReply>;
  cancelApiRecovery(id: string): void;
};
type MutationModule = {
  apiMutationNoReplay?: boolean;
  requestApiMutation?: RecoveryModule['requestApiRecovery'];
  cancelApiMutation?: RecoveryModule['cancelApiRecovery'];
};
type HttpFailure = { status: number; retryAfterMs?: number };
type RequestState = { httpFailure?: HttpFailure; ambiguousRecovery?: boolean };
const isUnsafeMethod = (method: string) => !['GET', 'HEAD', 'OPTIONS'].includes(method);

// TODO(native acceptance): compile the new bridge and verify physical mutation send
// counts/cancellation before distribution; owner hold permits mocked JS validation only.
function requireMutationModule(): Required<MutationModule> {
  const module = NativeModules?.VexVpn as MutationModule | undefined;
  if (module?.apiMutationNoReplay !== true || typeof module.requestApiMutation !== 'function' || typeof module.cancelApiMutation !== 'function') {
    throw new ApiRequestError('Обновите приложение для безопасных запросов API.', { code: 'native_transport_update_required' });
  }
  return module as Required<MutationModule>;
}

function deadlineError(failure?: HttpFailure, ambiguousRecovery = false): ApiRequestError {
  if (!failure && ambiguousRecovery) return new ApiRequestError('Recovery API response status unavailable', { code: 'recovery_status_ambiguous' });
  return new ApiRequestError(failure ? `HTTP ${failure.status}` : 'Превышено время ожидания API.', {
    status: failure?.status, retryAfterMs: failure?.retryAfterMs, code: 'request_timeout',
  });
}

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
    const legacyHosts = ['vexguard.app', 'www.vexguard.app', 'api.vexguard.app'];
    // New binaries advertise hostnames; old binaries must retain their shipped policy.
    const hosts = Array.isArray(module.apiRecoveryHosts)
      ? module.apiRecoveryHosts.filter(host => [...legacyHosts, 'api2.vexguard.app'].includes(host)) : legacyHosts;
    if (parsed.protocol !== 'https:' || !hosts.includes(parsed.hostname)
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
    }).catch(error => reject(signal.aborted ? deadlineError()
      : module.apiRecoveryPreservesHttpErrors !== true
        ? new ApiRequestError('Recovery API response status unavailable', { code: 'recovery_status_ambiguous' }) : error))
      .finally(() => signal.removeEventListener('abort', abort));
  });
}

/** Expo Fetch (SDK 57) disables redirects in OkHttp and URLSession before forwarding.
 * RN's global Fetch/XHR does not enforce this option. Do not substitute it here.
 */
async function ordinaryRequest(url: string, init: RequestInit, signal: AbortSignal, deadline: number): Promise<ApiResponse> {
  requireRequestTime(signal, deadline);
  try {
    const transport = Platform.OS === 'web' ? fetch : expoFetch;
    return await transport(url, { ...init, signal, redirect: 'error', credentials: 'omit' });
  } catch (error) {
    if (error instanceof Error && /redirect/i.test(error.message)) {
      throw new ApiRequestError('API redirect rejected', { code: 'unsafe_redirect' });
    }
    requireRequestTime(signal, deadline);
    // Expo wraps native DNS/socket errors in FetchError; keep redirect errors terminal.
    if (Platform.OS !== 'web' && error instanceof Error && error.message.startsWith('fetch failed:')) {
      throw new ApiRequestError('Network request failed', { code: 'network_unavailable' });
    }
    throw error;
  }
}

export async function jsonRequest<T>(path: string, options: RequestOptions = {}): Promise<T> {
  return JSON.parse(await rawRequest(path, options)) as T;
}

export async function rawRequest(path: string, options: RequestOptions = {}): Promise<string> {
  if (options.signal?.aborted) throw new ApiRequestError('API request aborted', { code: 'request_aborted' });
  const state: RequestState = {};
  const controller = new AbortController();
  const timeoutMs = options.timeout ?? requestTimeoutMs;
  if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) throw new ApiRequestError('Invalid API deadline', { code: 'request_timeout' });
  const cancel = () => controller.abort();
  options.signal?.addEventListener('abort', cancel, { once: true });
  if (options.signal?.aborted) controller.abort();
  const deadline = Date.now() + timeoutMs;
  // Capture once; a concurrent recovery ending must not move an in-flight retry.
  const useRecoveryTransport = profileRecoveryDepth > 0;
  let timeout: ReturnType<typeof setTimeout>;
  const expired = new Promise<never>((_, reject) => {
    timeout = setTimeout(() => {
      controller.abort();
      reject(deadlineError(state.httpFailure, state.ambiguousRecovery));
    }, timeoutMs);
  });
  const aborted = new Promise<never>((_, reject) => {
    const rejectAbort = () => reject(options.signal?.aborted
      ? new ApiRequestError('API request aborted', { code: 'request_aborted' }) : deadlineError(state.httpFailure, state.ambiguousRecovery));
    controller.signal.addEventListener('abort', rejectAbort, { once: true });
    if (controller.signal.aborted) rejectAbort();
  });
  try {
    return await Promise.race([requestWithinDeadline(path, options, controller.signal, deadline, useRecoveryTransport, state), expired, aborted]);
  } catch (error) {
    throw normalizeApiRequestError(error);
  } finally {
    clearTimeout(timeout!);
    options.signal?.removeEventListener('abort', cancel);
  }
}

function requireRequestTime(signal: AbortSignal, deadline: number): void {
  if (signal.aborted || Date.now() >= deadline) {
    throw new ApiRequestError('Превышено время ожидания API.', { code: 'request_timeout' });
  }
}

async function requestWithinDeadline(path: string, options: RequestOptions, signal: AbortSignal, deadline: number, useRecoveryTransport = false, state: RequestState = {}): Promise<string> {
  const method = (options.method ?? 'GET').toUpperCase();
  // Validate before native header lookups or any credential-bearing I/O.
  apiRequestUrl(apiOrigins[0], path);
  // Check before probes, metadata or credential-bearing I/O. Expo OkHttp can replay bodies.
  if (Platform.OS === 'android' && isUnsafeMethod(method)) {
    requireMutationModule();
    if (apiOrigins.length === 1) {
      throw new ApiRequestError('Запросы через локальный API-прокси на Android недоступны.', { code: 'native_mutation_origin_unsupported' });
    }
  }
  let originIndex = method !== 'GET' && apiOrigins.length > 1
    ? await selectMutationOrigin(signal, deadline, useRecoveryTransport, state) : 0;
  let originLocked = false;
  const maxAttempts = method === 'GET' ? Math.max(0, Math.min(getRequestRetryCount, options.retryCount ?? getRequestRetryCount)) + 1 : 1;
  let lastError: unknown;

  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    try {
      requireRequestTime(signal, deadline);
      const remaining = deadline - Date.now();
      const canFailOver = method === 'GET' && apiOrigins.length > 1 && attempt < maxAttempts;
      const attemptDeadline = canFailOver ? Date.now() + Math.min(8000, remaining / 2) : deadline;
      return await boundedAttempt(path, options, method, signal, attemptDeadline, useRecoveryTransport, apiOrigins[originIndex], false, state);
    } catch (error) {
      lastError = error;
      if (signal.aborted || Date.now() >= deadline || attempt >= maxAttempts || !isRetryableRequestError(error)) {
        throw normalizeApiRequestError(error);
      }
      if (error instanceof ApiRequestError && error.status) originLocked = true;
      const previousOrigin = originIndex;
      if (!originLocked && !(error instanceof ApiRequestError && (error.status || error.code === 'maintenance'))) {
        originIndex = Math.min(originIndex + 1, apiOrigins.length - 1);
      }
      const retryDelayMs = Math.max(originIndex !== previousOrigin ? 0 : requestRetryDelayMs * attempt,
        error instanceof ApiRequestError ? error.retryAfterMs ?? 0 : 0);
      // Preserve the server error when its requested wait cannot fit. Starting
      // another request early would violate throttling and amplify an outage.
      if (retryDelayMs >= deadline - Date.now()) {
        throw normalizeApiRequestError(error);
      }
      if (retryDelayMs > 0) await delay(retryDelayMs, signal);
    }
  }

  throw normalizeApiRequestError(lastError);
}

/** Probe with no bearer, caller headers, device identity, body or idempotency key.
 * Only transport failure can select reserve; any HTTP rejection stops selection.
 * Always probe primary again on the next operation, without sticky fallback state.
 */
async function selectMutationOrigin(signal: AbortSignal, deadline: number, recovery: boolean, state: RequestState): Promise<number> {
  for (let index = 0; index < apiOrigins.length; index++) {
    requireRequestTime(signal, deadline);
    const remaining = deadline - Date.now();
    const probeDeadline = Date.now() + Math.min(4000, remaining / (index === 0 ? 3 : 2));
    try {
      await boundedAttempt('/v1/billing/plans', { suppressErrorLog: true }, 'GET', signal, probeDeadline, recovery, apiOrigins[index], true, state);
      return index;
    } catch (error) {
      if (signal.aborted || Date.now() >= deadline || index === apiOrigins.length - 1
        || (error instanceof ApiRequestError && (error.status || error.code === 'maintenance'))
        || !isRetryableRequestError(error)) throw error;
    }
  }
  throw new ApiRequestError('Network request failed', { code: 'network_unavailable' });
}

async function boundedAttempt(path: string, options: RequestOptions, method: string, signal: AbortSignal,
  deadline: number, recovery: boolean, origin: string, bare = false, state: RequestState = {}): Promise<string> {
  const attempt = new AbortController();
  const abort = () => attempt.abort();
  signal.addEventListener('abort', abort, { once: true });
  if (signal.aborted) attempt.abort();
  let httpFailure: HttpFailure | undefined;
  const legacyRecovery = !isUnsafeMethod(method) && recovery ? recoveryModule(apiRequestUrl(origin, path)) : undefined;
  const bufferedRecovery = Boolean(legacyRecovery);
  const ambiguousRecovery = Boolean(legacyRecovery && legacyRecovery.apiRecoveryPreservesHttpErrors !== true);
  // Even a new buffered native promise cannot expose headers before its body completes.
  state.ambiguousRecovery = bufferedRecovery;
  let timer: ReturnType<typeof setTimeout>;
  const expired = new Promise<never>((_, reject) => {
    timer = setTimeout(() => {
      attempt.abort();
      reject(deadlineError(httpFailure, bufferedRecovery));
    }, Math.max(0, deadline - Date.now()));
  });
  try {
    return await Promise.race([rawRequestAttempt(path, options, method, attempt.signal, deadline, recovery, origin, (status, retryAfterMs) => { httpFailure = { status, retryAfterMs }; state.httpFailure = httpFailure; }, bare), expired]);
  } catch (error) {
    // A failed/aborted denial body must not turn its HTTP policy into a transport failover.
    if (httpFailure) {
      throw new ApiRequestError(error instanceof Error ? error.message : `HTTP ${httpFailure.status}`, {
        ...httpFailure, code: error instanceof ApiRequestError ? error.code : undefined,
      });
    }
    if ((ambiguousRecovery || (bufferedRecovery && error instanceof ApiRequestError && error.code === 'request_timeout'))
      && !(error instanceof ApiRequestError && error.status)) {
      throw new ApiRequestError('Recovery API response status unavailable', { code: 'recovery_status_ambiguous' });
    }
    throw error;
  } finally {
    clearTimeout(timer!);
    signal.removeEventListener('abort', abort);
    attempt.abort();
  }
}

async function rawRequestAttempt(path: string, options: RequestOptions, method: string, signal: AbortSignal, deadline: number, useRecoveryTransport = false, origin = apiOrigins[0], onHttpFailure: (status: number, retryAfterMs?: number) => void = () => {}, bare = false): Promise<string> {
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
  const versionHeaders = bare ? {} : await clientVersionHeaders();
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
      logApiDebug(`API Request: [${init.method || 'GET'}] ${origin}`);
    }
    
    const url = apiRequestUrl(origin, path);
    const native = useRecoveryTransport && !isUnsafeMethod(method) ? recoveryModule(url) : undefined;
    if (Platform.OS === 'android' && isUnsafeMethod(method)) {
      const mutation = requireMutationModule();
      response = await recoveryRequest({
        apiRecoveryPreservesHttpErrors: true,
        requestApiRecovery: mutation.requestApiMutation.bind(mutation),
        cancelApiRecovery: mutation.cancelApiMutation.bind(mutation),
      }, url, method, headers, typeof init.body === 'string' ? init.body : null, signal, deadline);
    } else {
      response = native
        ? await recoveryRequest(native, url, method, headers, typeof init.body === 'string' ? init.body : null, signal, deadline)
        : await ordinaryRequest(url, init, signal, deadline);
    }
    if (response.status >= 400) onHttpFailure(response.status, parseRetryAfterMs(response.headers?.get('Retry-After') ?? null));
    requireRequestTime(signal, deadline);
    
    if (shouldLogApiRequests && !options.suppressErrorLog) {
      logApiDebug(`API Response: ${response.status} ${response.statusText}`);
    }
    if (('redirected' in response && response.redirected) || ('url' in response && response.url && new URL(String(response.url)).origin !== origin)
      || (response.status >= 300 && response.status < 400)) {
      throw new ApiRequestError('API redirect rejected', { code: 'unsafe_redirect' });
    }
    const text = await response.text();
    requireRequestTime(signal, deadline);
    if (!response.ok) {
      if (shouldLogApiRequests && !options.suppressErrorLog) {
        logApiDebug(`API Error Response: ${response.status}`);
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
      logApiDebug('API request failed');
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
    if (['maintenance', 'recovery_status_ambiguous', 'native_transport_update_required', 'native_mutation_origin_unsupported'].includes(error.code ?? '')) return false;
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

function delay(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    const abort = () => { clearTimeout(timer); reject(new ApiRequestError('API request aborted', { code: 'request_aborted' })); };
    const timer = setTimeout(() => { signal.removeEventListener('abort', abort); resolve(); }, ms);
    signal.addEventListener('abort', abort, { once: true });
    if (signal.aborted) abort();
  });
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
