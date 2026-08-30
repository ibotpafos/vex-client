import {
  customerRealtimeMetadata,
  customerRealtimeReconnectDelay,
  parseCustomerSSE,
  type CustomerSSEEvent,
} from './customerRealtimeCore';

type XMLHttpRequestLike = {
  readyState: number;
  responseText: string;
  status: number;
  onabort: XMLHttpRequest['onabort'];
  onerror: XMLHttpRequest['onerror'];
  onload: XMLHttpRequest['onload'];
  onprogress: XMLHttpRequest['onprogress'];
  onreadystatechange: XMLHttpRequest['onreadystatechange'];
  abort(): void;
  open(method: string, url: string, async: boolean): void;
  send(): void;
  setRequestHeader(name: string, value: string): void;
};

export type CustomerRealtimeTransportOptions = {
  accessToken: string;
  baseUrl: string;
  createRequest?: () => XMLHttpRequestLike;
  onEvent: (event: CustomerSSEEvent) => void;
  onSessionRevoked: () => void;
  onStatus: (connected: boolean) => void;
  schedule?: (callback: () => void, milliseconds: number) => ReturnType<typeof setTimeout>;
  cancelSchedule?: (timer: ReturnType<typeof setTimeout>) => void;
};

export class CustomerRealtimeTransport {
  private static readonly livenessDeadlineMilliseconds = 45_000;
  private readonly options: CustomerRealtimeTransportOptions;
  private active = false;
  private request: XMLHttpRequestLike | null = null;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private watchdogTimer: ReturnType<typeof setTimeout> | null = null;
  private watchdogGeneration = 0;
  private reconnectAttempt = 0;
  private processedLength = 0;
  private buffer = '';
  private lastEventId = '';

  constructor(options: CustomerRealtimeTransportOptions) {
    this.options = options;
  }

  start(): void {
    if (this.active) return;
    this.active = true;
    this.connect();
  }

  stop(): void {
    this.active = false;
    this.clearReconnect();
    this.clearWatchdog();
    const request = this.request;
    this.request = null;
    request?.abort();
    this.options.onStatus(false);
  }

  private connect(): void {
    if (!this.active || this.request) return;
    const request = this.options.createRequest?.() ?? new XMLHttpRequest();
    this.request = request;
    this.processedLength = 0;
    this.buffer = '';
    request.open('GET', `${this.options.baseUrl.replace(/\/+$/, '')}/v1/events`, true);
    request.setRequestHeader('Accept', 'text/event-stream');
    request.setRequestHeader('Authorization', `Bearer ${this.options.accessToken}`);
    request.setRequestHeader('Cache-Control', 'no-cache');
    if (this.lastEventId) request.setRequestHeader('Last-Event-ID', this.lastEventId);
    request.onprogress = () => this.consume(request);
    request.onreadystatechange = () => {
      if (request.readyState >= 2 && request.status >= 400) this.finish(request, request.status === 401);
    };
    request.onerror = () => this.finish(request, false);
    request.onload = () => this.finish(request, request.status === 401);
    request.onabort = () => {
      if (this.request === request) this.request = null;
    };
    request.send();
    this.armWatchdog(request);
  }

  private consume(request: XMLHttpRequestLike): void {
    if (this.request !== request || request.responseText.length < this.processedLength) return;
    this.buffer += request.responseText.slice(this.processedLength);
    this.processedLength = request.responseText.length;
    this.armWatchdog(request);
    const parsed = parseCustomerSSE(this.buffer);
    this.buffer = parsed.remainder.slice(-64 * 1024);
    for (const event of parsed.events) {
      const metadata = customerRealtimeMetadata(event.type, event.data);
      if (!metadata) continue;
      if (event.id) this.lastEventId = event.id;
      if (event.type === 'customer.session.revoked') {
        this.options.onEvent(event);
        this.options.onSessionRevoked();
        this.active = false;
        this.finish(request, false);
        return;
      }
      this.reconnectAttempt = 0;
      this.options.onStatus(true);
      this.options.onEvent(event);
    }
  }

  private finish(request: XMLHttpRequestLike, sessionRejected: boolean): void {
    if (this.request !== request) return;
    this.request = null;
    this.clearWatchdog();
    request.abort();
    this.options.onStatus(false);
    if (sessionRejected) {
      this.active = false;
      this.options.onSessionRevoked();
      return;
    }
    if (!this.active) return;
    const delay = customerRealtimeReconnectDelay(this.reconnectAttempt++);
    const schedule = this.options.schedule ?? setTimeout;
    this.reconnectTimer = schedule(() => {
      this.reconnectTimer = null;
      this.connect();
    }, delay);
  }

  private clearReconnect(): void {
    if (this.reconnectTimer === null) return;
    (this.options.cancelSchedule ?? clearTimeout)(this.reconnectTimer);
    this.reconnectTimer = null;
  }

  private armWatchdog(request: XMLHttpRequestLike): void {
    this.clearWatchdog();
    const generation = this.watchdogGeneration;
    const schedule = this.options.schedule ?? setTimeout;
    this.watchdogTimer = schedule(() => {
      if (generation !== this.watchdogGeneration || this.request !== request) return;
      this.watchdogTimer = null;
      this.finish(request, false);
    }, CustomerRealtimeTransport.livenessDeadlineMilliseconds);
  }

  private clearWatchdog(): void {
    this.watchdogGeneration += 1;
    if (this.watchdogTimer === null) return;
    (this.options.cancelSchedule ?? clearTimeout)(this.watchdogTimer);
    this.watchdogTimer = null;
  }
}
