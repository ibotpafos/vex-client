// Anonymous, independently hosted status. Never use the authenticated API client.
export const independentServiceStatusURL = 'https://incy.vexguard.app/vex-service-status.json';
export const independentServiceStatusPageURL = 'https://incy.vexguard.app/service-status';
export const serviceStatusRefreshMs = 15_000;
export const serviceStatusDeadlineMs = 3_000;

export type IndependentServiceStatus = {
  schema: 'vex.service-status.v1';
  status: 'operational' | 'maintenance' | 'unknown';
  title: string;
  message: string;
  checked_at: string;
  expires_at: string;
  started_at?: string;
  incident_id?: string;
};
export type IndependentStatusState = {
  report: IndependentServiceStatus | null;
  unavailable: boolean;
  checkedAt: number;
};
export const initialIndependentStatus: IndependentStatusState = { report: null, unavailable: false, checkedAt: 0 };

const timestampPattern = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/;
function timestamp(value: unknown): number {
  if (typeof value !== 'string' || !timestampPattern.test(value)) return Number.NaN;
  const calendar = Date.parse(value.slice(0, 19) + 'Z');
  if (!Number.isFinite(calendar) || new Date(calendar).toISOString().slice(0, 19) !== value.slice(0, 19)) return Number.NaN;
  return Date.parse(value);
}

export function parseIndependentServiceStatus(value: unknown, now = Date.now()): IndependentServiceStatus | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const item = value as Record<string, unknown>;
  if (item.schema !== 'vex.service-status.v1' || typeof item.status !== 'string' || !['operational', 'maintenance', 'unknown'].includes(item.status)) return null;
  if (typeof item.title !== 'string' || item.title.length > 200 || typeof item.message !== 'string' || item.message.length > 2_000) return null;
  const checked = timestamp(item.checked_at);
  const expires = timestamp(item.expires_at);
  if (!Number.isFinite(checked) || !Number.isFinite(expires) || checked > now || now - checked > 60_000 || expires <= now || expires <= checked || expires - checked > 60_000) return null;
  if (item.started_at !== undefined && (!Number.isFinite(timestamp(item.started_at)) || timestamp(item.started_at) > checked)) return null;
  if (item.incident_id !== undefined && (typeof item.incident_id !== 'string' || (item.incident_id !== '' && !/^[a-zA-Z0-9:_-]{1,128}$/.test(item.incident_id)))) return null;
  if (item.status === 'maintenance' && (!item.title.trim() || !item.message.trim() || !item.incident_id)) return null;
  return item as IndependentServiceStatus;
}

export function updateIndependentStatus(previous: IndependentStatusState, value: unknown, now = Date.now()): IndependentStatusState {
  const report = parseIndependentServiceStatus(value, now);
  if (!report || Date.parse(report.checked_at) < previous.checkedAt) return { ...previous, unavailable: true };
  const checkedAt = Date.parse(report.checked_at);
  // Identical duplicates are a no-op. Equal-clock changes cannot alter evidence
  // or clear a warning after a failed read, even while the old TTL is valid.
  if (checkedAt === previous.checkedAt) {
    const before = previous.report;
    const identical = before && before.checked_at === report.checked_at &&
      before.status === report.status && before.title === report.title && before.message === report.message &&
      before.expires_at === report.expires_at && before.started_at === report.started_at && before.incident_id === report.incident_id;
    return identical ? previous : { ...previous, unavailable: true };
  }
  if (report.status === 'unknown') return { ...previous, unavailable: true, checkedAt };
  return { report, unavailable: false, checkedAt };
}

export function withServiceStatusDeadline<T>(load: (signal: AbortSignal) => Promise<T>, timeoutMs = serviceStatusDeadlineMs): Promise<T> {
  const controller = new AbortController();
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<never>((_resolve, reject) => {
    timer = setTimeout(() => {
      controller.abort();
      reject(new Error('Service status deadline exceeded'));
    }, Math.min(serviceStatusDeadlineMs, Math.max(1, timeoutMs)));
  });
  return Promise.race([Promise.resolve().then(() => load(controller.signal)), deadline]).finally(() => {
    if (timer) clearTimeout(timer);
    controller.abort();
  });
}

export function readIndependentServiceStatus(fetcher: typeof fetch = fetch, timeoutMs = serviceStatusDeadlineMs): Promise<unknown> {
  return withServiceStatusDeadline(async (signal) => {
    const response = await fetcher(independentServiceStatusURL, {
      method: 'GET', credentials: 'omit', redirect: 'error', cache: 'no-store',
      headers: { Accept: 'application/json' }, signal,
    });
    if (!response.ok || response.redirected || (response.url && response.url !== independentServiceStatusURL)) throw new Error('Independent status unavailable');
    if (response.headers.get('content-type')?.split(';')[0]?.trim() !== 'application/json') throw new Error('Independent status content type');
    const size = response.headers.get('content-length');
    if (size && (!/^\d+$/.test(size) || Number(size) > 65_536)) throw new Error('Independent status body exceeds limit');
    const text = await response.text();
    if (text.length > 65_536) throw new Error('Independent status body exceeds limit');
    return JSON.parse(text) as unknown;
  }, timeoutMs);
}

type StatusLifecycle = {
  foreground: (callback: () => void) => () => void;
  schedule: (callback: () => void, delay: number) => () => void;
};

// A single public read survives screen/session changes without storing account data.
export function createIndependentStatusStore(load: () => Promise<unknown>, lifecycle: StatusLifecycle) {
  let snapshot = initialIndependentStatus;
  let pending: Promise<void> | null = null;
  const listeners = new Set<() => void>();
  let stopForeground: (() => void) | undefined;
  let stopTimer: (() => void) | undefined;
  const refresh = () => {
    if (pending) return pending;
    stopTimer?.();
    pending = Promise.resolve().then(load).then((value) => {
      snapshot = updateIndependentStatus(snapshot, value);
    }).catch(() => {
      snapshot = { ...snapshot, unavailable: true };
    }).finally(() => {
      pending = null;
      listeners.forEach((listener) => listener());
      if (listeners.size) stopTimer = lifecycle.schedule(() => { void refresh(); }, serviceStatusRefreshMs);
    });
    return pending;
  };
  return {
    getSnapshot: () => snapshot,
    refresh,
    subscribe(listener: () => void) {
      const subscription = () => listener();
      listeners.add(subscription);
      if (listeners.size === 1) {
        stopForeground = lifecycle.foreground(() => { void refresh(); });
        void refresh();
      }
      return () => {
        listeners.delete(subscription);
        if (!listeners.size) { stopTimer?.(); stopForeground?.(); }
      };
    },
  };
}
