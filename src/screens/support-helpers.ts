import type { SupportMessage, SupportTicket } from "@/api/vexApi";

export const duplicateSupportMessageWindowMs = 10_000;
export const collapsedSupportMessageLength = 360;
export const collapsedSupportMessageLines = 8;
export const supportNetworkErrorMessage =
  "Нет соединения с сервером VEX. Проверьте интернет или отключите VPN и попробуйте снова.";
export const supportTopics = [
  "Не подключается",
  "Оплата",
  "Конфиг",
  "Скорость",
];

export type SupportChatItem =
  | { type: "message"; message: SupportMessage }
  | { type: "diagnosticGroup"; id: string; messages: SupportMessage[] };

export function supportHistoryErrorMessage(error: unknown): string | null {
  const message =
    error instanceof Error && error.message
      ? error.message
      : String(error || "Не удалось загрузить чат поддержки.");
  if (isSupportNetworkError(message)) {
    return supportNetworkErrorMessage;
  }
  return message.toLowerCase() === "not found" ? null : message;
}

function isSupportNetworkError(message: string): boolean {
  const normalized = message.toLowerCase();
  return (
    normalized.includes("fetch failed") ||
    normalized.includes("network request failed") ||
    normalized.includes("unable to resolve host") ||
    normalized.includes("no address associated with hostname")
  );
}

export function supportConnectionStatusText(
  status: "connecting" | "online" | "reconnecting" | "offline",
) {
  if (status === "online") return "в сети";
  if (status === "offline") return "нужен вход";
  if (status === "reconnecting") return "обновляем чат...";
  return "подключаемся...";
}

export function buildSupportSubject(value: string) {
  const firstLine = value.split(/\r?\n/).find(Boolean)?.trim();
  if (!firstLine) return "Вопрос в поддержку";
  return firstLine.length > 46 ? `${firstLine.slice(0, 43)}...` : firstLine;
}

export function optimisticSupportTicket(
  subject: string,
  body: string,
): SupportTicket {
  const now = new Date().toISOString();
  const id = `optimistic-support-${Date.now()}`;
  return {
    id,
    subject,
    message: body,
    messages: [
      {
        id: `${id}-message`,
        ticketId: id,
        sender: "user",
        body,
        createdAt: now,
      },
    ],
    status: "open",
    source: "mobile",
    createdAt: now,
    updatedAt: now,
  };
}

export function supportChatMessages(
  tickets: SupportTicket[],
): SupportMessage[] {
  const messages = tickets.flatMap((ticket) => {
    const items = ticket.messages?.length
      ? ticket.messages
      : legacySupportTicketMessages(ticket);
    return items.map((item) => ({
      ...item,
      status: ticket.status,
      subject: ticket.subject,
    }));
  });
  return uniqueSupportMessages(
    messages.sort(
      (left, right) =>
        supportMessageTimestamp(left) - supportMessageTimestamp(right),
    ),
  );
}

export function supportChatItems(
  messages: SupportMessage[],
): SupportChatItem[] {
  const items: SupportChatItem[] = [];
  let diagnostics: SupportMessage[] = [];

  const flushDiagnostics = () => {
    if (!diagnostics.length) return;
    if (diagnostics.length === 1) {
      items.push({ type: "message", message: diagnostics[0] });
    } else {
      items.push({
        type: "diagnosticGroup",
        id: supportDiagnosticGroupKey(diagnostics),
        messages: diagnostics,
      });
    }
    diagnostics = [];
  };

  for (const message of messages) {
    if (isSupportDiagnosticMessage(message.body)) {
      diagnostics.push(message);
      continue;
    }
    flushDiagnostics();
    items.push({ type: "message", message });
  }
  flushDiagnostics();
  return items;
}

export function supportDiagnosticGroupKey(messages: SupportMessage[]) {
  const first = messages[0];
  const last = messages[messages.length - 1];
  return [
    "diagnostics",
    first.ticketId,
    first.createdAt,
    last.createdAt,
    messages.length,
  ].join(":");
}

export function legacySupportTicketMessages(
  ticket: SupportTicket,
): SupportMessage[] {
  const messages: SupportMessage[] = [];
  if (ticket.message?.trim()) {
    messages.push({
      id: `${ticket.id}-user`,
      ticketId: ticket.id,
      sender: "user",
      body: ticket.message,
      createdAt: ticket.createdAt,
    });
  }
  if (ticket.adminNote?.trim()) {
    messages.push({
      id: `${ticket.id}-admin`,
      ticketId: ticket.id,
      sender: "admin",
      body: ticket.adminNote,
      createdAt: ticket.updatedAt || ticket.createdAt,
    });
  }
  return messages;
}

export function uniqueSupportMessages<TMessage extends SupportMessage>(
  messages: TMessage[],
): TMessage[] {
  const seen = new Set<string>();
  return removeNearDuplicateMessages(
    messages.filter((message) => {
      const key = supportMessageKey(message);
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    }),
  );
}

export function removeNearDuplicateMessages<TMessage extends SupportMessage>(
  messages: TMessage[],
): TMessage[] {
  return messages.filter((message, index) => {
    const previous = messages[index - 1];
    if (!previous) return true;
    return !isNearDuplicateMessage(previous, message);
  });
}

export function isNearDuplicateMessage(
  left: SupportMessage,
  right: SupportMessage,
) {
  if (left.sender !== right.sender) return false;
  if (
    normalizeSupportMessageBody(left.body) !==
    normalizeSupportMessageBody(right.body)
  )
    return false;
  return (
    Math.abs(supportMessageTimestamp(left) - supportMessageTimestamp(right)) <=
    duplicateSupportMessageWindowMs
  );
}

export function normalizeSupportMessageBody(body: string) {
  return body.trim().replace(/\s+/g, " ").toLowerCase();
}

export function supportMessageKey(message: SupportMessage) {
  return [
    message.id,
    message.ticketId,
    message.sender,
    message.createdAt,
    message.body.trim(),
  ].join(":");
}

export function supportMessageTimestamp(message: SupportMessage) {
  const timestamp = new Date(message.createdAt).getTime();
  return Number.isFinite(timestamp) ? timestamp : 0;
}

export function supportMessageDisplayBody(
  message: SupportMessage,
  expanded: boolean,
) {
  if (expanded || !shouldCollapseSupportMessage(message.body))
    return message.body;
  if (isSupportDiagnosticMessage(message.body))
    return supportDiagnosticPreview(message.body);
  const lines = message.body.split(/\r?\n/);
  const head = lines.slice(0, 5).join("\n");
  const preview =
    head.length > collapsedSupportMessageLength
      ? `${head.slice(0, collapsedSupportMessageLength).trim()}...`
      : `${head.trim()}...`;
  const hiddenLines = Math.max(0, lines.length - 5);
  return hiddenLines
    ? `${preview}\n\nЕще ${hiddenLines} строк диагностики`
    : preview;
}

export function shouldCollapseSupportMessage(body: string) {
  const lines = body.split(/\r?\n/);
  return (
    body.length > collapsedSupportMessageLength ||
    lines.length > collapsedSupportMessageLines
  );
}

export function isSupportDiagnosticMessage(body: string) {
  return (
    body.includes("generated_at:") &&
    (body.includes("check.") || body.includes("status:"))
  );
}

export function supportDiagnosticPreview(body: string) {
  const fields = supportDiagnosticFields(body);
  const lines = ["Автоматическая диагностика"];
  if (fields.status) lines.push(`статус: ${fields.status}`);
  if (fields.reason) lines.push(`причина: ${fields.reason}`);
  if (fields.error) lines.push(`ошибка: ${fields.error}`);
  return lines.join("\n");
}

export function supportDiagnosticGroupBody(
  messages: SupportMessage[],
  expanded: boolean,
) {
  if (expanded) {
    return messages
      .map((message, index) => {
        const preview = supportDiagnosticPreview(message.body).replace(
          "Автоматическая диагностика",
          `Отчет ${index + 1}, ${formatSupportMessageTime(message.createdAt)}`,
        );
        return preview;
      })
      .join("\n\n");
  }
  const latest = messages[messages.length - 1];
  const fields = supportDiagnosticFields(latest.body);
  const lines = [`Автоматическая диагностика (${messages.length})`];
  if (fields.status) lines.push(`последний статус: ${fields.status}`);
  if (fields.reason) lines.push(`последняя причина: ${fields.reason}`);
  return lines.join("\n");
}

export function supportDiagnosticFields(body: string) {
  const values = new Map<string, string>();
  for (const line of body.split(/\r?\n/)) {
    const separator = line.indexOf(":");
    if (separator <= 0) continue;
    values.set(
      line.slice(0, separator).trim(),
      line.slice(separator + 1).trim(),
    );
  }
  return {
    error: body
      .split(/\r?\n/)
      .find((line) => line.startsWith("error="))
      ?.replace(/^error=/, "")
      .trim(),
    reason: values.get("reason"),
    status: values.get("status"),
  };
}

export function toggleSetValue<T>(current: Set<T>, value: T) {
  const next = new Set(current);
  if (next.has(value)) {
    next.delete(value);
  } else {
    next.add(value);
  }
  return next;
}

export function supportNeedsReplyIndicator(tickets: SupportTicket[]) {
  const active = tickets.find(
    (ticket) => !["closed", "resolved"].includes(ticket.status),
  );
  if (!active) return false;
  const messages = active.messages?.length
    ? active.messages
    : legacySupportTicketMessages(active);
  return messages[messages.length - 1]?.sender === "user";
}

export function removeMatchingOptimisticTicket(
  tickets: SupportTicket[],
  ticket: SupportTicket,
) {
  const incomingUserMessages = supportUserMessageBodies(ticket);
  if (!incomingUserMessages.size) return tickets;
  return tickets.filter((item) => {
    if (!item.id.startsWith("optimistic-support-")) return true;
    return !setsOverlap(supportUserMessageBodies(item), incomingUserMessages);
  });
}

export function supportUserMessageBodies(ticket: SupportTicket) {
  const messages = ticket.messages?.length
    ? ticket.messages
    : legacySupportTicketMessages(ticket);
  return new Set(
    messages
      .filter((message) => message.sender === "user")
      .map((item) => item.body.trim())
      .filter(Boolean),
  );
}

export function setsOverlap<T>(left: Set<T>, right: Set<T>) {
  for (const value of left) {
    if (right.has(value)) return true;
  }
  return false;
}

export function upsertSupportTicket(
  tickets: SupportTicket[],
  ticket: SupportTicket,
) {
  const index = tickets.findIndex((item) => item.id === ticket.id);
  if (index < 0) {
    return [...tickets, ticket].sort(
      (left, right) =>
        supportTicketTimestamp(left) - supportTicketTimestamp(right),
    );
  }
  const next = [...tickets];
  next[index] = ticket;
  return next.sort(
    (left, right) =>
      supportTicketTimestamp(left) - supportTicketTimestamp(right),
  );
}

export function supportTicketTimestamp(ticket: SupportTicket) {
  const timestamp = new Date(ticket.updatedAt || ticket.createdAt).getTime();
  return Number.isFinite(timestamp) ? timestamp : 0;
}

export function formatSupportMessageTime(value?: string) {
  const date = value ? new Date(value) : new Date();
  if (Number.isNaN(date.getTime())) return "";
  return new Intl.DateTimeFormat("ru-RU", {
    hour: "2-digit",
    minute: "2-digit",
  }).format(date);
}
