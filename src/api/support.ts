import { jsonRequest, vexApiBaseUrl } from './client';
import { isSupportSocketConnecting } from './supportSocketState';
import {
  type SupportTicket,
  type SupportMessage,
  type SupportSocketHandle,
  type SupportSocketOptions,
  type SupportSocketEnvelope,
  type ServerSupportTicket,
  type ServerSupportMessage,
} from './types';

export async function supportTickets(accessToken: string): Promise<SupportTicket[]> {
  const items = await jsonRequest<ServerSupportTicket[] | null>('/v1/support-tickets', {
    accessToken,
    suppressErrorLog: true,
  });
  return (items ?? []).map(parseSupportTicket);
}

export async function createSupportTicket(
  accessToken: string,
  input: { subject: string; message: string; source?: string },
): Promise<SupportTicket> {
  const item = await jsonRequest<ServerSupportTicket>('/v1/support-tickets', {
    accessToken,
    body: {
      message: input.message,
      source: input.source ?? 'mobile',
      subject: input.subject,
    },
    idempotencyKey: `support-${Date.now()}-${Math.random().toString(16).slice(2)}`,
    method: 'POST',
  });
  return parseSupportTicket(item);
}

export function connectSupportSocket(accessToken: string, options: SupportSocketOptions): SupportSocketHandle {
  let closed = false;
  let connectionIssueReported = false;
  let openTimer: ReturnType<typeof setTimeout> | null = null;
  let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  let socket: WebSocket | null = null;

  const clearOpenTimer = () => {
    if (!openTimer) return;
    clearTimeout(openTimer);
    openTimer = null;
  };

  const reportConnectionIssue = (message: string) => {
    if (connectionIssueReported) return;
    connectionIssueReported = true;
    options.onError?.(message);
  };

  const scheduleReconnect = () => {
    if (closed || reconnectTimer) return;
    options.onReconnect?.();
    reconnectTimer = setTimeout(() => {
      reconnectTimer = null;
      void connect();
    }, 3000);
  };

  const connect = async () => {
    try {
      const url = await supportWebSocketURL(accessToken);
      if (closed) return;
      const nextSocket = new WebSocket(url);
      socket = nextSocket;
      openTimer = setTimeout(() => {
        if (closed || socket !== nextSocket || !isSupportSocketConnecting(nextSocket)) return;
        reportConnectionIssue('Чат поддержки не ответил вовремя, переподключаемся.');
        nextSocket.close();
        scheduleReconnect();
      }, 8000);
      nextSocket.onopen = () => {
        clearOpenTimer();
        connectionIssueReported = false;
        options.onOpen?.();
      };
      nextSocket.onmessage = (event) => dispatchSupportSocketEvent(String(event.data), options);
      nextSocket.onclose = () => {
        clearOpenTimer();
        scheduleReconnect();
      };
      nextSocket.onerror = () => {
        clearOpenTimer();
        reportConnectionIssue('Соединение с чатом прервано, переподключаемся.');
      };
    } catch (error) {
      if (!closed) {
        reportConnectionIssue(apiErrorMessage(error, 'Не удалось подключить чат поддержки.'));
        scheduleReconnect();
      }
    }
  };

  void connect();

  return {
    close() {
      closed = true;
      clearOpenTimer();
      if (reconnectTimer) {
        clearTimeout(reconnectTimer);
      }
      socket?.close();
    },
    sendMessage(message) {
      if (!socket || socket.readyState !== WebSocket.OPEN) return false;
      socket.send(JSON.stringify({
        body: message.body,
        subject: message.subject,
        ticket_id: message.ticketId,
        type: 'support.message',
      }));
      return true;
    },
  };
}


async function supportWebSocketURL(accessToken: string) {
  const payload = await jsonRequest<{ ticket?: string }>('/v1/support-ws-ticket', {
    accessToken,
    suppressErrorLog: true,
  });
  if (!payload.ticket?.trim()) {
    throw new Error('Support websocket ticket missing');
  }
  const url = new URL('/v1/support-ws', vexApiBaseUrl);
  url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
  url.searchParams.set('ticket', payload.ticket);
  return url.toString();
}

function dispatchSupportSocketEvent(data: string, options: SupportSocketOptions) {
  let envelope: SupportSocketEnvelope;
  try {
    envelope = JSON.parse(data) as SupportSocketEnvelope;
  } catch {
    options.onError?.('Получили некорректное событие чата поддержки.');
    return;
  }

  switch (envelope.type) {
    case 'support.snapshot':
      options.onSnapshot?.((envelope.tickets ?? []).map(parseSupportTicket));
      return;
    case 'support.ticket':
      if (envelope.ticket) options.onTicket?.(parseSupportTicket(envelope.ticket));
      return;
    case 'support.error':
      if (envelope.message) options.onError?.(envelope.message);
      return;
  }
}

function apiErrorMessage(error: unknown, fallback: string): string {
  return error instanceof Error && error.message ? error.message : fallback;
}

export function parseSupportTicket(item: ServerSupportTicket): SupportTicket {
  return {
    id: item.id,
    subject: item.subject,
    message: item.message,
    messages: item.messages?.map(parseSupportMessage),
    status: item.status,
    priority: item.priority,
    source: item.source,
    adminNote: item.admin_note,
    createdAt: item.created_at,
    updatedAt: item.updated_at,
    closedAt: item.closed_at,
  };
}

export function parseSupportMessage(item: ServerSupportMessage): SupportMessage {
  return {
    id: item.id,
    ticketId: item.ticket_id,
    sender: parseSupportSender(item.sender),
    authorId: item.author_id,
    body: item.body,
    createdAt: item.created_at,
  };
}

export function parseSupportSender(value: string): SupportMessage['sender'] {
  return value === 'admin' || value === 'system' ? value : 'user';
}
