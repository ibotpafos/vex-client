import * as Updates from 'expo-updates';
import { DownloadCloud, RefreshCw, X } from 'lucide-react-native';
import { useCallback, useEffect, useRef, useState } from 'react';
import { AppState, Platform, Pressable, StyleSheet, Text, View, type AppStateStatus } from 'react-native';
import { playErrorHaptic, playLightImpactHaptic, playSelectionHaptic, playSuccessHaptic } from '@/native/haptics';
import { VexNativeActivityIndicator } from '@/ui/native-activity-indicator';

const foregroundCheckThrottleMs = 5 * 60_000;
const startupCheckDelayMs = 5_000;

type OtaStatus = 'idle' | 'checking' | 'downloading' | 'ready' | 'restarting' | 'error';

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
  const [state, setState] = useState<OtaState>({ status: 'idle' });
  const [dismissed, setDismissed] = useState(false);
  const runningRef = useRef(false);
  const lastCheckAtRef = useRef(0);
  const statusRef = useRef<OtaStatus>('idle');

  const setOtaState = useCallback((nextState: OtaState) => {
    statusRef.current = nextState.status;
    setState(nextState);
  }, []);

  const checkAndFetchUpdate = useCallback(async (force = false) => {
    if (dismissed || runningRef.current || statusRef.current === 'ready' || statusRef.current === 'restarting') {
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
      if (!check.isAvailable) {
        setOtaState({ status: 'idle' });
        return;
      }

      nextStatus = 'downloading';
      setOtaState({ status: nextStatus });
      const fetch = await Updates.fetchUpdateAsync();
      if (fetch.isNew || fetch.isRollBackToEmbedded) {
        playSuccessHaptic();
        setOtaState({ status: 'ready' });
        return;
      }

      setOtaState({ status: 'idle' });
    } catch (error) {
      if (nextStatus === 'downloading') {
        const message = error instanceof Error && error.message ? error.message : 'Не удалось скачать OTA-обновление.';
        setOtaState({ status: 'error', message });
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

  const handleReload = useCallback(async () => {
    playLightImpactHaptic();
    setOtaState({ status: 'restarting' });
    try {
      await Updates.reloadAsync();
    } catch (error) {
      playErrorHaptic();
      const message = error instanceof Error && error.message ? error.message : 'Не удалось перезапустить приложение.';
      setOtaState({ status: 'error', message });
    }
  }, [setOtaState]);

  if (state.status !== 'ready' && state.status !== 'downloading' && state.status !== 'restarting' && state.status !== 'error') {
    return null;
  }

  const isBusy = state.status === 'downloading' || state.status === 'restarting';
  const isReady = state.status === 'ready';
  const isError = state.status === 'error';

  return (
    <View pointerEvents="box-none" style={styles.overlay}>
      <View style={styles.card}>
        <View style={styles.icon}>
          {isBusy ? <VexNativeActivityIndicator color="#031012" size="small" /> : <DownloadCloud color="#031012" size={23} strokeWidth={2.7} />}
        </View>
        <View style={styles.copy}>
          <Text style={styles.eyebrow}>VEX update</Text>
          <Text style={styles.title}>{isReady ? 'Обновление готово' : isError ? 'Обновление не загрузилось' : 'Загружаем обновление'}</Text>
          <Text style={styles.text}>
            {isReady
              ? 'Быстрое обновление интерфейса уже скачано. Перезапустите VEX, чтобы применить его.'
              : isError
                ? state.message || 'Проверьте подключение и повторите позже.'
                : 'Скачиваем исправления без переустановки приложения.'}
          </Text>
          {Updates.channel || Updates.runtimeVersion ? (
            <Text style={styles.meta}>
              {Updates.channel ? `Канал: ${Updates.channel}` : null}
              {Updates.channel && Updates.runtimeVersion ? ' · ' : null}
              {Updates.runtimeVersion ? `Runtime: ${Updates.runtimeVersion}` : null}
            </Text>
          ) : null}
        </View>
        <View style={styles.actions}>
          {isReady ? (
            <Pressable accessibilityRole="button" onPress={handleReload} style={styles.primaryButton}>
              <RefreshCw color="#031012" size={17} strokeWidth={3} />
              <Text style={styles.primaryText}>Перезапустить</Text>
            </Pressable>
          ) : isError ? (
            <Pressable accessibilityRole="button" onPress={handleRetry} style={styles.primaryButton}>
              <Text style={styles.primaryText}>Повторить</Text>
            </Pressable>
          ) : null}
          {!isBusy ? (
            <Pressable accessibilityLabel="Скрыть OTA-обновление" accessibilityRole="button" onPress={handleDismiss} style={styles.closeButton}>
              <X color="#A7B9BD" size={18} strokeWidth={2.6} />
            </Pressable>
          ) : null}
        </View>
      </View>
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
  card: {
    alignItems: 'center',
    alignSelf: 'center',
    backgroundColor: 'rgba(7,17,19,0.97)',
    borderColor: 'rgba(34,211,238,0.28)',
    borderRadius: 22,
    borderWidth: 1,
    flexDirection: 'row',
    gap: 12,
    maxWidth: 560,
    padding: 12,
    shadowColor: '#000000',
    shadowOffset: { height: 12, width: 0 },
    shadowOpacity: 0.28,
    shadowRadius: 24,
    width: '92%',
  },
  icon: {
    alignItems: 'center',
    backgroundColor: '#22D3EE',
    borderRadius: 16,
    height: 44,
    justifyContent: 'center',
    width: 44,
  },
  copy: {
    flex: 1,
    minWidth: 0,
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
  meta: {
    color: '#6F858A',
    fontSize: 10,
    fontWeight: '800',
    marginTop: 5,
  },
  actions: {
    alignItems: 'flex-end',
    gap: 8,
  },
  primaryButton: {
    alignItems: 'center',
    backgroundColor: '#22D3EE',
    borderRadius: 13,
    flexDirection: 'row',
    gap: 6,
    minHeight: 38,
    paddingHorizontal: 12,
  },
  primaryText: {
    color: '#031012',
    fontSize: 12,
    fontWeight: '900',
  },
  closeButton: {
    alignItems: 'center',
    borderColor: 'rgba(167,185,189,0.22)',
    borderRadius: 999,
    borderWidth: 1,
    height: 32,
    justifyContent: 'center',
    width: 32,
  },
});
