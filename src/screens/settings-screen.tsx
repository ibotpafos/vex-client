import { Host, Switch as ExpoSwitch } from "@expo/ui";
import { router, useFocusEffect } from "expo-router";
import {
  ChevronRight,
  ChevronLeft,
  Globe2,
  Languages,
  LogOut,
  Power,
  RefreshCw,
  ServerCog,
  Smartphone,
} from "lucide-react-native";
import React from "react";
import {
  Platform,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from "react-native";
import { useDesktopUpdate } from "@/components/desktop-update-overlay";
import { playSelectionHaptic, playLightImpactHaptic } from "@/native/haptics";
import { HOME_TAB_ROUTE, VPN_APPLICATIONS_ROUTE } from "@/navigation/routes";
import { getVpnApplicationSelection } from "@/settings/vpnPreferences";
import { useToast, type ToastOptions } from "@/ui/toast";
import { vexColors, VexScreen, vexSharedStyles, VexPressable } from "@/ui/vex-ui";
import { useVpnConnectionContext } from "@/vpn/vpn-connection-context";
import { useVexSettings, languages, type LanguageCode } from "./useVexSettings";

export default function SettingsScreen() {
  const [isSavingSmartRouting, setIsSavingSmartRouting] = React.useState(false);
  const [applicationRoutingSummary, setApplicationRoutingSummary] = React.useState('Все приложения');
  const { showToast: showGlobalToast } = useToast();
  const showSettingsToast = React.useCallback((options: ToastOptions) => {
    showGlobalToast(options);
  }, [showGlobalToast]);

  const {
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
  } = useVexSettings(showSettingsToast);
  const {
    isSmartRoutingEnabled,
    handleSmartRoutingToggle,
    vpnStatus,
  } = useVpnConnectionContext();

  const desktopUpdate = useDesktopUpdate();
  const versionText = appInfo.version || "dev";
  const buildText = appInfo.build ? `Сборка ${appInfo.build}` : null;
  const desktopReleaseText = desktopUpdate.latestVersion
    ? `${desktopUpdate.latestVersion} (${desktopUpdate.latestBuild || 0})`
    : "Проверка обновлений";
  const shouldShowDesktopRelease =
    Platform.OS === "web" && appInfo.platform !== "web";
  const isAndroidApp = Platform.OS === "android";
  const automationTitle = isAndroidApp ? "Автоподключение" : "Автозапуск";
  const automationValue = isAutomationEnabled ? "Включено" : "Выключено";
  const automationHint = isAndroidApp
    ? "Подключать VPN при открытии приложения."
    : "Запускать VEX вместе с системой.";
  const smartRoutingValue = isSmartRoutingEnabled ? "Включено" : "Выключено";
  const smartRoutingHint = vpnStatus.state === "connected"
    ? "Применится после переподключения. Российские сервисы пойдут без VPN."
    : "Российские сервисы без VPN, остальное через защищенный туннель.";
  const updateStatusLabel = desktopStatusLabel(
    desktopUpdate.status,
    desktopUpdate.required,
  );

  useFocusEffect(React.useCallback(() => {
    let active = true;
    if (!isAndroidApp) {
      return () => undefined;
    }
    getVpnApplicationSelection()
      .then((selection) => {
        if (active) {
          setApplicationRoutingSummary(selection.mode === 'selected'
            ? `Выбрано: ${selection.packageNames.length}`
            : 'Все приложения');
        }
      })
      .catch(() => undefined);
    return () => {
      active = false;
    };
  }, [isAndroidApp]));

  return (
    <VexScreen>
      <View style={vexSharedStyles.topBar}>
        <VexPressable
          onPress={() => {
            playSelectionHaptic();
            if (router.canGoBack()) {
              router.back();
              return;
            }
            router.replace(HOME_TAB_ROUTE);
          }}
          style={vexSharedStyles.iconButton}
          hoverStyle={{ opacity: 0.72 }}
          title="Назад"
          accessibilityLabel="Назад"
        >
          <ChevronLeft color="#EAF7F8" size={26} strokeWidth={2.4} />
        </VexPressable>
        <Text style={vexSharedStyles.title}>Настройки</Text>
        <View style={vexSharedStyles.iconButtonSpacer} />
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
              <Text style={styles.statusChip}>
                {formatPlatformLabel(appInfo.platform)}
              </Text>
              {buildText ? <Text style={styles.statusChip}>{buildText}</Text> : null}
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
          <VexPressable
            disabled={isSavingAutomation}
            onPress={() => handleAutomationToggle(!isAutomationEnabled)}
            style={styles.settingRow}
            hoverStyle={{ backgroundColor: 'rgba(7,17,19,0.96)', borderColor: 'rgba(34,211,238,0.36)' }}
            accessibilityRole="switch"
            accessibilityState={{ checked: isAutomationEnabled, disabled: isSavingAutomation }}
            accessibilityLabel={automationTitle}
          >
            <View style={styles.rowIcon}>
              <Power color="#22D3EE" size={21} strokeWidth={2.5} />
            </View>
            <View style={styles.rowCopy}>
              <Text style={styles.rowTitle}>{automationTitle}</Text>
              <Text numberOfLines={2} style={styles.rowDescription}>
                {automationHint}
              </Text>
              <Text
                style={[
                  styles.rowValue,
                  isAutomationEnabled && styles.rowValueActive,
                ]}
              >
                {automationValue}
              </Text>
            </View>
            <View pointerEvents="none">
              <SettingsNativeSwitch
                accessibilityLabel={automationTitle}
                disabled={isSavingAutomation}
                onValueChange={handleAutomationToggle}
                testID="settings-automation-switch"
                value={isAutomationEnabled}
              />
            </View>
          </VexPressable>
          {isAndroidApp ? (
            <VexPressable
              accessibilityLabel="Выбор приложений для VPN"
              accessibilityRole="button"
              onPress={() => {
                playSelectionHaptic();
                router.push(VPN_APPLICATIONS_ROUTE);
              }}
              style={styles.settingRow}
              hoverStyle={{ backgroundColor: 'rgba(7,17,19,0.96)', borderColor: 'rgba(34,211,238,0.36)' }}
              title="Выбрать приложения для VPN"
            >
              <View style={styles.rowIcon}>
                <Smartphone color="#22D3EE" size={21} strokeWidth={2.5} />
              </View>
              <View style={styles.rowCopy}>
                <Text style={styles.rowTitle}>Приложения через VPN</Text>
                <Text numberOfLines={2} style={styles.rowDescription}>
                  Направлять через туннель все приложения или только выбранные.
                </Text>
                <Text style={[styles.rowValue, applicationRoutingSummary !== 'Все приложения' && styles.rowValueActive]}>
                  {applicationRoutingSummary}
                </Text>
              </View>
              <ChevronRight color="#A7B9BD" size={22} strokeWidth={2.5} />
            </VexPressable>
          ) : null}
          <VexPressable
            disabled={isSavingServerSelection}
            onPress={() => handleServerSelectionToggle(!isAutoServerSelectionEnabled)}
            style={styles.settingRow}
            hoverStyle={{ backgroundColor: 'rgba(7,17,19,0.96)', borderColor: 'rgba(34,211,238,0.36)' }}
            accessibilityRole="switch"
            accessibilityState={{ checked: isAutoServerSelectionEnabled, disabled: isSavingServerSelection }}
            accessibilityLabel="Автовыбор сервера"
          >
            <View style={styles.rowIcon}>
              <ServerCog color="#22D3EE" size={21} strokeWidth={2.5} />
            </View>
            <View style={styles.rowCopy}>
              <Text style={styles.rowTitle}>Автовыбор сервера</Text>
              <Text style={styles.rowDescription}>
                VEX будет выбирать лучший доступный сервер при подключении.
              </Text>
              <Text
                style={[
                  styles.rowValue,
                  isAutoServerSelectionEnabled && styles.rowValueActive,
                ]}
              >
                {isAutoServerSelectionEnabled ? "Включено" : "Выключено"}
              </Text>
            </View>
            <View pointerEvents="none">
              <SettingsNativeSwitch
                accessibilityLabel="Автовыбор сервера"
                disabled={isSavingServerSelection}
                onValueChange={handleServerSelectionToggle}
                testID="settings-auto-server-switch"
                value={isAutoServerSelectionEnabled}
              />
            </View>
          </VexPressable>
          <VexPressable
            disabled={isSavingSmartRouting}
            onPress={() => {
              if (isSavingSmartRouting) {
                playSelectionHaptic();
                showSettingsToast({ message: "Настройка ещё сохраняется.", variant: "warning" });
                return;
              }
              playSelectionHaptic();
              setIsSavingSmartRouting(true);
              handleSmartRoutingToggle(!isSmartRoutingEnabled)
                .then((mode) => {
                  showSettingsToast({
                    message: mode === "all_except_ru"
                      ? "Умный режим включён."
                      : "Полный VPN для всего трафика включён.",
                    variant: "success",
                  });
                })
                .catch(() => {
                  showSettingsToast({
                    duration: "long",
                    message: "Не удалось сохранить умный режим.",
                    variant: "error",
                  });
                })
                .finally(() => setIsSavingSmartRouting(false));
            }}
            style={styles.settingRow}
            hoverStyle={{ backgroundColor: 'rgba(7,17,19,0.96)', borderColor: 'rgba(34,211,238,0.36)' }}
            accessibilityRole="switch"
            accessibilityState={{ checked: isSmartRoutingEnabled, disabled: isSavingSmartRouting }}
            accessibilityLabel="Умный режим"
          >
            <View style={styles.rowIcon}>
              <Globe2 color="#22D3EE" size={21} strokeWidth={2.5} />
            </View>
            <View style={styles.rowCopy}>
              <Text style={styles.rowTitle}>Умный режим</Text>
              <Text style={styles.rowDescription}>
                {smartRoutingHint}
              </Text>
              <Text
                style={[
                  styles.rowValue,
                  isSmartRoutingEnabled && styles.rowValueActive,
                ]}
              >
                {smartRoutingValue}
              </Text>
            </View>
            <View pointerEvents="none">
              <SettingsNativeSwitch
                accessibilityLabel="Умный режим"
                disabled={isSavingSmartRouting}
                onValueChange={handleSmartRoutingToggle}
                testID="settings-smart-routing-switch"
                value={isSmartRoutingEnabled}
              />
            </View>
          </VexPressable>
          <VexPressable
            disabled={isSavingAntiLeak}
            onPress={() => handleAntiLeakToggle(!isAntiLeakEnabled)}
            style={styles.settingRow}
            hoverStyle={{ backgroundColor: 'rgba(7,17,19,0.96)', borderColor: 'rgba(34,211,238,0.36)' }}
            accessibilityRole="switch"
            accessibilityState={{ checked: isAntiLeakEnabled, disabled: isSavingAntiLeak }}
            accessibilityLabel="Антидетект IP"
          >
            <View style={styles.rowIcon}>
              <Power color="#22D3EE" size={21} strokeWidth={2.5} />
            </View>
            <View style={styles.rowCopy}>
              <Text style={styles.rowTitle}>Антидетект IP</Text>
              <Text style={styles.rowDescription}>
                Блокировать прямой интернет, если VPN аварийно упал.
              </Text>
              <Text
                style={[
                  styles.rowValue,
                  isAntiLeakEnabled && styles.rowValueActive,
                ]}
              >
                {isAntiLeakEnabled ? "Включено" : "Выключено"}
              </Text>
            </View>
            <View pointerEvents="none">
              <SettingsNativeSwitch
                accessibilityLabel="Антидетект IP"
                disabled={isSavingAntiLeak}
                onValueChange={handleAntiLeakToggle}
                testID="settings-anti-leak-switch"
                value={isAntiLeakEnabled}
              />
            </View>
          </VexPressable>
        </View>

        <View style={styles.group}>
          <Text style={styles.groupTitle}>Интерфейс</Text>
          <View style={styles.settingRow}>
            <View style={styles.rowIcon}>
              <Languages color="#22D3EE" size={21} strokeWidth={2.5} />
            </View>
            <View style={styles.rowCopy}>
              <Text style={styles.rowTitle}>Язык</Text>
              <Text numberOfLines={1} style={styles.rowDescription}>
                Язык интерфейса приложения.
              </Text>
            </View>
          </View>
          <SettingsLanguagePicker
            onValueChange={handleLanguagePress}
            value={language}
          />
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
              <Text style={styles.infoValue}>
                {remoteConfig?.routingPolicyVersion || "Нет данных"}
              </Text>
            </View>
          </View>
          <View style={styles.detailList}>
            <View style={styles.detailRow}>
              <Text style={styles.detailLabel}>API клиент</Text>
              <Text style={styles.detailValue}>{appInfo.apiClientVersion}</Text>
            </View>
            <View style={styles.detailRow}>
              <Text style={styles.detailLabel}>Схема конфигурации</Text>
              <Text style={styles.detailValue}>
                {appInfo.configSchemaVersion}
              </Text>
            </View>
            {shouldShowDesktopRelease ? (
              <View style={styles.detailRow}>
                <Text style={styles.detailLabel}>Обновление desktop</Text>
                <Text
                  style={styles.detailValue}
                >{`${desktopReleaseText} · ${desktopUpdate.releaseChannel} · ${updateStatusLabel}`}</Text>
              </View>
            ) : null}
          </View>
          {desktopUpdate.status === "ready" ? (
            <VexPressable
              accessibilityRole="button"
              onPress={() => {
                playLightImpactHaptic();
                void desktopUpdate.relaunchToUpdate();
              }}
              style={styles.updateActionButton}
              hoverStyle={{ opacity: 0.88 }}
              title="Перезапустить VEX и применить обновление"
            >
              <Text style={styles.updateActionText}>
                Перезапустить и установить
              </Text>
            </VexPressable>
          ) : null}
        </View>

        <View style={styles.dangerGroup}>
          <VexPressable
            accessibilityRole="button"
            disabled={isSigningOut}
            onPress={handleSignOut}
            style={[
              styles.signOutButton,
              isSigningOut && styles.signOutButtonBusy,
            ]}
            hoverStyle={{ backgroundColor: 'rgba(255,159,159,0.12)' }}
            title="Выйти из текущей учетной записи"
          >
            <LogOut color="#FF9F9F" size={22} strokeWidth={2.5} />
            <Text style={styles.signOutText}>
              {isSigningOut ? "Выходим" : "Выйти из аккаунта"}
            </Text>
          </VexPressable>
        </View>
      </ScrollView>
    </VexScreen>
  );
}

function desktopStatusLabel(status: string, required: boolean) {
  if (required) return "обязательно";
  if (status === "ready") return "готово";
  if (status === "downloading") return "скачивается";
  if (status === "checking") return "проверка";
  if (status === "error") return "ошибка проверки";
  return "актуально";
}

function formatPlatformLabel(platform: string) {
  if (platform === "android") return "Android";
  if (platform === "ios") return "iOS";
  if (platform === "macos") return "macOS";
  if (platform === "windows") return "Windows";
  if (platform === "web") return "Web";
  return platform;
}

type SettingsNativeSwitchProps = {
  accessibilityLabel: string;
  disabled: boolean;
  onValueChange: (value: boolean) => void;
  testID: string;
  value: boolean;
};

function SettingsNativeSwitch({
  accessibilityLabel,
  disabled,
  onValueChange,
  testID,
  value,
}: SettingsNativeSwitchProps) {
  return (
    <Host
      accessibilityLabel={accessibilityLabel}
      accessibilityRole="switch"
      accessibilityState={{ checked: value, disabled }}
      colorScheme="dark"
      matchContents
      style={styles.nativeSwitchHost}
    >
      <ExpoSwitch
        disabled={disabled}
        onValueChange={onValueChange}
        testID={testID}
        value={value}
      />
    </Host>
  );
}

type SettingsLanguagePickerProps = {
  onValueChange: (value: LanguageCode) => void;
  value: LanguageCode;
};

function SettingsLanguagePicker({ onValueChange, value }: SettingsLanguagePickerProps) {
  return (
    <View
      accessibilityLabel="Язык интерфейса"
      style={styles.languageSelector}
      testID="settings-language-picker"
    >
      {languages.map((item) => {
        const selected = value === item.code;
        return (
          <VexPressable
            accessibilityRole="button"
            accessibilityState={{ selected }}
            key={item.code}
            onPress={() => onValueChange(item.code)}
            style={[styles.languageButton, selected && styles.languageButtonActive]}
            hoverStyle={{ backgroundColor: selected ? '#22D3EE' : 'rgba(34,211,238,0.14)' }}
          >
            <Text style={[styles.languageText, selected && styles.languageTextActive]}>{item.label}</Text>
          </VexPressable>
        );
      })}
    </View>
  );
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
    alignItems: "center",
    backgroundColor: vexColors.card,
    borderColor: vexColors.line,
    borderRadius: 14,
    borderWidth: 1,
    flexDirection: "row",
    gap: 8,
    padding: 8,
  },
  heroIcon: {
    alignItems: "center",
    backgroundColor: vexColors.accent,
    borderRadius: 12,
    height: 32,
    justifyContent: "center",
    width: 32,
  },
  heroCopy: {
    flex: 1,
    minWidth: 0,
  },
  heroEyebrow: {
    color: vexColors.accent,
    fontSize: 10,
    fontWeight: "900",
    textTransform: "uppercase",
  },
  heroTitle: {
    color: vexColors.text,
    fontSize: 12,
    fontWeight: "900",
    marginTop: 2,
  },
  chipRow: {
    flexDirection: "row",
    flexWrap: "wrap",
    gap: 5,
    marginTop: 5,
  },
  statusChip: {
    backgroundColor: "rgba(34,211,238,0.12)",
    borderColor: "rgba(34,211,238,0.22)",
    borderRadius: 999,
    borderWidth: 1,
    color: vexColors.textSoft,
    fontSize: 10,
    fontWeight: "800",
    overflow: "hidden",
    paddingHorizontal: 7,
    paddingVertical: 3,
  },
  noticePanel: {
    backgroundColor: "rgba(34,211,238,0.08)",
    borderColor: "rgba(34,211,238,0.22)",
    borderRadius: 12,
    borderWidth: 1,
    padding: 10,
  },
  noticeTitle: {
    color: vexColors.textSoft,
    fontSize: 14,
    fontWeight: "900",
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
    fontWeight: "900",
    textTransform: "uppercase",
  },
  settingRow: {
    alignItems: "center",
    flexDirection: "row",
    gap: 8,
  },
  rowIcon: {
    alignItems: "center",
    backgroundColor: "rgba(17,61,70,0.72)",
    borderRadius: 12,
    height: 34,
    justifyContent: "center",
    width: 34,
  },
  rowCopy: {
    flex: 1,
    minWidth: 0,
  },
  rowTitle: {
    color: vexColors.textSoft,
    fontSize: 13,
    fontWeight: "900",
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
    fontWeight: "900",
    marginTop: 4,
    textTransform: "uppercase",
  },
  rowValueActive: {
    color: vexColors.accent,
  },
  languageSelector: {
    alignSelf: "stretch",
    backgroundColor: vexColors.field,
    borderColor: "rgba(96,118,123,0.28)",
    borderRadius: 12,
    borderWidth: 1,
    flexDirection: "row",
    gap: 4,
    minHeight: 42,
    overflow: "hidden",
    padding: 4,
  },
  languageButton: {
    alignItems: "center",
    borderRadius: 9,
    flex: 1,
    justifyContent: "center",
    minHeight: 34,
    paddingHorizontal: 10,
  },
  languageButtonActive: {
    backgroundColor: vexColors.accent,
  },
  languageText: {
    color: vexColors.muted,
    fontSize: 13,
    fontWeight: "900",
  },
  languageTextActive: {
    color: "#031012",
  },
  infoGrid: {
    flexDirection: "row",
    gap: 8,
  },
  infoTile: {
    backgroundColor: "transparent",
    borderLeftColor: "rgba(34,211,238,0.36)",
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
    fontWeight: "800",
  },
  infoValue: {
    color: vexColors.textSoft,
    fontSize: 12,
    fontWeight: "900",
  },
  detailList: {
    gap: 8,
  },
  detailRow: {
    alignItems: "flex-start",
    borderTopColor: "rgba(96,118,123,0.18)",
    borderTopWidth: 1,
    gap: 4,
    paddingTop: 8,
  },
  detailLabel: {
    color: vexColors.muted,
    fontSize: 11,
    fontWeight: "800",
  },
  detailValue: {
    color: vexColors.textSoft,
    fontSize: 12,
    fontWeight: "800",
    lineHeight: 16,
  },
  updateActionButton: {
    alignItems: "center",
    backgroundColor: vexColors.accent,
    borderRadius: 14,
    justifyContent: "center",
    minHeight: 42,
    paddingHorizontal: 14,
  },
  updateActionText: {
    color: "#031012",
    fontSize: 15,
    fontWeight: "900",
  },
  dangerGroup: {
    paddingTop: 2,
  },
  signOutButton: {
    alignItems: "center",
    backgroundColor: vexColors.dangerSoft,
    borderColor: vexColors.dangerLine,
    borderRadius: 14,
    borderWidth: 1,
    flexDirection: "row",
    gap: 10,
    justifyContent: "center",
    minHeight: 46,
  },
  signOutButtonBusy: {
    opacity: 0.68,
  },
  signOutText: {
    color: vexColors.danger,
    fontSize: 15,
    fontWeight: "900",
  },
  nativeSwitchHost: {
    minHeight: 34,
    minWidth: 52,
  },
});
