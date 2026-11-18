import { vexTheme } from "@/ui/vex-theme";
import { ServiceNotice } from "@/components/service-notice";
import { Host, Switch as ExpoSwitch } from "@expo/ui";
import { router, useFocusEffect } from "expo-router";
import {
  Check,
  ChevronRight,
  ChevronLeft,
  CreditCard,
  FlaskConical,
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
  Alert,
  Platform,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from "react-native";
import { playSelectionHaptic } from "@/native/haptics";
import { openVpnSettings } from "@/native/vexVpn";
import {
  VPN_APPLICATIONS_ROUTE,
  goBackOrHome,
} from "@/navigation/routes";
import { openExternalUrl } from "@/auth/systemAuth";
import { vexWebsite } from "@/navigation/website";
import { getVpnApplicationSelection } from "@/settings/vpnPreferences";
import { VexSection } from "@/components/vex-settings-section";
import { formatQuotaResetAt, formatQuotaUsage, hasQuotaLimit } from "@/components/traffic-quota-presentation";
import { useToast, type ToastOptions } from "@/ui/toast";
import { vexColors, VexScreen, vexSharedStyles, VexPressable } from "@/ui/vex-ui";
import { useVpnConnectionContext } from "@/vpn/vpn-connection-context";
import { useVexSettings } from "./useVexSettings";

export default function SettingsScreen() {
  const [isSavingTransport, setIsSavingTransport] = React.useState(false);
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
    isSigningOut,
    isAutomationEnabled,
    isSavingAutomation,
    isAntiLeakEnabled,
    isSavingAntiLeak,
    isAutoServerSelectionEnabled,
    isSavingServerSelection,
    appInfo,
    remoteConfig,
    handleSignOut,
    handleAutomationToggle,
    handleServerSelectionToggle,
    handleAntiLeakToggle,
  } = useVexSettings(showSettingsToast);
  const {
    accountEmail,
    accountSummaryText,
    accountTierLabel,
    isSmartRoutingEnabled,
    handleSmartRoutingToggle,
    trafficQuota,
    vpnStatus,
    transport,
    supportsVless,
    unavailableTransportMessage,
    handleTransportChange,
    isVpnBusy,
  } = useVpnConnectionContext();

  const versionText = appInfo.version || "dev";
  const buildText = appInfo.build ? `Сборка ${appInfo.build}` : null;
  const isAndroidApp = Platform.OS === "android";
  const automationTitle = isAndroidApp ? "Автоподключение" : "Автозапуск";
  const automationHint = isAndroidApp
    ? "При открытии VEX"
    : "При запуске системы";
  const smartRoutingHint = transport === 'auto' && supportsVless
    ? 'VLESS — весь трафик; умный режим — только AmneziaWG.'
    : transport === 'vless'
    ? 'Весь трафик через VPN. Умный режим — только AmneziaWG.'
    : isSmartRoutingEnabled
    ? isAndroidApp
      ? "Часть российских IP — без VPN."
      : "Российские IP — без VPN."
    : "Весь трафик через VPN.";
  const smartRoutingDescription = vpnStatus.state === "connected"
    ? `После переподключения: ${smartRoutingHint}`
    : smartRoutingHint;

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
            goBackOrHome();
          }}
          style={vexSharedStyles.iconButton}
          hoverStyle={{ opacity: 0.72 }}
          title="Назад"
          accessibilityLabel="Назад"
        >
          <ChevronLeft color={vexTheme.colors.text} size={18} strokeWidth={1.75} />
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
        <ServiceNotice />

        <VexSection title="Подключение">
          <VexPressable
            disabled={isSavingAutomation}
            onPress={() => handleAutomationToggle(!isAutomationEnabled)}
            style={styles.settingRow}
            hoverStyle={{ backgroundColor: vexTheme.colors.surfaceRaised }}
            accessibilityRole="switch"
            accessibilityState={{ checked: isAutomationEnabled, disabled: isSavingAutomation }}
            accessibilityLabel={automationTitle}
          >
            <View style={styles.rowIcon}>
              <Power color={vexTheme.colors.textSecondary} size={18} strokeWidth={1.75} />
            </View>
            <View style={styles.rowCopy}>
              <Text style={styles.rowTitle}>{automationTitle}</Text>
              <Text numberOfLines={2} style={styles.rowDescription}>
                {automationHint}
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

        {isAndroidApp ? (
          <VexSection title="Защита при загрузке">
            <VexPressable
              style={styles.settingRow}
              accessibilityRole="button"
              accessibilityLabel="Настроить защиту VPN при загрузке"
              onPress={() => {
                playSelectionHaptic();
                Alert.alert('Постоянная VPN',
                  'Включите для VEX «Постоянная VPN» и «Блокировать соединения без VPN». Интернет будет заблокирован до подключения: откройте VEX и подключитесь. Исключённые приложения тоже будут заблокированы. Отключить эту защиту можно в настройках Android.',
                  [
                    { text: 'Отмена', style: 'cancel' },
                    { text: 'Настройки Android', onPress: () => openVpnSettings().then((opened) => {
                      if (!opened) throw new Error('VPN settings unavailable');
                    }).catch(() => showSettingsToast({ message: 'Не удалось открыть настройки VPN Android.', variant: 'error' })) },
                  ]);
              }}
            >
              <View style={styles.rowCopy}>
                <Text style={styles.rowTitle}>Постоянная VPN</Text>
                <Text style={styles.rowDescription}>Интернет только через VPN</Text>
              </View>
              <ChevronRight color={vexTheme.colors.textSecondary} size={18} strokeWidth={1.75} />
            </VexPressable>
          </VexSection>
        ) : null}

        {isAndroidApp ? (
          <VexSection title="Протокол VPN">
            {unavailableTransportMessage ? <Text accessibilityRole="alert" style={[styles.rowDescription, { padding: 16 }]}>{unavailableTransportMessage}</Text> : null}
            {vpnStatus.state === 'connected' ? <Text style={styles.rowDescription}>Подключено: {vpnStatus.transport === 'vless' ? 'VLESS' : 'AmneziaWG'}</Text> : null}
            {(supportsVless ? ['auto', 'amneziawg', 'vless'] as const : ['auto', 'amneziawg'] as const).map((protocol) => (
              <VexPressable
                key={protocol}
                testID={`settings-protocol-${protocol}`}
                disabled={isSavingTransport || isVpnBusy || (protocol === 'vless' && !supportsVless)}
                accessibilityRole="radio"
                accessibilityState={{ checked: transport === protocol, disabled: isSavingTransport || isVpnBusy || (protocol === 'vless' && !supportsVless) }}
                onPress={() => {
                  setIsSavingTransport(true);
                  void handleTransportChange(protocol)
                    .then(() => showSettingsToast({ message: vpnStatus.state === 'connected' ? 'Протокол сохранён. Переподключите VPN для применения.' : 'Протокол сохранён.', variant: 'success' }))
                    .catch((error: unknown) => showSettingsToast({ message: error instanceof Error ? error.message : 'Не удалось сохранить протокол.', variant: 'error' }))
                    .finally(() => setIsSavingTransport(false));
                }}
                style={styles.settingRow}
              >
                <View style={styles.rowCopy}>
                  <Text style={styles.rowTitle}>{protocol === 'auto' ? 'Авто' : protocol === 'vless' ? 'VLESS' : 'AmneziaWG'}</Text>
                  {protocol !== 'amneziawg' ? <Text style={styles.rowDescription}>{protocol === 'auto'
                    ? 'Выбор доступного протокола'
                    : 'Без умного режима. UDP может не работать.'}</Text> : null}
                </View>
                {transport === protocol ? <Check color={vexTheme.colors.accent} size={20} accessible={false} /> : null}
              </VexPressable>
            ))}
          </VexSection>
        ) : null}

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
              hoverStyle={{ backgroundColor: vexTheme.colors.surfaceRaised }}
              title="Выбрать приложения для VPN"
            >
              <View style={styles.rowIcon}>
                <Smartphone color={vexTheme.colors.textSecondary} size={18} strokeWidth={1.75} />
              </View>
              <View style={styles.rowCopy}>
                <Text style={styles.rowTitle}>Приложения через VPN</Text>
                <Text style={[styles.rowValue, applicationRoutingSummary !== 'Все приложения' && styles.rowValueActive]}>
                  {applicationRoutingSummary}
                </Text>
              </View>
              <ChevronRight color={vexTheme.colors.textSecondary} size={18} strokeWidth={1.75} />
            </VexPressable>
          ) : null}
          <VexPressable
            disabled={isSavingServerSelection}
            onPress={() => handleServerSelectionToggle(!isAutoServerSelectionEnabled)}
            style={styles.settingRow}
            hoverStyle={{ backgroundColor: vexTheme.colors.surfaceRaised }}
            accessibilityRole="switch"
            accessibilityState={{ checked: isAutoServerSelectionEnabled, disabled: isSavingServerSelection }}
            accessibilityLabel="Автовыбор сервера"
          >
            <View style={styles.rowIcon}>
              <ServerCog color={vexTheme.colors.textSecondary} size={18} strokeWidth={1.75} />
            </View>
            <View style={styles.rowCopy}>
              <Text style={styles.rowTitle}>Автовыбор сервера</Text>
              <Text style={styles.rowDescription}>
                При каждом подключении
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
            disabled={isSavingSmartRouting || transport === 'vless'}
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
                    message: vpnStatus.state === "connected"
                      ? "Режим сохранён. Переподключите VPN для применения."
                      : mode === "all_except_ru"
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
            hoverStyle={{ backgroundColor: vexTheme.colors.surfaceRaised }}
            accessibilityRole="switch"
            accessibilityState={{ checked: isSmartRoutingEnabled, disabled: isSavingSmartRouting || transport === 'vless' }}
            accessibilityLabel="Умный режим"
          >
            <View style={styles.rowIcon}>
              <Globe2 color={vexTheme.colors.textSecondary} size={18} strokeWidth={1.75} />
            </View>
            <View style={styles.rowCopy}>
              <Text style={styles.rowTitle}>Умный режим</Text>
              <Text style={styles.rowDescription}>
                {smartRoutingDescription}
              </Text>
            </View>
            <View pointerEvents="none">
              <SettingsNativeSwitch
                accessibilityLabel="Умный режим"
                disabled={isSavingSmartRouting || transport === 'vless'}
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
            hoverStyle={{ backgroundColor: vexTheme.colors.surfaceRaised }}
            accessibilityRole="switch"
            accessibilityState={{ checked: isAntiLeakEnabled, disabled: isSavingAntiLeak }}
            accessibilityLabel="Защита от утечек"
          >
            <View style={styles.rowIcon}>
              <Power color={vexTheme.colors.textSecondary} size={18} strokeWidth={1.75} />
            </View>
            <View style={styles.rowCopy}>
              <Text style={styles.rowTitle}>Защита от утечек</Text>
              <Text style={styles.rowDescription}>
                Блокировать интернет при обрыве VPN
              </Text>
            </View>
            <View pointerEvents="none">
              <SettingsNativeSwitch
                accessibilityLabel="Защита от утечек"
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
              <Languages color={vexTheme.colors.textSecondary} size={18} strokeWidth={1.75} />
            </View>
            <View style={styles.rowCopy}>
              <Text style={styles.rowTitle}>Язык</Text>
              <Text numberOfLines={1} style={styles.rowDescription}>
                Русский
              </Text>
            </View>
          </View>
        </VexSection>

        <VexSection title="Аккаунт и помощь">
          <View style={styles.accountSummaryCard} testID="settings-account-summary">
            <Text style={styles.accountPlanTitle}>
              {accountTierLabel ? `VEX · ${accountTierLabel}` : "VEX"}
            </Text>
            {accountSummaryText ? <Text style={styles.accountSubtitle}>{accountSummaryText}</Text> : null}
            {accountEmail ? (
              <View style={styles.accountDetailRow}>
                <Text style={styles.accountDetailLabel}>Email</Text>
                <Text numberOfLines={1} style={styles.accountDetailValue}>{accountEmail}</Text>
              </View>
            ) : null}
          </View>
          {trafficQuota ? (
            <View style={styles.accountQuotaCard} testID="settings-traffic-quota">
              <View style={styles.accountDetailRow}>
                <Text style={styles.accountDetailLabel}>Трафик за месяц</Text>
                <Text style={styles.accountDetailValue}>
                  {formatQuotaUsage(trafficQuota.usedBytes, trafficQuota.limitBytes)}
                </Text>
              </View>
              {hasQuotaLimit(trafficQuota.limitBytes) ? (
                <View style={styles.accountDetailRow}>
                  <Text style={styles.accountDetailLabel}>Сброс</Text>
                  <Text style={styles.accountDetailValue}>{formatQuotaResetAt(trafficQuota.resetAt)}</Text>
                </View>
              ) : null}
              {trafficQuota.multiplier > 1 ? (
                <View style={styles.accountDetailRow}>
                  <Text style={styles.accountDetailLabel}>Мобильный трафик</Text>
                  <Text style={styles.accountDetailValue}>×{trafficQuota.multiplier}</Text>
                </View>
              ) : null}
              {hasQuotaLimit(trafficQuota.limitBytes) && trafficQuota.limitReached ? (
                <Text accessibilityRole="alert" style={styles.accountQuotaWarning}>
                  Лимит достигнут · скорость {trafficQuota.effectiveRateLimitMbps ?? 1} Мбит/с
                </Text>
              ) : null}
            </View>
          ) : null}
          <VexPressable
            accessibilityLabel={isAndroidApp ? "Продлить VPN в личном кабинете на сайте" : "Открыть личный кабинет на сайте"}
            accessibilityRole="button"
            onPress={() => {
              openWebsite(vexWebsite.dashboard());
            }}
            style={styles.settingRow}
            hoverStyle={{ backgroundColor: vexTheme.colors.surfaceRaised }}
            title={isAndroidApp ? "Продлить VPN" : "Личный кабинет"}
          >
            <View style={styles.rowIcon}>
              <CreditCard color={vexTheme.colors.textSecondary} size={18} strokeWidth={1.75} />
            </View>
            <View style={styles.rowCopy}>
              <Text style={styles.rowTitle}>{isAndroidApp ? "Продлить VPN" : "Личный кабинет"}</Text>
              <Text numberOfLines={2} style={styles.rowDescription}>
                {isAndroidApp ? "Тарифы и оплата на сайте" : "Подписка и устройства на сайте"}
              </Text>
            </View>
            <ChevronRight color={vexTheme.colors.textSecondary} size={18} strokeWidth={1.75} />
          </VexPressable>
          <VexPressable
            accessibilityLabel="Открыть программу тестировщиков на сайте VEX"
            accessibilityRole="button"
            onPress={() => openWebsite(vexWebsite.testing())}
            style={styles.settingRow}
            title="Аккаунт тестировщика"
          >
            <View style={styles.rowIcon}><FlaskConical color={vexTheme.colors.textSecondary} size={18} strokeWidth={1.75} /></View>
            <View style={styles.rowCopy}>
              <Text style={styles.rowTitle}>Аккаунт тестировщика</Text>
              <Text numberOfLines={2} style={styles.rowDescription}>Тестовые версии и отзывы</Text>
            </View>
            <ChevronRight color={vexTheme.colors.textSecondary} size={18} strokeWidth={1.75} />
          </VexPressable>
          <VexPressable
            accessibilityLabel="Открыть поддержку на сайте"
            accessibilityRole="button"
            onPress={() => {
              openWebsite(vexWebsite.support());
            }}
            style={styles.settingRow}
            hoverStyle={{ backgroundColor: vexTheme.colors.surfaceRaised }}
            title="Поддержка на сайте"
          >
            <View style={styles.rowIcon}>
              <MessageSquare color={vexTheme.colors.textSecondary} size={18} strokeWidth={1.75} />
            </View>
            <View style={styles.rowCopy}>
              <Text style={styles.rowTitle}>Поддержка</Text>
              <Text numberOfLines={2} style={styles.rowDescription}>
                На сайте VEX
              </Text>
            </View>
            <ChevronRight color={vexTheme.colors.textSecondary} size={18} strokeWidth={1.75} />
          </VexPressable>
          <VexPressable
            accessibilityRole="button"
            disabled={isSigningOut}
            onPress={handleSignOut}
            style={[styles.signOutButton, isSigningOut && styles.signOutButtonBusy]}
            hoverStyle={{ backgroundColor: 'rgba(255,159,159,0.12)' }}
            title="Выйти из текущей учетной записи"
          >
            <LogOut color="#FF9F9F" size={18} strokeWidth={1.75} />
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
              <ServerCog color={vexTheme.colors.textSecondary} size={18} strokeWidth={1.75} />
              <Text style={styles.infoLabel}>Ядро</Text>
              <Text style={styles.infoValue}>{appInfo.coreVersion}</Text>
            </View>
            <View style={styles.infoTile}>
              <RefreshCw color={vexTheme.colors.textSecondary} size={18} strokeWidth={1.75} />
              <Text style={styles.infoLabel}>Маршруты</Text>
              <Text style={styles.infoValue}>
                {remoteConfig?.routingPolicyVersion || "Нет данных"}
              </Text>
            </View>
          </View>
          <View style={styles.detailList}>
            <View style={styles.detailRow}>
              <Text style={styles.detailLabel}>OTA</Text>
              <Text style={styles.detailValue}>{appInfo.otaLaunch === "emergency" ? "Аварийный запуск" : appInfo.otaLaunch === "embedded" ? "Встроенная версия" : appInfo.otaLaunch === "applied" ? "Применённое обновление" : "Нет данных OTA"}{appInfo.otaRuntimeVersion ? ` · runtime ${appInfo.otaRuntimeVersion}` : ""}</Text>
            </View>
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
      seedColor={vexTheme.colors.accent}
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
  accountSummaryCard: {
    borderBottomColor: vexTheme.colors.line,
    borderBottomWidth: 1,
    gap: 4,
    paddingHorizontal: 16,
    paddingVertical: 12,
  },
  accountPlanTitle: {
    color: vexColors.text,
    fontSize: 17,
    fontWeight: "600",
  },
  accountSubtitle: {
    color: vexColors.muted,
    fontSize: 13,
    lineHeight: 20,
  },
  accountQuotaCard: {
    borderBottomColor: vexTheme.colors.line,
    borderBottomWidth: 1,
    gap: 8,
    paddingHorizontal: 16,
    paddingVertical: 12,
  },
  accountDetailRow: {
    alignItems: "center",
    flexDirection: "row",
    gap: 12,
    justifyContent: "space-between",
    marginTop: 4,
  },
  accountDetailLabel: {
    color: vexColors.muted,
    fontSize: 12,
    fontWeight: "600",
  },
  accountDetailValue: {
    color: vexColors.textSoft,
    flexShrink: 1,
    fontSize: 12,
    fontWeight: "600",
    textAlign: "right",
  },
  accountQuotaWarning: {
    color: vexColors.danger,
    fontSize: 12,
    fontWeight: "600",
    lineHeight: 20,
    marginTop: 4,
  },
  settingRow: {
    alignItems: "center",
    borderBottomColor: vexTheme.colors.line,
    borderBottomWidth: 1,
    flexDirection: "row",
    gap: 12,
    minHeight: 68,
    paddingHorizontal: 16,
    paddingVertical: 12,
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
    lineHeight: 20,
    marginTop: 4,
  },
  rowValue: {
    color: vexColors.muted,
    fontSize: 12,
    fontWeight: "600",
    marginTop: 4,
  },
  rowValueActive: {
    color: vexColors.accent,
  },
  infoGrid: {
    flexDirection: "row",
    gap: 8,
    paddingHorizontal: 16,
    paddingTop: 12,
  },
  infoTile: {
    backgroundColor: "transparent",
    flex: 1,
    gap: 4,
    minHeight: 48,
    paddingLeft: 8,
    paddingVertical: 4,
  },
  infoLabel: {
    color: vexColors.muted,
    fontSize: 11,
    fontWeight: "600",
  },
  infoValue: {
    color: vexColors.textSoft,
    fontSize: 12,
    fontWeight: "600",
  },
  detailList: {
    gap: 8,
    paddingHorizontal: 16,
    paddingVertical: 12,
  },
  detailRow: {
    alignItems: "flex-start",
    borderTopColor: vexTheme.colors.line,
    borderTopWidth: 1,
    gap: 4,
    paddingTop: 8,
  },
  detailLabel: {
    color: vexColors.muted,
    fontSize: 11,
    fontWeight: "600",
  },
  detailValue: {
    color: vexColors.textSoft,
    fontSize: 12,
    fontWeight: "600",
    lineHeight: 16,
  },
  signOutButton: {
    alignItems: "center",
    backgroundColor: vexTheme.colors.surface,
    borderColor: vexTheme.colors.line,
    borderTopColor: vexTheme.colors.line,
    borderTopWidth: StyleSheet.hairlineWidth,
    flexDirection: "row",
    gap: 12,
    justifyContent: "center",
    minHeight: 56,
  },
  signOutButtonBusy: {
    opacity: 0.68,
  },
  signOutText: {
    color: vexColors.danger,
    fontSize: 15,
    fontWeight: "600",
  },
  nativeSwitchHost: {
    minHeight: 44,
    minWidth: 52,
  },
});
