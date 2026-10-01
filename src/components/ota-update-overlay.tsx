import * as Updates from 'expo-updates';
import { Button, Column, Host, Text as UniversalText } from '@expo/ui';
import { useCallback, useEffect, useRef, useState } from 'react';
import { AppState, Platform, StyleSheet, View, type AppStateStatus } from 'react-native';
import { playErrorHaptic, playLightImpactHaptic, playSelectionHaptic, playSuccessHaptic } from '@/native/haptics';
import * as SecureStore from '@/native/secureStore';
import { getVpnStatus } from '@/native/vexVpn';
import { canAutomaticallyApplyOtaUpdate } from '@/updates/otaAutoApply';
import { createOtaCompletionTarget, parseOtaCompletionTarget, wasOtaCompletionApplied, type OtaCompletionTarget } from '@/updates/otaCompletion';

const foregroundCheckThrottleMs = 5 * 60_000;
const startupCheckDelayMs = 5_000;
const autoReloadDelayMs = 2_500;
const blockedAutoReloadRetryMs = 15_000;
const completionNoticeMs = 4_000;
const pendingOtaCompletionKey = 'vex.ota.pending-completion.v1';

type OtaStatus = 'idle' | 'checking' | 'downloading' | 'ready' | 'restarting' | 'updated' | 'rolled_back' | 'error';

type OtaState = {
  status: OtaStatus;
  message?: string;
};

export function OtaUpdateOverlay() {
  if ((Platform.OS !== 'android' && Platform.OS !== 'ios') || !Updates.isEnabled) {
    return null;
  }

  return <OtaUpdateOverlayContent />;
}

function OtaUpdateOverlayContent() {
  const updateState = Updates.useUpdates();
  const [state, setState] = useState<OtaState>({ status: 'idle' });
  const [dismissed, setDismissed] = useState(false);
  const runningRef = useRef(false);
  const lastCheckAtRef = useRef(0);
  const statusRef = useRef<OtaStatus>('idle');
  const nativeBusyRef = useRef(false);
  const newUpdateBusyRef = useRef(false);
  const fetchedTargetRef = useRef<OtaCompletionTarget | null>(null);
  const autoReloadTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  newUpdateBusyRef.current = updateState.isDownloading || updateState.isUpdatePending;
  nativeBusyRef.current = updateState.isChecking || newUpdateBusyRef.current;

  const setOtaState = useCallback((nextState: OtaState) => {
    statusRef.current = nextState.status;
    setState(nextState);
  }, []);

  useEffect(() => {
    if (!updateState.isUpdatePending) {
      return;
    }
    setDismissed(false);
    setOtaState({ status: 'ready' });
  }, [setOtaState, updateState.isUpdatePending]);

  useEffect(() => {
    let cancelled = false;
    void SecureStore.getItemAsync(pendingOtaCompletionKey)
      .then(async (stored) => {
        if (!stored || cancelled) return;
        const target = parseOtaCompletionTarget(stored);
        const applied = !newUpdateBusyRef.current && wasOtaCompletionApplied(target, updateState.currentlyRunning);
        const cleared = await SecureStore.deleteItemAsync(pendingOtaCompletionKey).then(() => true).catch(() => false);
        if (!cancelled && cleared && applied) {
          setOtaState({ status: target?.type === 'rollback' ? 'rolled_back' : 'updated' });
        }
      })
      .catch(() => undefined);
    return () => { cancelled = true; };
  }, [setOtaState, updateState.currentlyRunning]);

  useEffect(() => {
    if (updateState.isDownloading && statusRef.current !== 'ready' && statusRef.current !== 'restarting') {
      setOtaState({ status: 'downloading' });
    }
  }, [setOtaState, updateState.isDownloading]);

  useEffect(() => {
    if (updateState.downloadError && statusRef.current === 'downloading') {
      setOtaState({ status: 'error', message: 'Не удалось скачать обновление. Проверьте подключение и повторите.' });
    }
  }, [setOtaState, updateState.downloadError]);

  useEffect(() => {
    if (state.status !== 'updated' && state.status !== 'rolled_back') return;
    const timer = setTimeout(() => setOtaState({ status: 'idle' }), completionNoticeMs);
    return () => clearTimeout(timer);
  }, [setOtaState, state.status]);

  const checkAndFetchUpdate = useCallback(async (force = false) => {
    if (dismissed || runningRef.current || nativeBusyRef.current ||
      statusRef.current === 'ready' || statusRef.current === 'restarting' ||
      statusRef.current === 'updated' || statusRef.current === 'rolled_back') {
      return;
    }

    const now = Date.now();
    if (!force && now - lastCheckAtRef.current < foregroundCheckThrottleMs) {
      return;
    }

    runningRef.current = true;
    lastCheckAtRef.current = now;
    let nextStatus: OtaStatus = 'checking';
    setOtaState({ status: nextStatus });

    try {
      const check = await Updates.checkForUpdateAsync();
      if (!check.isAvailable && !check.isRollBackToEmbedded) {
        setOtaState({ status: 'idle' });
        return;
      }

      nextStatus = 'downloading';
      setOtaState({ status: nextStatus });
      const fetch = await Updates.fetchUpdateAsync();
      if (fetch.isNew || fetch.isRollBackToEmbedded) {
        fetchedTargetRef.current = createOtaCompletionTarget(
          fetch.isRollBackToEmbedded ? { type: 'rollback' } : { type: 'new', updateId: fetch.manifest?.id },
          Updates.runtimeVersion,
        );
        playSuccessHaptic();
        setOtaState({ status: 'ready' });
        return;
      }

      setOtaState({ status: 'idle' });
    } catch {
      if (nextStatus === 'downloading') {
        setOtaState({ status: 'error', message: 'Не удалось скачать обновление. Проверьте подключение и повторите.' });
        return;
      }
      setOtaState({ status: 'idle' });
    } finally {
      runningRef.current = false;
    }
  }, [dismissed, setOtaState]);

  useEffect(() => {
    const timer = setTimeout(() => {
      checkAndFetchUpdate(true).catch(() => undefined);
    }, startupCheckDelayMs);
    return () => clearTimeout(timer);
  }, [checkAndFetchUpdate]);

  useEffect(() => {
    const handleAppState = (nextState: AppStateStatus) => {
      if (nextState === 'active') {
        checkAndFetchUpdate().catch(() => undefined);
      }
    };

    const subscription = AppState.addEventListener('change', handleAppState);
    return () => subscription.remove();
  }, [checkAndFetchUpdate]);

  const handleDismiss = useCallback(() => {
    playSelectionHaptic();
    setDismissed(true);
    setOtaState({ status: 'idle' });
  }, [setOtaState]);

  const handleRetry = useCallback(() => {
    playLightImpactHaptic();
    setDismissed(false);
    lastCheckAtRef.current = 0;
    checkAndFetchUpdate(true).catch(() => undefined);
  }, [checkAndFetchUpdate]);

  const handleReload = useCallback(async (): Promise<boolean> => {
    const vpnStatus = await getVpnStatus().catch(() => null);
    if (!vpnStatus || !canAutomaticallyApplyOtaUpdate(AppState.currentState, vpnStatus)) {
      const message = !vpnStatus ? 'Не удалось проверить VPN. Обновление подождёт.' :
        AppState.currentState !== 'active' ? 'Применим обновление, когда VEX снова будет открыт.' :
        vpnStatus.leakProtection === 'blocking' ? 'Обновление ждёт снятия блокировки трафика.' :
        'Обновление ждёт отключения VPN, чтобы не прервать соединение.';
      setOtaState({ status: 'ready', message });
      return false;
    }

    const target = createOtaCompletionTarget(updateState.downloadedUpdate ?? null, Updates.runtimeVersion) ?? fetchedTargetRef.current;
    try {
      playLightImpactHaptic();
      setOtaState({ status: 'restarting' });
      if (target) {
        await SecureStore.setItemAsync(pendingOtaCompletionKey, JSON.stringify(target)).catch(() => undefined);
      }
      await Updates.reloadAsync();
      return true;
    } catch {
      await SecureStore.deleteItemAsync(pendingOtaCompletionKey).catch(() => undefined);
      playErrorHaptic();
      setOtaState({ status: 'error', message: 'Не удалось применить обновление. Попробуйте ещё раз.' });
      return false;
    }
  }, [setOtaState, updateState.downloadedUpdate]);

  useEffect(() => {
    if (state.status !== 'ready') {
      if (autoReloadTimerRef.current) {
        clearTimeout(autoReloadTimerRef.current);
        autoReloadTimerRef.current = null;
      }
      return;
    }

    let cancelled = false;
    const attemptAutomaticReload = async () => {
      autoReloadTimerRef.current = null;
      const reloadStarted = await handleReload();
      if (!reloadStarted && !cancelled) {
        autoReloadTimerRef.current = setTimeout(attemptAutomaticReload, blockedAutoReloadRetryMs);
      }
    };

    autoReloadTimerRef.current = setTimeout(attemptAutomaticReload, autoReloadDelayMs);

    return () => {
      cancelled = true;
      if (autoReloadTimerRef.current) {
        clearTimeout(autoReloadTimerRef.current);
        autoReloadTimerRef.current = null;
      }
    };
  }, [handleReload, state.status]);

  if (state.status !== 'ready' && state.status !== 'downloading' && state.status !== 'restarting' &&
    state.status !== 'updated' && state.status !== 'rolled_back' && state.status !== 'error') {
    return null;
  }

  const isReady = state.status === 'ready';
  const isError = state.status === 'error';
  const title = state.status === 'updated' ? 'Обновлено' : state.status === 'rolled_back' ? 'Стабильная версия восстановлена' :
    isReady ? 'Обновление готово' : isError ? 'Обновление не загрузилось' : state.status === 'restarting' ? 'Применяем обновление' : 'Загружаем обновление';
  const progress = state.status === 'downloading' && typeof updateState.downloadProgress === 'number' && Number.isFinite(updateState.downloadProgress)
    ? Math.round(Math.max(0, Math.min(1, updateState.downloadProgress)) * 100)
    : null;
  const text = state.status === 'updated'
    ? 'Новая версия запущена и готова к работе.'
    : state.status === 'rolled_back'
    ? 'Безопасная встроенная версия запущена и готова к работе.'
    : isReady
    ? state.message || 'Обновление скачано. Применим его безопасным перезапуском, не прерывая активный VPN.'
    : isError
      ? state.message || 'Проверьте подключение и повторите позже.'
      : state.status === 'restarting' ? 'Перезапускаем VEX без установки APK.' :
        progress === null ? 'Скачиваем исправления без переустановки приложения.' : `Скачиваем исправления: ${progress}%.`;

  return (
    <View pointerEvents="box-none" style={styles.overlay}>
      {/* TODO(android-release): verify ready/completion notices on-device before release; the previous Host measured zero height. */}
      <Host colorScheme="dark" seedColor="#22D3EE" style={styles.host} matchContents={{ vertical: true }}>
        <Column spacing={8} style={styles.card}>
          <UniversalText textStyle={styles.eyebrow}>VEX update</UniversalText>
          <UniversalText textStyle={styles.title}>{title}</UniversalText>
          <UniversalText textStyle={styles.text}>{text}</UniversalText>
          {isReady ? (
            <Button label="Перезапустить" onPress={handleReload} />
          ) : isError ? (
            <Button label="Повторить" onPress={handleRetry} />
          ) : null}
          {isError ? (
            <Button label="Позже" onPress={handleDismiss} variant="outlined" />
          ) : null}
        </Column>
      </Host>
    </View>
  );
}

const styles = StyleSheet.create({
  overlay: {
    left: 0,
    position: 'absolute',
    right: 0,
    top: Platform.OS === 'ios' ? 58 : 32,
    zIndex: 50,
  },
  host: {
    alignSelf: 'center',
    maxWidth: 560,
    width: '92%',
  },
  card: {
    backgroundColor: 'rgba(7,17,19,0.97)',
    borderColor: 'rgba(34,211,238,0.28)',
    borderRadius: 22,
    borderWidth: 1,
    padding: 16,
    shadowColor: '#000000',
    shadowOffset: { height: 12, width: 0 },
    shadowOpacity: 0.28,
    shadowRadius: 24,
  },
  eyebrow: {
    color: '#22D3EE',
    fontSize: 10,
    fontWeight: '900',
    letterSpacing: 0.7,
    textTransform: 'uppercase',
  },
  title: {
    color: '#F4FCFD',
    fontSize: 16,
    fontWeight: '900',
    marginTop: 2,
  },
  text: {
    color: '#C6D6D9',
    fontSize: 12,
    fontWeight: '700',
    lineHeight: 16,
    marginTop: 3,
  },
});
