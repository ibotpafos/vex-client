import { apiFetch } from '../api/apiFetch';
import {
  customerRealtimeMetadata,
  customerRealtimeReconnectDelay,
  CustomerSSEParser,
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

type RealtimeRequest = { abort(): void };

export class CustomerRealtimeTransport {
  private static readonly livenessDeadlineMilliseconds = 45_000;
  // XHR retains the whole responseText; retire the response at the next progress callback.
  private static readonly maximumResponseLength = 1024 * 1024;
  private readonly options: CustomerRealtimeTransportOptions;
  private active = false;
  private request: RealtimeRequest | null = null;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private reconnectGeneration = 0;
  private watchdogTimer: ReturnType<typeof setTimeout> | null = null;
  private watchdogGeneration = 0;
  private reconnectAttempt = 0;
  private processedLength = 0;
  private parser = new CustomerSSEParser();
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
    this.parser = new CustomerSSEParser();
    request?.abort();
    this.options.onStatus(false);
  }

  private connect(): void {
    if (!this.active || this.request) return;
    this.clearReconnect();
    const url = `${this.options.baseUrl.replace(/\/+$/, '')}/v1/events`;
    const headers: Record<string, string> = {
      Accept: 'text/event-stream', Authorization: `Bearer ${this.options.accessToken}`, 'Cache-Control': 'no-cache',
    };
    if (this.lastEventId) headers['Last-Event-ID'] = this.lastEventId;
    if (!this.options.createRequest) {
      void this.connectFetch(url, headers);
      return;
    }
    // Preserve explicitly injected XHR clients. The default owns a streaming
    // response rather than retaining a cumulative native responseText.
    const request = this.options.createRequest();
    this.request = request;
    this.processedLength = 0;
    this.parser = new CustomerSSEParser();
    request.open('GET', url, true);
    for (const [name, value] of Object.entries(headers)) request.setRequestHeader(name, value);
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
    if (this.active && this.request === request) this.armWatchdog(request);
  }

  private async connectFetch(url: string, headers: Record<string, string>): Promise<void> {
    const controller = new AbortController();
    let reader: ReadableStreamDefaultReader<Uint8Array> | undefined;
    let aborted = false;
    const request: RealtimeRequest = { abort() {
      if (aborted) return;
      aborted = true;
      controller.abort();
      if (reader) {
        void reader.cancel().catch(() => {});
        reader.releaseLock();
      }
    } };
    this.request = request;
    this.parser = new CustomerSSEParser();
    this.armWatchdog(request);
    try {
      const response = await apiFetch(url, { method: 'GET', headers, signal: controller.signal });
      if (!this.active || this.request !== request) {
        void response.body?.cancel().catch(() => {});
        return;
      }
      // A redirect must not dispatch events or initiate credential recovery.
      if (response.type === 'opaqueredirect' || response.status !== 200) {
        this.finish(request, response.status === 401);
        return;
      }
      reader = response.body?.getReader();
      if (!reader) return;
      const decoder = new TextDecoder();
      while (this.active && this.request === request) {
        const { done, value } = await reader.read();
        if (!this.active || this.request !== request) return;
        if (done) {
          this.consumeChunk(request, decoder.decode());
          return;
        }
        // Decode a bounded slice even when the native boundary returns one
        // large chunk. The existing parser separately bounds each SSE frame.
        for (let offset = 0; offset < value.length; offset += 16 * 1024) {
          if (!this.active || this.request !== request) return;
          this.consumeChunk(request, decoder.decode(value.subarray(offset, offset + 16 * 1024), { stream: true }));
        }
      }
    } catch {
      // Network, parser and retired-reader errors use the same owned finish.
    } finally {
      this.finish(request, false);
      request.abort();
    }
  }

  private consume(request: XMLHttpRequestLike): void {
    if (!this.active || this.request !== request) return;
    const response = request.responseText;
    if (response.length < this.processedLength) return;
    const end = Math.min(response.length, CustomerRealtimeTransport.maximumResponseLength);
    const chunk = response.slice(this.processedLength, end);
    this.processedLength = end;
    this.consumeChunk(request, chunk);
    if (response.length >= CustomerRealtimeTransport.maximumResponseLength) this.finish(request, false);
  }

  private consumeChunk(request: RealtimeRequest, chunk: string): void {
    const events = this.parser.append(chunk);
    this.armWatchdog(request);
    for (const event of events) {
      if (!this.active || this.request !== request) return;
      const metadata = customerRealtimeMetadata(event.type, event.data);
      if (!metadata) continue;
      if (event.type === 'customer.session.revoked') {
        if (event.id) this.lastEventId = event.id;
        this.options.onEvent(event);
        if (!this.active || this.request !== request) return;
        this.options.onSessionRevoked();
        if (!this.active || this.request !== request) return;
        this.active = false;
        this.finish(request, false);
        return;
      }
      this.reconnectAttempt = 0;
      this.options.onStatus(true);
      if (!this.active || this.request !== request) return;
      if (event.id) this.lastEventId = event.id;
      this.options.onEvent(event);
    }
    if (this.parser.hasExceededFrameLimit) {
      this.finish(request, false);
    }
  }

  private finish(request: RealtimeRequest, sessionRejected: boolean): void {
    if (this.request !== request) return;
    this.request = null;
    this.parser = new CustomerSSEParser();
    this.clearReconnect();
    const generation = this.reconnectGeneration;
    this.clearWatchdog();
    request.abort();
    this.options.onStatus(false);
    if (generation !== this.reconnectGeneration || !this.active) return;
    if (sessionRejected) {
      this.active = false;
      this.options.onSessionRevoked();
      return;
    }
    const delay = customerRealtimeReconnectDelay(this.reconnectAttempt++);
    const schedule = this.options.schedule ?? setTimeout;
    this.reconnectTimer = schedule(() => {
      if (generation !== this.reconnectGeneration) return;
      this.reconnectTimer = null;
      this.connect();
    }, delay);
  }

  private clearReconnect(): void {
    this.reconnectGeneration += 1;
    if (this.reconnectTimer === null) return;
    (this.options.cancelSchedule ?? clearTimeout)(this.reconnectTimer);
    this.reconnectTimer = null;
  }

  private armWatchdog(request: RealtimeRequest): void {
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
