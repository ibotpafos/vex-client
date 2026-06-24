import { useCallback, useEffect, useState } from 'react';
import { Platform } from 'react-native';
import { router } from 'expo-router';
import { appRemoteConfig, type AppRemoteConfig } from '@/api/vexApi';
import { useSession } from '@/auth/session-context';
import { getAppInfo, type AppInfo } from '@/native/appInfo';
import { playErrorHaptic, playLightImpactHaptic, playSelectionHaptic, playSuccessHaptic, playWarningHaptic } from '@/native/haptics';
import { disconnectVpn, getStartupEnabled, setStartupEnabled } from '@/native/vexVpn';
import { getAndroidAutoConnectEnabled, getAntiLeakEnabled, getServerSelectionMode, setAndroidAutoConnectEnabled, setAntiLeakEnabled, setServerSelectionMode } from '@/settings/vpnPreferences';
import * as SecureStore from '@/native/secureStore';
import { useToast, type ToastOptions } from '@/ui/toast';

export const languages = [
  { code: 'ru', label: 'Русский' },
  { code: 'en', label: 'English' },
] as const;
export const languageKey = 'vex.settings.language.v1';
export type LanguageCode = (typeof languages)[number]['code'];

export function isLanguageCode(value: string | null): value is LanguageCode {
  return value === 'ru' || value === 'en';
}

export function useVexSettings(showToastOverride?: (options: ToastOptions) => void) {
  const { signOut } = useSession();
  const { showToast: showGlobalToast } = useToast();
  const showToast = showToastOverride ?? showGlobalToast;
  const [language, setLanguage] = useState<LanguageCode>('ru');
  const [isSigningOut, setIsSigningOut] = useState(false);
  const [isAutomationEnabled, setIsAutomationEnabled] = useState(false);
  const [isSavingAutomation, setIsSavingAutomation] = useState(false);
  const [isAntiLeakEnabled, setIsAntiLeakEnabled] = useState(true);
  const [isSavingAntiLeak, setIsSavingAntiLeak] = useState(false);
  const [isAutoServerSelectionEnabled, setIsAutoServerSelectionEnabled] = useState(true);
  const [isSavingServerSelection, setIsSavingServerSelection] = useState(false);
  const [appInfo, setAppInfo] = useState<AppInfo>({ name: 'VEX', version: 'dev', build: '0', platform: 'web', channel: 'stable', coreVersion: '0.1.0', configSchemaVersion: 1, apiClientVersion: 'expo-1' });
  const [remoteConfig, setRemoteConfig] = useState<AppRemoteConfig | null>(null);

  useEffect(() => {
    let mounted = true;
    getAppInfo()
      .then((info) => {
        if (mounted) {
          setAppInfo(info);
        }
        return info;
      })
      .then(async (info) => {
        if (!mounted) {
          return;
        }
        const config = await appRemoteConfig({
          platform: info.platform,
          appVersion: info.version,
          buildNumber: Number.parseInt(info.build || '0', 10) || 0,
          channel: info.channel,
          coreVersion: info.coreVersion,
          osVersion: `${info.platform} ${String(Platform.Version ?? '')}`,
          apiClientVersion: info.apiClientVersion,
          configSchemaVersion: info.configSchemaVersion,
        });
        if (mounted) {
          setRemoteConfig(config);
        }
      })
      .catch(() => undefined);
    SecureStore.getItemAsync(languageKey)
      .then((storedLanguage) => {
        if (mounted && isLanguageCode(storedLanguage)) {
          setLanguage(storedLanguage);
        }
      })
      .catch(() => undefined);
    const loadAutomationPreference = Platform.OS === 'android'
      ? getAndroidAutoConnectEnabled()
      : getStartupEnabled();
    loadAutomationPreference
      .then((value) => {
        if (mounted) {
          setIsAutomationEnabled(value);
        }
      })
      .catch(() => undefined);
    getServerSelectionMode()
      .then((mode) => {
        if (mounted) {
          setIsAutoServerSelectionEnabled(mode === 'auto');
        }
      })
      .catch(() => undefined);
    getAntiLeakEnabled()
      .then((enabled) => {
        if (mounted) {
          setIsAntiLeakEnabled(enabled);
        }
      })
      .catch(() => undefined);
    return () => {
      mounted = false;
    };
  }, []);

  const handleLanguagePress = useCallback((nextLanguage: LanguageCode) => {
    if (nextLanguage === language) {
      return;
    }
    playSelectionHaptic();
    const previousLanguage = language;
    setLanguage(nextLanguage);
    SecureStore.setItemAsync(languageKey, nextLanguage)
      .then(() => {
        showToast({
          message: `Язык изменён: ${languageLabel(nextLanguage)}`,
          variant: 'success',
        });
      })
      .catch(() => {
        setLanguage(previousLanguage);
        playErrorHaptic();
        showToast({
          duration: 'long',
          message: 'Не удалось сохранить язык.',
          variant: 'error',
        });
      });
  }, [language, showToast]);

  const handleSignOut = useCallback(async () => {
    if (isSigningOut) {
      playWarningHaptic();
      showToast({ message: 'Выход уже выполняется.', variant: 'warning' });
      return;
    }
    playLightImpactHaptic();
    setIsSigningOut(true);
    try {
      await disconnectVpn().catch(() => undefined);
      await signOut();
      playSuccessHaptic();
      router.replace('/sign-in');
    } catch {
      playErrorHaptic();
      showToast({
        duration: 'long',
        message: 'Не удалось выйти из аккаунта. Попробуйте ещё раз.',
        variant: 'error',
      });
    } finally {
      setIsSigningOut(false);
    }
  }, [isSigningOut, showToast, signOut]);

  const handleAutomationToggle = useCallback(async (next: boolean) => {
    if (isSavingAutomation) {
      playWarningHaptic();
      showToast({ message: 'Настройка ещё сохраняется.', variant: 'warning' });
      return;
    }
    playSelectionHaptic();
    setIsSavingAutomation(true);
    try {
      const result = Platform.OS === 'android'
        ? await setAndroidAutoConnectEnabled(next)
        : await setStartupEnabled(next);
      setIsAutomationEnabled(result);
      playSuccessHaptic();
      showToast({
        message: result ? 'Автоподключение включено.' : 'Автоподключение выключено.',
        variant: 'success',
      });
    } catch {
      playErrorHaptic();
      showToast({
        duration: 'long',
        message: 'Не удалось сохранить автоподключение.',
        variant: 'error',
      });
    } finally {
      setIsSavingAutomation(false);
    }
  }, [isSavingAutomation, showToast]);

  const handleServerSelectionToggle = useCallback(async (next: boolean) => {
    if (isSavingServerSelection) {
      playWarningHaptic();
      showToast({ message: 'Настройка ещё сохраняется.', variant: 'warning' });
      return;
    }
    playSelectionHaptic();
    setIsSavingServerSelection(true);
    try {
      const mode = await setServerSelectionMode(next ? 'auto' : 'manual');
      setIsAutoServerSelectionEnabled(mode === 'auto');
      playSuccessHaptic();
      showToast({
        message: mode === 'auto' ? 'Автовыбор сервера включён.' : 'Автовыбор сервера выключен.',
        variant: 'success',
      });
    } catch {
      playErrorHaptic();
      showToast({
        duration: 'long',
        message: 'Не удалось сохранить автовыбор сервера.',
        variant: 'error',
      });
    } finally {
      setIsSavingServerSelection(false);
    }
  }, [isSavingServerSelection, showToast]);

  const handleAntiLeakToggle = useCallback(async (next: boolean) => {
    if (isSavingAntiLeak) {
      playWarningHaptic();
      showToast({ message: 'Настройка ещё сохраняется.', variant: 'warning' });
      return;
    }
    playSelectionHaptic();
    setIsSavingAntiLeak(true);
    try {
      const result = await setAntiLeakEnabled(next);
      setIsAntiLeakEnabled(result);
      playSuccessHaptic();
      showToast({
        message: result ? 'Антидетект IP включён.' : 'Антидетект IP выключен.',
        variant: 'success',
      });
    } catch {
      playErrorHaptic();
      showToast({
        duration: 'long',
        message: 'Не удалось сохранить антидетект IP.',
        variant: 'error',
      });
    } finally {
      setIsSavingAntiLeak(false);
    }
  }, [isSavingAntiLeak, showToast]);

  return {
    language,
    isSigningOut,
    isAutomationEnabled,
    isSavingAutomation,
    isAntiLeakEnabled,
    isSavingAntiLeak,
    isAutoServerSelectionEnabled,
    isSavingServerSelection,
    appInfo,
    remoteConfig,
    handleLanguagePress,
    handleSignOut,
    handleAutomationToggle,
    handleServerSelectionToggle,
    handleAntiLeakToggle,
  };
}

function languageLabel(language: LanguageCode) {
  return languages.find((item) => item.code === language)?.label ?? language;
}
