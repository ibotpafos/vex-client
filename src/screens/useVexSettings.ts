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

export const languages = [
  { code: 'ru', label: 'Русский' },
  { code: 'en', label: 'English' },
] as const;
export const languageKey = 'vex.settings.language.v1';
export type LanguageCode = (typeof languages)[number]['code'];

export function isLanguageCode(value: string | null): value is LanguageCode {
  return value === 'ru' || value === 'en';
}

export function useVexSettings() {
  const { signOut } = useSession();
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
    playSelectionHaptic();
    setLanguage(nextLanguage);
    SecureStore.setItemAsync(languageKey, nextLanguage).catch(() => undefined);
  }, []);

  const handleSignOut = useCallback(async () => {
    if (isSigningOut) {
      playWarningHaptic();
      return;
    }
    playLightImpactHaptic();
    setIsSigningOut(true);
    try {
      await disconnectVpn().catch(() => undefined);
      await signOut();
      playSuccessHaptic();
      router.replace('/sign-in');
    } finally {
      setIsSigningOut(false);
    }
  }, [isSigningOut, signOut]);

  const handleAutomationToggle = useCallback(async () => {
    if (isSavingAutomation) {
      playWarningHaptic();
      return;
    }
    playSelectionHaptic();
    setIsSavingAutomation(true);
    const next = !isAutomationEnabled;
    try {
      const result = Platform.OS === 'android'
        ? await setAndroidAutoConnectEnabled(next)
        : await setStartupEnabled(next);
      setIsAutomationEnabled(result);
      playSuccessHaptic();
    } catch {
      playErrorHaptic();
    } finally {
      setIsSavingAutomation(false);
    }
  }, [isSavingAutomation, isAutomationEnabled]);

  const handleServerSelectionToggle = useCallback(async () => {
    if (isSavingServerSelection) {
      playWarningHaptic();
      return;
    }
    playSelectionHaptic();
    setIsSavingServerSelection(true);
    const next = !isAutoServerSelectionEnabled;
    try {
      const mode = await setServerSelectionMode(next ? 'auto' : 'manual');
      setIsAutoServerSelectionEnabled(mode === 'auto');
      playSuccessHaptic();
    } catch {
      playErrorHaptic();
    } finally {
      setIsSavingServerSelection(false);
    }
  }, [isAutoServerSelectionEnabled, isSavingServerSelection]);

  const handleAntiLeakToggle = useCallback(async () => {
    if (isSavingAntiLeak) {
      playWarningHaptic();
      return;
    }
    playSelectionHaptic();
    setIsSavingAntiLeak(true);
    const next = !isAntiLeakEnabled;
    try {
      setIsAntiLeakEnabled(await setAntiLeakEnabled(next));
      playSuccessHaptic();
    } catch {
      playErrorHaptic();
    } finally {
      setIsSavingAntiLeak(false);
    }
  }, [isAntiLeakEnabled, isSavingAntiLeak]);

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
