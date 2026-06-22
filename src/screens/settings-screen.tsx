import * as SecureStore from '@/native/secureStore';
import { router } from 'expo-router';
import { ChevronLeft, Languages, LogOut, Power, RefreshCw, ServerCog, Smartphone } from 'lucide-react-native';
import React, { useCallback, useEffect, useState } from 'react';
import { Platform, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { appRemoteConfig, type AppRemoteConfig } from '@/api/vexApi';
import { useSession } from '@/auth/session-context';
import { useDesktopUpdate } from '@/components/desktop-update-overlay';
import { getAppInfo, type AppInfo } from '@/native/appInfo';
import { playErrorHaptic, playLightImpactHaptic, playSelectionHaptic, playSuccessHaptic, playWarningHaptic } from '@/native/haptics';
import { disconnectVpn, getStartupEnabled, setStartupEnabled } from '@/native/vexVpn';
import { getAndroidAutoConnectEnabled, getAntiLeakEnabled, getServerSelectionMode, setAndroidAutoConnectEnabled, setAntiLeakEnabled, setServerSelectionMode } from '@/settings/vpnPreferences';
import { vexColors, VexScreen, vexSharedStyles } from '@/ui/vex-ui';

const languages = [
  { code: 'ru', label: 'Русский' },
  { code: 'en', label: 'English' },
] as const;
const languageKey = 'vex.settings.language.v1';
type LanguageCode = (typeof languages)[number]['code'];

export default function SettingsScreen() {
  const { signOut } = useSession();
  const desktopUpdate = useDesktopUpdate();
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
  const versionText = appInfo.build ? `${appInfo.name} ${appInfo.version} (${appInfo.build})` : `${appInfo.name} ${appInfo.version}`;
  const desktopReleaseText = desktopUpdate.latestVersion
    ? `${desktopUpdate.latestVersion} (${desktopUpdate.latestBuild || 0})`
    : 'Проверка обновлений';
  const shouldShowDesktopRelease = Platform.OS === 'web' && appInfo.platform !== 'web';
  const isAndroidApp = Platform.OS === 'android';
  const automationTitle = isAndroidApp ? 'Автоподключение' : 'Автозапуск';
  const automationValue = isAutomationEnabled ? 'Включено' : 'Выключено';
  const automationHint = isAndroidApp
    ? 'Подключать VPN при открытии приложения.'
    : 'Запускать VEX вместе с системой.';
  const updateStatusLabel = desktopStatusLabel(desktopUpdate.status, desktopUpdate.required);

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
      // keep current value
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

  return (
    <VexScreen>
      <View style={vexSharedStyles.topBar}>
        <Pressable
          onPress={() => {
            playSelectionHaptic();
            router.back();
          }}
          style={vexSharedStyles.iconButton}
          accessibilityLabel="Назад"
        >
          <ChevronLeft color="#EAF7F8" size={26} strokeWidth={2.4} />
        </Pressable>
        <Text style={vexSharedStyles.title}>Настройки</Text>
        <View style={vexSharedStyles.iconButton} />
      </View>

      <ScrollView
        alwaysBounceVertical={false}
        contentContainerStyle={styles.scrollContent}
        showsVerticalScrollIndicator={false}
        style={styles.scroll}
      >
        <View style={styles.heroPanel}>
          <View style={styles.heroIcon}>
            <Smartphone color="#031012" size={24} strokeWidth={2.6} />
          </View>
          <View style={styles.heroCopy}>
            <Text style={styles.heroEyebrow}>VEX VPN</Text>
            <Text style={styles.heroTitle}>{versionText}</Text>
            <View style={styles.chipRow}>
              <Text style={styles.statusChip}>{formatPlatformLabel(appInfo.platform)}</Text>
              <Text style={styles.statusChip}>{appInfo.channel}</Text>
            </View>
          </View>
        </View>

        {remoteConfig?.incidentBanner ? (
          <View style={styles.noticePanel}>
            <Text style={styles.noticeTitle}>Статус сервиса</Text>
            <Text style={styles.noticeText}>{remoteConfig.incidentBanner}</Text>
          </View>
        ) : null}

        <View style={styles.group}>
          <Text style={styles.groupTitle}>Подключение</Text>
          <View style={styles.settingRow}>
            <View style={styles.rowIcon}>
              <Power color="#22D3EE" size={21} strokeWidth={2.5} />
            </View>
            <View style={styles.rowCopy}>
              <Text style={styles.rowTitle}>{automationTitle}</Text>
              <Text numberOfLines={2} style={styles.rowDescription}>{automationHint}</Text>
              <Text style={[styles.rowValue, isAutomationEnabled && styles.rowValueActive]}>{automationValue}</Text>
            </View>
            <Pressable
              accessibilityLabel={automationTitle}
              accessibilityRole="switch"
              accessibilityState={{ checked: isAutomationEnabled, disabled: isSavingAutomation }}
              disabled={isSavingAutomation}
              onPress={handleAutomationToggle}
              style={[styles.switchTrack, isAutomationEnabled && styles.switchTrackActive]}
            >
              <View style={[styles.switchThumb, isAutomationEnabled && styles.switchThumbActive]} />
            </Pressable>
          </View>
          <View style={styles.settingRow}>
            <View style={styles.rowIcon}>
              <ServerCog color="#22D3EE" size={21} strokeWidth={2.5} />
            </View>
            <View style={styles.rowCopy}>
              <Text style={styles.rowTitle}>Автовыбор сервера</Text>
              <Text style={styles.rowDescription}>VEX будет выбирать лучший доступный сервер при подключении.</Text>
              <Text style={[styles.rowValue, isAutoServerSelectionEnabled && styles.rowValueActive]}>
                {isAutoServerSelectionEnabled ? 'Включено' : 'Выключено'}
              </Text>
            </View>
            <Pressable
              accessibilityLabel="Автовыбор сервера"
              accessibilityRole="switch"
              accessibilityState={{ checked: isAutoServerSelectionEnabled, disabled: isSavingServerSelection }}
              disabled={isSavingServerSelection}
              onPress={handleServerSelectionToggle}
              style={[styles.switchTrack, isAutoServerSelectionEnabled && styles.switchTrackActive]}
            >
              <View style={[styles.switchThumb, isAutoServerSelectionEnabled && styles.switchThumbActive]} />
            </Pressable>
          </View>
          <View style={styles.settingRow}>
            <View style={styles.rowIcon}>
              <Power color="#22D3EE" size={21} strokeWidth={2.5} />
            </View>
            <View style={styles.rowCopy}>
              <Text style={styles.rowTitle}>Антидетект IP</Text>
              <Text style={styles.rowDescription}>Блокировать прямой интернет, если VPN аварийно упал.</Text>
              <Text style={[styles.rowValue, isAntiLeakEnabled && styles.rowValueActive]}>
                {isAntiLeakEnabled ? 'Включено' : 'Выключено'}
              </Text>
            </View>
            <Pressable
              accessibilityLabel="Антидетект IP"
              accessibilityRole="switch"
              accessibilityState={{ checked: isAntiLeakEnabled, disabled: isSavingAntiLeak }}
              disabled={isSavingAntiLeak}
              onPress={handleAntiLeakToggle}
              style={[styles.switchTrack, isAntiLeakEnabled && styles.switchTrackActive]}
            >
              <View style={[styles.switchThumb, isAntiLeakEnabled && styles.switchThumbActive]} />
            </Pressable>
          </View>
        </View>

        <View style={styles.group}>
          <Text style={styles.groupTitle}>Интерфейс</Text>
          <View style={styles.settingRow}>
            <View style={styles.rowIcon}>
              <Languages color="#22D3EE" size={21} strokeWidth={2.5} />
            </View>
            <View style={styles.rowCopy}>
              <Text style={styles.rowTitle}>Язык</Text>
              <Text numberOfLines={1} style={styles.rowDescription}>Язык интерфейса приложения.</Text>
            </View>
          </View>
          <View style={styles.languageRow}>
            {languages.map((item) => {
              const selected = item.code === language;
              return (
                <Pressable
                  key={item.code}
                  onPress={() => handleLanguagePress(item.code)}
                  style={[styles.languageButton, selected && styles.languageButtonSelected]}
                  accessibilityLabel={item.label}
                  accessibilityRole="button"
                  accessibilityState={{ selected }}
                >
                  <Text style={[styles.languageText, selected && styles.languageTextSelected]}>{item.label}</Text>
                </Pressable>
              );
            })}
          </View>
        </View>

        <View style={styles.group}>
          <Text style={styles.groupTitle}>Система</Text>
          <View style={styles.infoGrid}>
            <View style={styles.infoTile}>
              <ServerCog color="#A7B9BD" size={18} strokeWidth={2.4} />
              <Text style={styles.infoLabel}>Ядро</Text>
              <Text style={styles.infoValue}>{appInfo.coreVersion}</Text>
            </View>
            <View style={styles.infoTile}>
              <RefreshCw color="#A7B9BD" size={18} strokeWidth={2.4} />
              <Text style={styles.infoLabel}>Маршруты</Text>
              <Text style={styles.infoValue}>{remoteConfig?.routingPolicyVersion || 'Нет данных'}</Text>
            </View>
          </View>
          <View style={styles.detailList}>
            <View style={styles.detailRow}>
              <Text style={styles.detailLabel}>API клиент</Text>
              <Text style={styles.detailValue}>{appInfo.apiClientVersion}</Text>
            </View>
            <View style={styles.detailRow}>
              <Text style={styles.detailLabel}>Схема конфигурации</Text>
              <Text style={styles.detailValue}>{appInfo.configSchemaVersion}</Text>
            </View>
            {shouldShowDesktopRelease ? (
              <View style={styles.detailRow}>
                <Text style={styles.detailLabel}>Обновление desktop</Text>
                <Text style={styles.detailValue}>{`${desktopReleaseText} · ${desktopUpdate.releaseChannel} · ${updateStatusLabel}`}</Text>
              </View>
            ) : null}
          </View>
          {desktopUpdate.status === 'ready' ? (
            <Pressable
              accessibilityRole="button"
              onPress={() => {
                playLightImpactHaptic();
                void desktopUpdate.relaunchToUpdate();
              }}
              style={styles.updateActionButton}
            >
              <Text style={styles.updateActionText}>Перезапустить и установить</Text>
            </Pressable>
          ) : null}
        </View>

        <View style={styles.dangerGroup}>
          <Pressable
            accessibilityRole="button"
            disabled={isSigningOut}
            onPress={handleSignOut}
            style={[styles.signOutButton, isSigningOut && styles.signOutButtonBusy]}
          >
            <LogOut color="#FF9F9F" size={22} strokeWidth={2.5} />
            <Text style={styles.signOutText}>{isSigningOut ? 'Выходим' : 'Выйти из аккаунта'}</Text>
          </Pressable>
        </View>
      </ScrollView>
    </VexScreen>
  );
}

function isLanguageCode(value: string | null): value is LanguageCode {
  return value === 'ru' || value === 'en';
}

function desktopStatusLabel(status: string, required: boolean) {
  if (required) return 'обязательно';
  if (status === 'ready') return 'готово';
  if (status === 'downloading') return 'скачивается';
  if (status === 'checking') return 'проверка';
  if (status === 'error') return 'ошибка проверки';
  return 'актуально';
}

function formatPlatformLabel(platform: string) {
  if (platform === 'android') return 'Android';
  if (platform === 'ios') return 'iOS';
  if (platform === 'macos') return 'macOS';
  if (platform === 'windows') return 'Windows';
  if (platform === 'web') return 'Web';
  return platform;
}

const styles = StyleSheet.create({
  scroll: {
    flex: 1,
  },
  scrollContent: {
    gap: 8,
    paddingBottom: 14,
  },
  heroPanel: {
    alignItems: 'center',
    backgroundColor: vexColors.card,
    borderColor: vexColors.line,
    borderRadius: 14,
    borderWidth: 1,
    flexDirection: 'row',
    gap: 8,
    padding: 8,
  },
  heroIcon: {
    alignItems: 'center',
    backgroundColor: vexColors.accent,
    borderRadius: 12,
    height: 32,
    justifyContent: 'center',
    width: 32,
  },
  heroCopy: {
    flex: 1,
    minWidth: 0,
  },
  heroEyebrow: {
    color: vexColors.accent,
    fontSize: 10,
    fontWeight: '900',
    textTransform: 'uppercase',
  },
  heroTitle: {
    color: vexColors.text,
    fontSize: 12,
    fontWeight: '900',
    marginTop: 2,
  },
  chipRow: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: 5,
    marginTop: 5,
  },
  statusChip: {
    backgroundColor: 'rgba(34,211,238,0.12)',
    borderColor: 'rgba(34,211,238,0.22)',
    borderRadius: 999,
    borderWidth: 1,
    color: vexColors.textSoft,
    fontSize: 10,
    fontWeight: '800',
    overflow: 'hidden',
    paddingHorizontal: 7,
    paddingVertical: 3,
  },
  noticePanel: {
    backgroundColor: 'rgba(34,211,238,0.08)',
    borderColor: 'rgba(34,211,238,0.22)',
    borderRadius: 12,
    borderWidth: 1,
    padding: 10,
  },
  noticeTitle: {
    color: vexColors.textSoft,
    fontSize: 14,
    fontWeight: '900',
  },
  noticeText: {
    color: vexColors.muted,
    fontSize: 13,
    lineHeight: 18,
    marginTop: 6,
  },
  group: {
    backgroundColor: vexColors.card,
    borderColor: vexColors.line,
    borderRadius: 14,
    borderWidth: 1,
    gap: 8,
    padding: 8,
  },
  groupTitle: {
    color: vexColors.muted,
    fontSize: 11,
    fontWeight: '900',
    textTransform: 'uppercase',
  },
  settingRow: {
    alignItems: 'center',
    flexDirection: 'row',
    gap: 8,
  },
  rowIcon: {
    alignItems: 'center',
    backgroundColor: 'rgba(17,61,70,0.72)',
    borderRadius: 12,
    height: 34,
    justifyContent: 'center',
    width: 34,
  },
  rowCopy: {
    flex: 1,
    minWidth: 0,
  },
  rowTitle: {
    color: vexColors.textSoft,
    fontSize: 13,
    fontWeight: '900',
  },
  rowDescription: {
    color: vexColors.muted,
    fontSize: 11,
    lineHeight: 15,
    marginTop: 3,
  },
  rowValue: {
    color: vexColors.muted,
    fontSize: 11,
    fontWeight: '900',
    marginTop: 4,
    textTransform: 'uppercase',
  },
  rowValueActive: {
    color: vexColors.accent,
  },
  languageRow: {
    backgroundColor: vexColors.field,
    borderColor: 'rgba(96,118,123,0.28)',
    borderRadius: 12,
    borderWidth: 1,
    flexDirection: 'row',
    gap: 6,
    padding: 4,
  },
  languageButton: {
    alignItems: 'center',
    borderRadius: 12,
    flex: 1,
    minHeight: 32,
    justifyContent: 'center',
  },
  languageButtonSelected: {
    backgroundColor: vexColors.accent,
  },
  languageText: {
    color: vexColors.muted,
    fontSize: 13,
    fontWeight: '800',
  },
  languageTextSelected: {
    color: '#031012',
  },
  infoGrid: {
    flexDirection: 'row',
    gap: 8,
  },
  infoTile: {
    backgroundColor: 'transparent',
    borderLeftColor: 'rgba(34,211,238,0.36)',
    borderLeftWidth: 2,
    flex: 1,
    gap: 5,
    minHeight: 48,
    paddingLeft: 8,
    paddingVertical: 4,
  },
  infoLabel: {
    color: vexColors.muted,
    fontSize: 11,
    fontWeight: '800',
  },
  infoValue: {
    color: vexColors.textSoft,
    fontSize: 12,
    fontWeight: '900',
  },
  detailList: {
    gap: 8,
  },
  detailRow: {
    alignItems: 'flex-start',
    borderTopColor: 'rgba(96,118,123,0.18)',
    borderTopWidth: 1,
    gap: 4,
    paddingTop: 8,
  },
  detailLabel: {
    color: vexColors.muted,
    fontSize: 11,
    fontWeight: '800',
  },
  detailValue: {
    color: vexColors.textSoft,
    fontSize: 12,
    fontWeight: '800',
    lineHeight: 16,
  },
  updateActionButton: {
    alignItems: 'center',
    backgroundColor: vexColors.accent,
    borderRadius: 14,
    justifyContent: 'center',
    minHeight: 42,
    paddingHorizontal: 14,
  },
  updateActionText: {
    color: '#031012',
    fontSize: 15,
    fontWeight: '900',
  },
  dangerGroup: {
    paddingTop: 2,
  },
  signOutButton: {
    alignItems: 'center',
    backgroundColor: vexColors.dangerSoft,
    borderColor: vexColors.dangerLine,
    borderRadius: 14,
    borderWidth: 1,
    flexDirection: 'row',
    gap: 10,
    justifyContent: 'center',
    minHeight: 46,
  },
  signOutButtonBusy: {
    opacity: 0.68,
  },
  signOutText: {
    color: vexColors.danger,
    fontSize: 15,
    fontWeight: '900',
  },
  switchTrack: {
    alignItems: 'center',
    backgroundColor: vexColors.field,
    borderColor: 'rgba(96,118,123,0.34)',
    borderRadius: 999,
    borderWidth: 1,
    flexDirection: 'row',
    height: 30,
    justifyContent: 'flex-start',
    padding: 3,
    width: 50,
  },
  switchTrackActive: {
    backgroundColor: 'rgba(34,211,238,0.24)',
    borderColor: 'rgba(34,211,238,0.42)',
    justifyContent: 'flex-end',
  },
  switchThumb: {
    backgroundColor: vexColors.muted,
    borderRadius: 12,
    height: 22,
    width: 22,
  },
  switchThumbActive: {
    backgroundColor: vexColors.accent,
  },
});
