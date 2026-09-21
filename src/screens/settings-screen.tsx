import { Host, Switch as ExpoSwitch } from "@expo/ui";
import { router, useFocusEffect } from "expo-router";
import {
  ChevronRight,
  ChevronLeft,
  CreditCard,
  Globe2,
  Languages,
  LogOut,
  MessageSquare,
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
import { playSelectionHaptic } from "@/native/haptics";
import {
  HOME_TAB_ROUTE,
  VPN_APPLICATIONS_ROUTE,
} from "@/navigation/routes";
import { openExternalUrl } from "@/auth/systemAuth";
import { vexWebsite } from "@/navigation/website";
import { getVpnApplicationSelection } from "@/settings/vpnPreferences";
import { VexSection } from "@/components/vex-settings-section";
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
  const openWebsite = React.useCallback((url: string) => {
    playSelectionHaptic();
    void openExternalUrl(url).catch(() => {
      showSettingsToast({ message: "Не удалось открыть сайт VEX.", variant: "error" });
    });
  }, [showSettingsToast]);

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

  const versionText = appInfo.version || "dev";
  const buildText = appInfo.build ? `Сборка ${appInfo.build}` : null;
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
      <View style={styles.screenHeader}>
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
        contentInsetAdjustmentBehavior="automatic"
        contentContainerStyle={styles.scrollContent}
        showsVerticalScrollIndicator={false}
        style={styles.scroll}
      >
        {remoteConfig?.incidentBanner ? (
          <View style={styles.noticePanel}>
            <Text style={styles.noticeTitle}>Статус сервиса</Text>
            <Text style={styles.noticeText}>{remoteConfig.incidentBanner}</Text>
          </View>
        ) : null}

        <VexSection title="Подключение">
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
        </VexSection>

        <VexSection title="Маршрутизация">
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
        </VexSection>

        <VexSection title="Интерфейс">
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
        </VexSection>

        <VexSection title="Аккаунт и помощь">
          <VexPressable
            accessibilityLabel="Открыть личный кабинет на сайте"
            accessibilityRole="button"
            onPress={() => {
              openWebsite(vexWebsite.dashboard());
            }}
            style={styles.settingRow}
            hoverStyle={{ backgroundColor: 'rgba(7,17,19,0.96)', borderColor: 'rgba(34,211,238,0.36)' }}
            title="Личный кабинет"
          >
            <View style={styles.rowIcon}>
              <CreditCard color="#22D3EE" size={21} strokeWidth={2.5} />
            </View>
            <View style={styles.rowCopy}>
              <Text style={styles.rowTitle}>Личный кабинет</Text>
              <Text numberOfLines={2} style={styles.rowDescription}>
                Подписка, оплата и устройства — на сайте VEX.
              </Text>
            </View>
            <ChevronRight color="#A7B9BD" size={22} strokeWidth={2.5} />
          </VexPressable>
          <VexPressable
            accessibilityLabel="Открыть поддержку на сайте"
            accessibilityRole="button"
            onPress={() => {
              openWebsite(vexWebsite.support());
            }}
            style={styles.settingRow}
            hoverStyle={{ backgroundColor: 'rgba(7,17,19,0.96)', borderColor: 'rgba(34,211,238,0.36)' }}
            title="Поддержка на сайте"
          >
            <View style={styles.rowIcon}>
              <MessageSquare color="#22D3EE" size={21} strokeWidth={2.5} />
            </View>
            <View style={styles.rowCopy}>
              <Text style={styles.rowTitle}>Поддержка</Text>
              <Text numberOfLines={2} style={styles.rowDescription}>
                Открыть сайт VEX и написать в поддержку.
              </Text>
            </View>
            <ChevronRight color="#A7B9BD" size={22} strokeWidth={2.5} />
          </VexPressable>
          <VexPressable
            accessibilityRole="button"
            disabled={isSigningOut}
            onPress={handleSignOut}
            style={[styles.signOutButton, isSigningOut && styles.signOutButtonBusy]}
            hoverStyle={{ backgroundColor: 'rgba(255,159,159,0.12)' }}
            title="Выйти из текущей учетной записи"
          >
            <LogOut color="#FF9F9F" size={22} strokeWidth={2.5} />
            <Text style={styles.signOutText}>
              {isSigningOut ? "Выходим" : "Выйти из аккаунта"}
            </Text>
          </VexPressable>
        </VexSection>

        <VexSection title="О приложении">
          <View style={styles.detailList}>
            <View style={styles.detailRow}>
              <Text style={styles.detailLabel}>Версия</Text>
              <Text style={styles.detailValue}>
                {[versionText, buildText, formatPlatformLabel(appInfo.platform), appInfo.channel].filter(Boolean).join(' · ')}
              </Text>
            </View>
          </View>
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
          </View>
        </VexSection>

      </ScrollView>
    </VexScreen>
  );
}

function formatPlatformLabel(platform: string) {
  if (platform === "android") return "Android";
  if (platform === "ios") return "iOS";
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
    gap: 24,
    paddingBottom: 32,
  },
  screenHeader: {
    alignItems: "center",
    flexDirection: "row",
    justifyContent: "space-between",
    minHeight: 56,
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
  settingRow: {
    alignItems: "center",
    borderBottomColor: 'rgba(159, 218, 223, 0.14)',
    borderBottomWidth: 1,
    flexDirection: "row",
    gap: 12,
    minHeight: 68,
    paddingHorizontal: 14,
    paddingVertical: 11,
  },
  rowIcon: {
    alignItems: "center",
    height: 36,
    justifyContent: "center",
    width: 36,
  },
  rowCopy: {
    flex: 1,
    minWidth: 0,
  },
  rowTitle: {
    color: vexColors.text,
    fontSize: 16,
    fontWeight: "600",
  },
  rowDescription: {
    color: vexColors.muted,
    fontSize: 13,
    lineHeight: 18,
    marginTop: 3,
  },
  rowValue: {
    color: vexColors.muted,
    fontSize: 12,
    fontWeight: "700",
    marginTop: 4,
    textTransform: "uppercase",
  },
  rowValueActive: {
    color: vexColors.accent,
  },
  languageSelector: {
    alignSelf: "stretch",
    flexDirection: "row",
    gap: 4,
    minHeight: 44,
    paddingHorizontal: 14,
    paddingVertical: 10,
  },
  languageButton: {
    alignItems: "center",
    borderRadius: 999,
    flex: 1,
    justifyContent: "center",
    minHeight: 34,
    paddingHorizontal: 10,
  },
  languageButtonActive: {
    backgroundColor: "rgba(34,211,238,0.16)",
  },
  languageText: {
    color: vexColors.muted,
    fontSize: 13,
    fontWeight: "900",
  },
  languageTextActive: {
    color: vexColors.accent,
  },
  infoGrid: {
    flexDirection: "row",
    gap: 8,
    paddingHorizontal: 14,
    paddingTop: 12,
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
    paddingHorizontal: 14,
    paddingVertical: 10,
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
  signOutButton: {
    alignItems: "center",
    backgroundColor: vexColors.dangerSoft,
    borderColor: vexColors.dangerLine,
    borderTopColor: vexColors.dangerLine,
    borderTopWidth: StyleSheet.hairlineWidth,
    flexDirection: "row",
    gap: 10,
    justifyContent: "center",
    minHeight: 56,
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
