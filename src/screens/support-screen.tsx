import { router } from "expo-router";
import { CheckCheck, ChevronLeft, RefreshCw, Send } from "lucide-react-native";
import React, {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import {
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from "react-native";
import {
  connectSupportSocket,
  createSupportTicket,
  type SupportMessage,
  type SupportSocketHandle,
  type SupportTicket,
  supportTickets,
} from "@/api/vexApi";
import { useSession } from "@/auth/session-context";
import { VexNativeActivityIndicator } from "@/ui/native-activity-indicator";
import { useRenderProfilerMark } from "@/debug/render-profiler";
import {
  playErrorHaptic,
  playLightImpactHaptic,
  playSelectionHaptic,
  playSuccessHaptic,
  playWarningHaptic,
} from "@/native/haptics";
import { vexColors, VexScreen, vexSharedStyles } from "@/ui/vex-ui";
import {
  supportTopics,
  type SupportChatItem,
  supportHistoryErrorMessage,
  supportNetworkErrorMessage,
  supportConnectionStatusText,
  buildSupportSubject,
  optimisticSupportTicket,
  supportChatMessages,
  supportChatItems,
  toggleSetValue,
  supportNeedsReplyIndicator,
  removeMatchingOptimisticTicket,
  upsertSupportTicket,
  supportMessageKey,
  supportDiagnosticGroupBody,
  supportMessageDisplayBody,
  isSupportDiagnosticMessage,
  formatSupportMessageTime,
} from "./support-helpers";

export default function SupportScreen() {
  useRenderProfilerMark("SupportScreen");
  const { session } = useSession();
  const [tickets, setTickets] = useState<SupportTicket[]>([]);
  const [message, setMessage] = useState("");
  const [subject, setSubject] = useState("");
  const [connectionStatus, setConnectionStatus] = useState<
    "connecting" | "online" | "reconnecting" | "offline"
  >("connecting");
  const [isLoading, setIsLoading] = useState(true);
  const [isRefreshing, setIsRefreshing] = useState(false);
  const [isSending, setIsSending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [expandedDiagnosticGroups, setExpandedDiagnosticGroups] = useState<
    Set<string>
  >(() => new Set());
  const [expandedMessages, setExpandedMessages] = useState<Set<string>>(
    () => new Set(),
  );
  const hasResolvedHistoryRef = useRef(false);
  const inputRef = useRef<TextInput | null>(null);
  const socketRef = useRef<SupportSocketHandle | null>(null);
  const threadRef = useRef<ScrollView | null>(null);
  const chatMessages = useMemo(() => supportChatMessages(tickets), [tickets]);
  const chatItems = useMemo(
    () => supportChatItems(chatMessages),
    [chatMessages],
  );
  const needsReply = supportNeedsReplyIndicator(tickets);
  const showTopics = !chatMessages.length && !message.trim();
  const refreshHistory = useCallback(
    async (options?: { quiet?: boolean }) => {
      if (!session?.accessToken) return false;
      const quiet = options?.quiet ?? false;
      if (quiet) {
        setIsRefreshing(true);
      } else {
        setIsLoading(true);
      }
      try {
        const nextTickets = await supportTickets(session.accessToken);
        hasResolvedHistoryRef.current = true;
        setTickets(nextTickets);
        setIsLoading(false);
        setIsRefreshing(false);
        setConnectionStatus("online");
        setError(null);
        return true;
      } catch (requestError: unknown) {
        setIsLoading(false);
        setIsRefreshing(false);
        if (!quiet || !hasResolvedHistoryRef.current) {
          setError(supportHistoryErrorMessage(requestError));
        }
        if (!hasResolvedHistoryRef.current) {
          setConnectionStatus("reconnecting");
        }
        return false;
      }
    },
    [session?.accessToken],
  );

  useEffect(() => {
    if (!session?.accessToken) {
      setTickets([]);
      setIsLoading(false);
      setConnectionStatus("offline");
      setError("Сначала войдите в аккаунт, чтобы написать в поддержку.");
      return undefined;
    }
    setIsLoading(true);
    setError(null);
    setConnectionStatus("connecting");
    hasResolvedHistoryRef.current = false;
    let cancelled = false;
    let connectWatchdog: ReturnType<typeof setTimeout> | null = setTimeout(() => {
      if (cancelled) return;
      setIsLoading(false);
      setConnectionStatus("reconnecting");
      if (!hasResolvedHistoryRef.current) {
        setError(supportNetworkErrorMessage);
      }
    }, 8000);
    const clearConnectWatchdog = () => {
      if (!connectWatchdog) return;
      clearTimeout(connectWatchdog);
      connectWatchdog = null;
    };
    void refreshHistory().finally(() => {
      if (cancelled) return;
      clearConnectWatchdog();
    });
    const socket = connectSupportSocket(session.accessToken, {
      onError(messageText) {
        clearConnectWatchdog();
        setConnectionStatus("reconnecting");
        setIsLoading(false);
        if (!hasResolvedHistoryRef.current) {
          setError(supportHistoryErrorMessage(messageText));
          return;
        }
        setError(null);
        void refreshHistory({ quiet: true });
      },
      onOpen() {
        clearConnectWatchdog();
        setConnectionStatus("online");
        setError(null);
      },
      onReconnect() {
        clearConnectWatchdog();
        setConnectionStatus("reconnecting");
        setIsLoading(false);
        if (hasResolvedHistoryRef.current) {
          setError(null);
          void refreshHistory({ quiet: true });
        }
      },
      onSnapshot(nextTickets) {
        clearConnectWatchdog();
        hasResolvedHistoryRef.current = true;
        setTickets(nextTickets);
        setIsLoading(false);
        setConnectionStatus("online");
        setError(null);
      },
      onTicket(ticket) {
        clearConnectWatchdog();
        hasResolvedHistoryRef.current = true;
        setTickets((current) =>
          upsertSupportTicket(
            removeMatchingOptimisticTicket(current, ticket),
            ticket,
          ),
        );
        setIsLoading(false);
        setConnectionStatus("online");
        setError(null);
      },
    });
    socketRef.current = socket;
    return () => {
      cancelled = true;
      clearConnectWatchdog();
      socket.close();
      if (socketRef.current === socket) {
        socketRef.current = null;
      }
    };
  }, [refreshHistory, session?.accessToken]);

  useEffect(() => {
    if (connectionStatus !== "reconnecting" || !session?.accessToken) {
      return undefined;
    }
    const timer = setInterval(() => {
      void refreshHistory({ quiet: true });
    }, 15_000);
    return () => clearInterval(timer);
  }, [connectionStatus, refreshHistory, session?.accessToken]);

  useEffect(() => {
    requestAnimationFrame(() => {
      threadRef.current?.scrollToEnd({ animated: true });
    });
  }, [chatItems.length, needsReply]);

  const handleToggleDiagnosticGroup = useCallback((id: string) => {
    playSelectionHaptic();
    setExpandedDiagnosticGroups((current) => toggleSetValue(current, id));
  }, []);

  const handleExpandMessage = useCallback((key: string) => {
    playSelectionHaptic();
    setExpandedMessages((current) => {
      const next = new Set(current);
      next.add(key);
      return next;
    });
  }, []);

  const handleSend = useCallback(async () => {
    const body = message.trim();
    if (!body || isSending) {
      playWarningHaptic();
      return;
    }
    if (!session?.accessToken) {
      setError("Сначала войдите в аккаунт.");
      playWarningHaptic();
      return;
    }
    const nextSubject = subject.trim() || buildSupportSubject(body);
    const socket = socketRef.current;
    const optimistic = optimisticSupportTicket(nextSubject, body);
    playLightImpactHaptic();
    setIsSending(true);
    setError(null);
    setMessage("");
    setTickets((current) => upsertSupportTicket(current, optimistic));
    if (socket?.sendMessage({ body, subject: nextSubject })) {
      setSubject("");
      playSuccessHaptic();
      setIsSending(false);
      requestAnimationFrame(() => inputRef.current?.focus());
      return;
    }
    try {
      const ticket = await createSupportTicket(session.accessToken, {
        message: body,
        source: "mobile",
        subject: nextSubject,
      });
      setTickets((current) =>
        upsertSupportTicket(removeMatchingOptimisticTicket(current, ticket), ticket),
      );
      setSubject("");
      setConnectionStatus("online");
      setError(null);
      playSuccessHaptic();
      requestAnimationFrame(() => inputRef.current?.focus());
    } catch (sendError) {
      setTickets((current) =>
        current.filter((item) => item.id !== optimistic.id),
      );
      setMessage(body);
      setError(
        supportHistoryErrorMessage(sendError) ??
          "Чат переподключается, сообщение не отправлено.",
      );
      setConnectionStatus("reconnecting");
      playErrorHaptic();
      requestAnimationFrame(() => inputRef.current?.focus());
    } finally {
      setIsSending(false);
    }
  }, [isSending, message, session?.accessToken, subject]);

  const reconnectHint =
    connectionStatus === "reconnecting"
      ? "Live-обновления временно восстанавливаются. Отправка работает, история обновится автоматически."
      : null;

  return (
    <VexScreen>
      <View style={vexSharedStyles.topBar}>
        <Pressable
          onPress={() => {
            playSelectionHaptic();
            router.dismissTo("/");
          }}
          style={vexSharedStyles.iconButton}
          accessibilityLabel="Назад"
        >
          <ChevronLeft color="#EAF7F8" size={26} strokeWidth={2.4} />
        </Pressable>
        <View style={styles.chatHeader}>
          <View style={styles.chatAvatar}>
            <Text style={styles.chatAvatarText}>V</Text>
          </View>
          <View style={styles.chatHeaderCopy}>
            <Text numberOfLines={1} style={styles.chatTitle}>
              Поддержка VEX
            </Text>
            <Text numberOfLines={1} style={styles.chatStatus}>
              {supportConnectionStatusText(connectionStatus)}
            </Text>
          </View>
        </View>
        <View style={vexSharedStyles.iconButton} />
      </View>

      <View style={styles.chatShell}>
        <ScrollView
          alwaysBounceVertical={false}
          contentContainerStyle={styles.threadContent}
          onContentSizeChange={() =>
            threadRef.current?.scrollToEnd({ animated: true })
          }
          ref={threadRef}
          showsVerticalScrollIndicator={false}
          style={styles.thread}
        >
          <View style={styles.dayPill}>
            <Text style={styles.dayPillText}>Сегодня</Text>
          </View>
          {!chatMessages.length && !isLoading ? (
            <View style={styles.emptyState}>
              <Text style={styles.emptyText}>
                Укажите устройство, ошибку и когда началось. Повторные сообщения
                добавятся в активное обращение.
              </Text>
            </View>
          ) : null}
          {chatItems.map((chatItem) => {
            if (chatItem.type === "diagnosticGroup") {
              return (
                <DiagnosticGroupBubble
                  expanded={expandedDiagnosticGroups.has(chatItem.id)}
                  group={chatItem}
                  key={chatItem.id}
                  onToggle={handleToggleDiagnosticGroup}
                />
              );
            }
            const item = chatItem.message;
            const key = supportMessageKey(item);
            return (
              <MessageBubble
                expanded={expandedMessages.has(key)}
                messageKey={key}
                key={key}
                message={item}
                onExpand={handleExpandMessage}
              />
            );
          })}
          {needsReply ? (
            <View style={styles.bubble}>
              <Text style={styles.bubbleText}>
                Спасибо, сообщение получено. Ответ появится здесь, как только
                специалист возьмет обращение в работу.
              </Text>
            </View>
          ) : null}
        </ScrollView>

        <View style={styles.composer}>
          {showTopics ? (
            <View style={styles.topicRow}>
              {supportTopics.map((topic) => {
                const selected = topic === subject;
                return (
                  <Pressable
                    key={topic}
                    accessibilityLabel={topic}
                    accessibilityRole="button"
                    accessibilityState={{ selected }}
                    onPress={() => {
                      playSelectionHaptic();
                      setSubject(selected ? "" : topic);
                    }}
                    style={[
                      styles.topicButton,
                      selected && styles.topicButtonSelected,
                    ]}
                  >
                    <Text
                      style={[
                        styles.topicText,
                        selected && styles.topicTextSelected,
                      ]}
                    >
                      {topic}
                    </Text>
                  </Pressable>
                );
              })}
            </View>
          ) : null}
          <View style={styles.inputShell}>
            <TextInput
              editable={!isSending}
              onKeyPress={(event) => {
                const nativeEvent =
                  event.nativeEvent as typeof event.nativeEvent & {
                    shiftKey?: boolean;
                  };
                if (nativeEvent.key !== "Enter" || nativeEvent.shiftKey) return;
                event.preventDefault?.();
                void handleSend();
              }}
              multiline
              onChangeText={setMessage}
              placeholder="Напишите сообщение"
              placeholderTextColor="rgba(167,185,189,0.72)"
              ref={inputRef}
              style={styles.input}
              textAlignVertical="top"
              value={message}
            />
            <Pressable
              accessibilityLabel={
                isSending ? "Отправляем сообщение" : "Отправить сообщение"
              }
              accessibilityRole="button"
              disabled={isSending || !message.trim()}
              onPress={handleSend}
              style={[
                styles.inlineSendButton,
                (!message.trim() || isSending) &&
                  styles.inlineSendButtonDisabled,
              ]}
            >
              {isSending ? (
                <VexNativeActivityIndicator color="#031012" size="small" />
              ) : (
                <Send color="#031012" size={19} strokeWidth={2.8} />
              )}
            </Pressable>
          </View>
          {reconnectHint ? (
            <View style={styles.statusHintRow}>
              <Text style={styles.statusHintText}>{reconnectHint}</Text>
              <Pressable
                accessibilityLabel="Обновить чат"
                accessibilityRole="button"
                disabled={isRefreshing}
                onPress={() => {
                  playSelectionHaptic();
                  void refreshHistory({ quiet: true });
                }}
                style={[
                  styles.refreshButton,
                  isRefreshing && styles.refreshButtonDisabled,
                ]}
              >
                {isRefreshing ? (
                  <VexNativeActivityIndicator color={vexColors.accent} size="small" />
                ) : (
                  <RefreshCw
                    color={vexColors.accent}
                    size={15}
                    strokeWidth={2.5}
                  />
                )}
              </Pressable>
            </View>
          ) : null}
          {error ? <Text style={styles.errorText}>{error}</Text> : null}
        </View>
      </View>
    </VexScreen>
  );
}

type DiagnosticGroupBubbleProps = {
  expanded: boolean;
  group: Extract<SupportChatItem, { type: "diagnosticGroup" }>;
  onToggle: (id: string) => void;
};

const DiagnosticGroupBubble = React.memo(function DiagnosticGroupBubble({
  expanded,
  group,
  onToggle,
}: DiagnosticGroupBubbleProps) {
  useRenderProfilerMark("SupportDiagnosticBubble");
  const latestMessage = group.messages[group.messages.length - 1];
  return (
    <View
      style={[
        styles.bubble,
        latestMessage.sender === "user" && styles.bubbleUser,
        styles.bubbleDiagnostic,
        styles.bubbleCollapsed,
      ]}
    >
      <Text
        style={[
          styles.bubbleText,
          latestMessage.sender === "user" && styles.bubbleTextUser,
          styles.bubbleTextDiagnostic,
        ]}
      >
        {supportDiagnosticGroupBody(group.messages, expanded)}
      </Text>
      <Pressable
        accessibilityLabel={
          expanded ? "Скрыть диагностику" : "Показать диагностику"
        }
        accessibilityRole="button"
        onPress={() => onToggle(group.id)}
        style={styles.expandButton}
      >
        <Text style={styles.expandText}>
          {expanded ? "Скрыть" : "Показать отчеты"}
        </Text>
      </Pressable>
      <View style={styles.bubbleMeta}>
        <Text
          style={[
            styles.bubbleTime,
            latestMessage.sender === "user" && styles.bubbleTimeUser,
          ]}
        >
          {formatSupportMessageTime(latestMessage.createdAt)}
        </Text>
        {latestMessage.sender === "user" ? (
          <CheckCheck
            color="rgba(234,247,248,0.72)"
            size={13}
            strokeWidth={2.3}
          />
        ) : null}
      </View>
    </View>
  );
});

type MessageBubbleProps = {
  expanded: boolean;
  message: SupportMessage;
  messageKey: string;
  onExpand: (key: string) => void;
};

const MessageBubble = React.memo(function MessageBubble({
  expanded,
  message,
  messageKey,
  onExpand,
}: MessageBubbleProps) {
  useRenderProfilerMark("SupportMessageBubble");
  const isDiagnostic = isSupportDiagnosticMessage(message.body);
  const body = supportMessageDisplayBody(message, expanded);
  const isCollapsed = body !== message.body;
  return (
    <View
      style={[
        styles.bubble,
        message.sender === "user" && styles.bubbleUser,
        isDiagnostic && styles.bubbleDiagnostic,
        isCollapsed && styles.bubbleCollapsed,
      ]}
    >
      <Text
        style={[
          styles.bubbleText,
          message.sender === "user" && styles.bubbleTextUser,
          isDiagnostic && styles.bubbleTextDiagnostic,
        ]}
      >
        {body}
      </Text>
      {isCollapsed ? (
        <Pressable
          accessibilityLabel="Показать сообщение полностью"
          accessibilityRole="button"
          onPress={() => onExpand(messageKey)}
          style={styles.expandButton}
        >
          <Text style={styles.expandText}>Показать полностью</Text>
        </Pressable>
      ) : null}
      <View style={styles.bubbleMeta}>
        <Text
          style={[
            styles.bubbleTime,
            message.sender === "user" && styles.bubbleTimeUser,
          ]}
        >
          {formatSupportMessageTime(message.createdAt)}
        </Text>
        {message.sender === "user" ? (
          <CheckCheck
            color="rgba(234,247,248,0.72)"
            size={13}
            strokeWidth={2.3}
          />
        ) : null}
      </View>
    </View>
  );
});

const styles = StyleSheet.create({
  chatHeader: {
    alignItems: "center",
    flex: 1,
    flexDirection: "row",
    gap: 9,
    minWidth: 0,
    paddingHorizontal: 4,
  },
  chatAvatar: {
    alignItems: "center",
    backgroundColor: vexColors.accent,
    borderRadius: 17,
    height: 34,
    justifyContent: "center",
    width: 34,
  },
  chatAvatarText: {
    color: "#031012",
    fontSize: 16,
    fontWeight: "900",
  },
  chatHeaderCopy: {
    flex: 1,
    minWidth: 0,
  },
  chatTitle: {
    color: vexColors.text,
    fontSize: 15,
    fontWeight: "900",
  },
  chatStatus: {
    color: vexColors.accent,
    fontSize: 11,
    fontWeight: "800",
    marginTop: 2,
  },
  chatShell: {
    flex: 1,
    gap: 0,
  },
  thread: {
    backgroundColor: "transparent",
    flex: 1,
  },
  threadContent: {
    gap: 7,
    paddingBottom: 10,
    paddingHorizontal: 4,
    paddingTop: 4,
  },
  dayPill: {
    alignSelf: "center",
    backgroundColor: "rgba(7,17,19,0.74)",
    borderColor: "rgba(96,118,123,0.28)",
    borderRadius: 999,
    borderWidth: 1,
    paddingHorizontal: 10,
    paddingVertical: 4,
  },
  dayPillText: {
    color: vexColors.muted,
    fontSize: 11,
    fontWeight: "900",
  },
  emptyState: {
    alignSelf: "center",
    backgroundColor: "rgba(7,17,19,0.74)",
    borderColor: "rgba(96,118,123,0.24)",
    borderRadius: 14,
    borderWidth: 1,
    marginTop: 4,
    maxWidth: "84%",
    paddingHorizontal: 12,
    paddingVertical: 9,
  },
  emptyText: {
    color: vexColors.muted,
    fontSize: 11,
    fontWeight: "700",
    lineHeight: 17,
    textAlign: "center",
  },
  bubble: {
    alignSelf: "flex-start",
    backgroundColor: "rgba(7,17,19,0.92)",
    borderBottomLeftRadius: 5,
    borderBottomRightRadius: 16,
    borderColor: "rgba(96,118,123,0.24)",
    borderRadius: 16,
    borderWidth: 1,
    maxWidth: "82%",
    paddingHorizontal: 11,
    paddingVertical: 7,
  },
  bubbleUser: {
    alignSelf: "flex-end",
    backgroundColor: "rgba(34,211,238,0.24)",
    borderBottomLeftRadius: 16,
    borderBottomRightRadius: 5,
    borderColor: "rgba(34,211,238,0.34)",
  },
  bubbleCollapsed: {
    maxWidth: "78%",
  },
  bubbleDiagnostic: {
    backgroundColor: "rgba(7,17,19,0.78)",
    borderColor: "rgba(96,118,123,0.2)",
  },
  bubbleText: {
    color: vexColors.textSoft,
    fontSize: 14,
    lineHeight: 19,
  },
  bubbleTextDiagnostic: {
    color: "rgba(234,247,248,0.82)",
    fontSize: 12,
    lineHeight: 17,
  },
  bubbleTextUser: {
    color: vexColors.text,
  },
  bubbleTime: {
    color: vexColors.muted,
    fontSize: 10,
    fontWeight: "800",
    textAlign: "right",
  },
  bubbleTimeUser: {
    color: "rgba(234,247,248,0.72)",
  },
  bubbleMeta: {
    alignItems: "center",
    alignSelf: "flex-end",
    flexDirection: "row",
    gap: 3,
    marginTop: 3,
  },
  expandButton: {
    alignSelf: "flex-start",
    marginTop: 8,
    paddingVertical: 2,
  },
  expandText: {
    color: vexColors.accent,
    fontSize: 12,
    fontWeight: "900",
  },
  composer: {
    backgroundColor: "rgba(2,10,11,0.94)",
    borderTopColor: "rgba(96,118,123,0.18)",
    borderTopWidth: 1,
    gap: 8,
    marginHorizontal: -4,
    paddingBottom: 2,
    paddingHorizontal: 4,
    paddingTop: 8,
  },
  topicRow: {
    flexDirection: "row",
    flexWrap: "nowrap",
    gap: 6,
  },
  topicButton: {
    backgroundColor: "rgba(7,17,19,0.86)",
    borderColor: "rgba(96,118,123,0.26)",
    borderRadius: 999,
    borderWidth: 1,
    flex: 1,
    minHeight: 30,
    paddingHorizontal: 6,
    paddingVertical: 6,
  },
  topicButtonSelected: {
    backgroundColor: "rgba(34,211,238,0.18)",
    borderColor: "rgba(34,211,238,0.4)",
  },
  topicText: {
    color: vexColors.muted,
    fontSize: 10,
    fontWeight: "900",
    textAlign: "center",
  },
  topicTextSelected: {
    color: vexColors.accent,
  },
  inputShell: {
    alignItems: "flex-end",
    backgroundColor: "rgba(7,17,19,0.94)",
    borderColor: "rgba(96,118,123,0.32)",
    borderRadius: 22,
    borderWidth: 1,
    flexDirection: "row",
    gap: 8,
    minHeight: 48,
    paddingBottom: 5,
    paddingLeft: 12,
    paddingRight: 5,
    paddingTop: 5,
  },
  input: {
    color: vexColors.text,
    flex: 1,
    fontSize: 14,
    lineHeight: 20,
    maxHeight: 104,
    minHeight: 38,
    paddingBottom: 8,
    paddingTop: 8,
  },
  inlineSendButton: {
    alignItems: "center",
    backgroundColor: vexColors.accent,
    borderRadius: 19,
    height: 38,
    justifyContent: "center",
    width: 38,
  },
  inlineSendButtonDisabled: {
    opacity: 0.48,
  },
  errorText: {
    color: vexColors.danger,
    fontSize: 12,
    fontWeight: "800",
    lineHeight: 17,
  },
  refreshButton: {
    alignItems: "center",
    borderColor: "rgba(34,211,238,0.28)",
    borderRadius: 14,
    borderWidth: 1,
    height: 28,
    justifyContent: "center",
    width: 28,
  },
  refreshButtonDisabled: {
    opacity: 0.58,
  },
  statusHintRow: {
    alignItems: "center",
    flexDirection: "row",
    gap: 8,
  },
  statusHintText: {
    color: vexColors.muted,
    flex: 1,
    fontSize: 12,
    fontWeight: "700",
    lineHeight: 17,
  },
});
