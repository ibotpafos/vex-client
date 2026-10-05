import * as Updates from "expo-updates";
import { Button, Column, Host, Text as UniversalText } from "@expo/ui";
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type PropsWithChildren,
} from "react";
import {
  AppState,
  Platform,
  StyleSheet,
  View,
  type AppStateStatus,
} from "react-native";
import {
  playErrorHaptic,
  playLightImpactHaptic,
  playSelectionHaptic,
  playSuccessHaptic,
} from "@/native/haptics";
import * as SecureStore from "@/native/secureStore";
import { getVpnStatus } from "@/native/vexVpn";
import { canAutomaticallyApplyOtaUpdate } from "@/updates/otaAutoApply";
import {
  createOtaCompletionTarget,
  parseOtaCompletionTarget,
  wasOtaCompletionApplied,
  type OtaCompletionTarget,
} from "@/updates/otaCompletion";
import {
  canRunOtaCheck,
  reloadOtaSafely,
  shouldShowOtaOverlay,
  type OtaPresentationStatus,
} from "@/updates/otaPresentation";

const foregroundCheckThrottleMs = 5 * 60_000;
// The provider now mounts before DeferredStartupOverlays. Keep its former effective delay.
const startupCheckDelayMs = Platform.OS === "android" ? 8_500 : 6_500;
const autoReloadDelayMs = 2_500;
const blockedAutoReloadRetryMs = 15_000;
const completionNoticeMs = 4_000;
const pendingOtaCompletionKey = "vex.ota.pending-completion.v1";

type OtaState = { status: OtaPresentationStatus; message?: string };

type OtaPresentationValue = OtaState & {
  progress: number | null;
  isSupported: boolean;
  isBusy: boolean;
  checkForUpdate: (force?: boolean) => Promise<void>;
  retry: () => void;
  dismiss: () => void;
  reload: () => Promise<boolean>;
};

const OtaPresentationContext = createContext<OtaPresentationValue | null>(null);

export function useOtaPresentation(): OtaPresentationValue | null {
  return useContext(OtaPresentationContext);
}

export function OtaUpdateProvider({ children }: PropsWithChildren) {
  if (
    (Platform.OS !== "android" && Platform.OS !== "ios") ||
    !Updates.isEnabled
  )
    return <>{children}</>;
  return <OtaUpdateProviderContent>{children}</OtaUpdateProviderContent>;
}

function OtaUpdateProviderContent({ children }: PropsWithChildren) {
  const updateState = Updates.useUpdates();
  const [state, setState] = useState<OtaState>({ status: "idle" });
  const [dismissed, setDismissed] = useState(false);
  const runningRef = useRef(false);
  const lastCheckAtRef = useRef(0);
  const statusRef = useRef<OtaPresentationStatus>("idle");
  const nativeBusyRef = useRef(false);
  const newUpdateBusyRef = useRef(false);
  const fetchedTargetRef = useRef<OtaCompletionTarget | null>(null);
  const autoReloadTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const reloadRunningRef = useRef(false);
  newUpdateBusyRef.current =
    updateState.isDownloading || updateState.isUpdatePending;
  // Pending means a downloaded update is ready; it must not disable the safe Apply action.
  nativeBusyRef.current = updateState.isChecking || updateState.isDownloading;

  const setOtaState = useCallback((nextState: OtaState) => {
    statusRef.current = nextState.status;
    setState(nextState);
  }, []);

  useEffect(() => {
    if (!updateState.isUpdatePending) return;
    setDismissed(false);
    setOtaState({ status: "ready" });
  }, [setOtaState, updateState.isUpdatePending]);

  useEffect(() => {
    let cancelled = false;
    void SecureStore.getItemAsync(pendingOtaCompletionKey)
      .then(async (stored) => {
        if (!stored || cancelled) return;
        const target = parseOtaCompletionTarget(stored);
        const applied =
          !newUpdateBusyRef.current &&
          wasOtaCompletionApplied(target, updateState.currentlyRunning);
        const cleared = await SecureStore.deleteItemAsync(
          pendingOtaCompletionKey,
        )
          .then(() => true)
          .catch(() => false);
        if (!cancelled && cleared && applied)
          setOtaState({
            status: target?.type === "rollback" ? "rolled_back" : "updated",
          });
      })
      .catch(() => undefined);
    return () => {
      cancelled = true;
    };
  }, [setOtaState, updateState.currentlyRunning]);

  useEffect(() => {
    if (
      updateState.isDownloading &&
      statusRef.current !== "ready" &&
      statusRef.current !== "restarting"
    )
      setOtaState({ status: "downloading" });
  }, [setOtaState, updateState.isDownloading]);
  useEffect(() => {
    if (updateState.downloadError && statusRef.current === "downloading")
      setOtaState({
        status: "error",
        message:
          "Не удалось скачать обновление. Проверьте подключение и повторите.",
      });
  }, [setOtaState, updateState.downloadError]);
  useEffect(() => {
    if (state.status !== "updated" && state.status !== "rolled_back") return;
    const timer = setTimeout(
      () => setOtaState({ status: "idle" }),
      completionNoticeMs,
    );
    return () => clearTimeout(timer);
  }, [setOtaState, state.status]);

  const checkForUpdate = useCallback(
    async (force = false) => {
      if (
        !canRunOtaCheck({
          dismissed,
          force,
          running: runningRef.current,
          nativeBusy: nativeBusyRef.current,
          status: statusRef.current,
        })
      )
        return;
      const now = Date.now();
      if (!force && now - lastCheckAtRef.current < foregroundCheckThrottleMs)
        return;
      runningRef.current = true;
      lastCheckAtRef.current = now;
      let nextStatus: OtaPresentationStatus = "checking";
      setOtaState({ status: nextStatus });
      try {
        const check = await Updates.checkForUpdateAsync();
        if (!check.isAvailable && !check.isRollBackToEmbedded) {
          setOtaState({ status: "idle" });
          return;
        }
        nextStatus = "downloading";
        setOtaState({ status: nextStatus });
        const fetch = await Updates.fetchUpdateAsync();
        if (fetch.isNew || fetch.isRollBackToEmbedded) {
          fetchedTargetRef.current = createOtaCompletionTarget(
            fetch.isRollBackToEmbedded
              ? { type: "rollback" }
              : { type: "new", updateId: fetch.manifest?.id },
            Updates.runtimeVersion,
          );
          playSuccessHaptic();
          setOtaState({ status: "ready" });
          return;
        }
        setOtaState({ status: "idle" });
      } catch {
        setOtaState(
          nextStatus === "downloading"
            ? {
                status: "error",
                message:
                  "Не удалось скачать обновление. Проверьте подключение и повторите.",
              }
            : { status: "idle" },
        );
      } finally {
        runningRef.current = false;
      }
    },
    [dismissed, setOtaState],
  );

  useEffect(() => {
    const timer = setTimeout(() => {
      void checkForUpdate(true);
    }, startupCheckDelayMs);
    return () => clearTimeout(timer);
  }, [checkForUpdate]);
  useEffect(() => {
    const subscription = AppState.addEventListener(
      "change",
      (nextState: AppStateStatus) => {
        if (nextState === "active") void checkForUpdate();
      },
    );
    return () => subscription.remove();
  }, [checkForUpdate]);

  const retry = useCallback(() => {
    playLightImpactHaptic();
    setDismissed(false);
    lastCheckAtRef.current = 0;
    void checkForUpdate(true);
  }, [checkForUpdate]);

  const dismiss = useCallback(() => {
    playSelectionHaptic();
    setDismissed(true);
    setOtaState({ status: "idle" });
  }, [setOtaState]);

  const reload = useCallback(
    async (): Promise<boolean> =>
      reloadOtaSafely({
        getAppState: () => AppState.currentState,
        canApply: canAutomaticallyApplyOtaUpdate,
        getVpnStatus,
        isReady: () => statusRef.current === "ready" && !runningRef.current,
        lock: reloadRunningRef,
        onBlocked: (message) => setOtaState({ status: "ready", message }),
        performReload: async () => {
          const target =
            createOtaCompletionTarget(
              updateState.downloadedUpdate ?? null,
              Updates.runtimeVersion,
            ) ?? fetchedTargetRef.current;
          try {
            playLightImpactHaptic();
            setOtaState({ status: "restarting" });
            if (target)
              await SecureStore.setItemAsync(
                pendingOtaCompletionKey,
                JSON.stringify(target),
              ).catch(() => undefined);
            await Updates.reloadAsync();
            return true;
          } catch {
            await SecureStore.deleteItemAsync(pendingOtaCompletionKey).catch(
              () => undefined,
            );
            playErrorHaptic();
            setOtaState({
              status: "error",
              message: "Не удалось применить обновление. Попробуйте ещё раз.",
            });
            return false;
          }
        },
      }),
    [setOtaState, updateState.downloadedUpdate],
  );

  useEffect(() => {
    if (state.status !== "ready") {
      if (autoReloadTimerRef.current) clearTimeout(autoReloadTimerRef.current);
      return;
    }
    let cancelled = false;
    const attemptAutomaticReload = async () => {
      autoReloadTimerRef.current = null;
      const reloadStarted = await reload();
      if (!reloadStarted && !cancelled)
        autoReloadTimerRef.current = setTimeout(
          attemptAutomaticReload,
          blockedAutoReloadRetryMs,
        );
    };
    autoReloadTimerRef.current = setTimeout(
      attemptAutomaticReload,
      autoReloadDelayMs,
    );
    return () => {
      cancelled = true;
      if (autoReloadTimerRef.current) clearTimeout(autoReloadTimerRef.current);
    };
  }, [reload, state.status]);

  const progress =
    state.status === "downloading" &&
    typeof updateState.downloadProgress === "number" &&
    Number.isFinite(updateState.downloadProgress)
      ? Math.round(Math.max(0, Math.min(1, updateState.downloadProgress)) * 100)
      : null;
  const value = useMemo<OtaPresentationValue>(
    () => ({
      ...state,
      progress,
      isSupported: true,
      isBusy:
        state.status === "checking" ||
        state.status === "downloading" ||
        state.status === "restarting" ||
        updateState.isChecking ||
        updateState.isDownloading,
      checkForUpdate,
      retry,
      dismiss,
      reload,
    }),
    [
      checkForUpdate,
      dismiss,
      progress,
      reload,
      retry,
      state,
      updateState.isChecking,
      updateState.isDownloading,
    ],
  );
  return (
    <OtaPresentationContext.Provider value={value}>
      {children}
    </OtaPresentationContext.Provider>
  );
}

export function OtaUpdateOverlay() {
  const ota = useOtaPresentation();
  if (!ota || !shouldShowOtaOverlay(ota.status)) return null;
  const isError = ota.status === "error";
  const title =
    ota.status === "updated"
      ? "Обновлено"
      : ota.status === "rolled_back"
        ? "Стабильная версия восстановлена"
        : isError
          ? "Обновление не загрузилось"
          : ota.status === "restarting"
            ? "Применяем обновление"
            : "Загружаем обновление";
  const text =
    ota.status === "updated"
      ? "Новая версия запущена и готова к работе."
      : ota.status === "rolled_back"
        ? "Безопасная встроенная версия запущена и готова к работе."
        : isError
          ? ota.message || "Проверьте подключение и повторите позже."
          : ota.status === "restarting"
            ? "Перезапускаем VEX без установки APK."
            : ota.progress === null
              ? "Скачиваем исправления без переустановки приложения."
              : `Скачиваем исправления: ${ota.progress}%.`;
  return (
    <View pointerEvents="box-none" style={styles.overlay}>
      <Host
        colorScheme="dark"
        seedColor="#22D3EE"
        style={styles.host}
        matchContents={{ vertical: true }}
      >
        <Column spacing={8} style={styles.card}>
          <UniversalText textStyle={styles.eyebrow}>VEX update</UniversalText>
          <UniversalText textStyle={styles.title}>{title}</UniversalText>
          <UniversalText textStyle={styles.text}>{text}</UniversalText>
          {isError ? <Button label="Повторить" onPress={ota.retry} /> : null}
          {isError ? (
            <Button label="Позже" onPress={ota.dismiss} variant="outlined" />
          ) : null}
        </Column>
      </Host>
    </View>
  );
}

const styles = StyleSheet.create({
  overlay: {
    left: 0,
    position: "absolute",
    right: 0,
    top: Platform.OS === "ios" ? 58 : 32,
    zIndex: 50,
  },
  host: { alignSelf: "center", maxWidth: 560, width: "92%" },
  card: {
    backgroundColor: "rgba(7,17,19,0.97)",
    borderColor: "rgba(34,211,238,0.28)",
    borderRadius: 18,
    borderWidth: 1,
    padding: 13,
    shadowColor: "#000000",
    shadowOffset: { height: 8, width: 0 },
    shadowOpacity: 0.22,
    shadowRadius: 18,
  },
  eyebrow: {
    color: "#22D3EE",
    fontSize: 10,
    fontWeight: "900",
    letterSpacing: 0.7,
    textTransform: "uppercase",
  },
  title: { color: "#F4FCFD", fontSize: 15, fontWeight: "900", marginTop: 2 },
  text: {
    color: "#C6D6D9",
    fontSize: 12,
    fontWeight: "700",
    lineHeight: 16,
    marginTop: 3,
  },
});
