import * as Application from "expo-application";
import {
  Download,
  ShieldAlert,
  ShieldCheck,
  X,
} from "lucide-react-native";
import React, {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import {
  Linking,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from "react-native";
import { installManualUpdate } from "@/api/manualUpdateInstall";
import {
  assessManualUpdateCenter,
  canUseOtaUpdate,
  requiresNativeUpdate,
  shouldOfferAppUpdate,
} from "@/api/updatePreflight";
import { vexApiBaseUrl, type AppUpdateCheckResult } from "@/api/vexApi";
import { useMobileAppUpdateQuery } from "@/components/mobile-app-update-query";
import { getAppInfo, type AppInfo } from "@/native/appInfo";
import {
  playErrorHaptic,
  playLightImpactHaptic,
  playSelectionHaptic,
  playSuccessHaptic,
} from "@/native/haptics";
import { useOtaPresentation } from "@/components/ota-update-overlay";
import { shouldShowOtaHeaderAction } from "@/updates/otaPresentation";
import { VexNativeActivityIndicator } from "@/ui/native-activity-indicator";
import { VexPressable, VexScreen } from "@/ui/vex-ui";

const androidSigningMigrationLandingUrl = "https://vexguard.app/download";

type UpdateCenterButtonProps = {
  visible: boolean;
  onOpen: () => void;
  onClose: () => void;
};

export function UpdateCenterButton({
  visible,
  onOpen,
  onClose,
}: UpdateCenterButtonProps) {
  if (Platform.OS === "android" || Platform.OS === "ios") {
    return (
      <MobileUpdateCenterButton
        platform={Platform.OS}
        visible={visible}
        onClose={onClose}
        onOpen={onOpen}
      />
    );
  }
  return null;
}

export function MobileUpdateNoticeBanner({ onOpen }: { onOpen: () => void }) {
  if (Platform.OS !== "android" && Platform.OS !== "ios") {
    return null;
  }
  return (
    <MobileUpdateNoticeBannerContent onOpen={onOpen} platform={Platform.OS} />
  );
}

function MobileUpdateNoticeBannerContent({
  onOpen,
  platform,
}: {
  onOpen: () => void;
  platform: "android" | "ios";
}) {
  const buildNumber = currentNativeBuild();
  const updateQuery = useMobileAppUpdateQuery(platform, buildNumber);
  const update = updateQuery.data ?? null;
  const mandatoryUpdate = Boolean(
    update?.required || update?.currentBuildBlocked,
  );
  // Optional APK releases stay discoverable from the header, not as a persistent home banner.
  const shouldShow = requiresNativeUpdate(update) && mandatoryUpdate;

  if (!shouldShow) {
    return null;
  }

  const migration = isAndroidSigningKeyMigration(update);
  const handlePress = () => {
    playSelectionHaptic();
    if (migration && platform === "android") {
      void openAndroidSigningMigrationDownload().catch(() => {
        onOpen();
      });
      return;
    }
    onOpen();
  };

  return (
    <Pressable
      accessibilityLabel={
        migration
          ? "Скачать новую Android-сборку"
          : mandatoryUpdate
            ? "Открыть обязательное обновление"
            : "Открыть обновление"
      }
      accessibilityRole="button"
      onPress={handlePress}
      style={[styles.noticeBanner, migration && styles.noticeBannerMigration]}
    >
      <View style={styles.noticeIcon}>
        <ShieldAlert color="#031012" size={20} strokeWidth={2.7} />
      </View>
      <View style={styles.noticeCopy}>
        <Text style={styles.noticeTitle}>
          {migration
            ? "Нужно поставить новую сборку VEX"
            : mandatoryUpdate
              ? "Требуется обновление VEX"
              : "Доступно обновление VEX"}
        </Text>
        <Text numberOfLines={2} style={styles.noticeText}>
          {migration
            ? "Скачайте новый APK, войдите в аккаунт и затем удалите старое приложение."
            : "Откройте центр обновлений и установите актуальную версию."}
        </Text>
      </View>
      <Text style={styles.noticeAction}>
        {migration ? "Скачать" : "Открыть"}
      </Text>
    </Pressable>
  );
}

function MobileUpdateCenterButton({
  onOpen,
  platform,
}: UpdateCenterButtonProps & { platform: "android" | "ios" }) {
  const buildNumber = currentNativeBuild();
  const updateQuery = useMobileAppUpdateQuery(platform, buildNumber);
  const update = updateQuery.data ?? null;
  const ota = useOtaPresentation();
  const hasNativeUpdate = Boolean(
    update &&
      shouldOfferAppUpdate(update, buildNumber) &&
      requiresNativeUpdate(update),
  );
  const hasUnappliedOta = ota?.status === "downloading" || ota?.status === "ready";

  if (!hasNativeUpdate && !hasUnappliedOta) {
    return null;
  }

  return (
    <HeaderButton
      busy={ota?.status === "downloading" || Boolean(ota?.isBusy)}
      onPress={onOpen}
    />
  );
}

function HeaderButton({
  busy,
  onPress,
}: {
  busy: boolean;
  onPress: () => void;
}) {
  return (
    <VexPressable
      accessibilityLabel={busy ? "Загружаем обновление" : "Обновление доступно"}
      accessibilityRole="button"
      accessibilityState={{ busy }}
      hitSlop={12}
      hoverStyle={styles.headerButtonPressed}
      onPress={() => {
        playSelectionHaptic();
        onPress();
      }}
      style={styles.headerButton}
      title="Обновление"
    >
      {busy ? (
        <VexNativeActivityIndicator color="#EAF7F8" size="small" />
      ) : (
        <Download color="#EAF7F8" size={25} strokeWidth={2.15} />
      )}
    </VexPressable>
  );
}

export function MobileUpdateCenterRouteContent({
  onClose,
  platform,
}: {
  onClose: () => void;
  platform: "android" | "ios";
}) {
  const buildNumber = currentNativeBuild();
  const updateQuery = useMobileAppUpdateQuery(platform, buildNumber);
  return (
    <UpdateCenterFrame onClose={onClose}>
      <MobileUpdateCenterContent
        buildNumber={buildNumber}
        platform={platform}
        update={updateQuery.data ?? null}
        updateQuery={updateQuery}
      />
    </UpdateCenterFrame>
  );
}

function UpdateCenterFrame({
  children,
  onClose,
}: {
  children: React.ReactNode;
  onClose: () => void;
}) {
  return (
    <VexScreen contentStyle={styles.routeShell}>
      <View style={styles.modal}>
        <View style={styles.modalHeader}>
          <View>
            <Text style={styles.eyebrow}>VEX</Text>
            <Text style={styles.modalTitle}>Обновления</Text>
          </View>
          <Pressable
            accessibilityLabel="Закрыть центр обновлений"
            onPress={onClose}
            style={styles.closeButton}
          >
            <X color="#A7B9BD" size={24} strokeWidth={2.5} />
          </Pressable>
        </View>
        {children}
      </View>
    </VexScreen>
  );
}

function MobileUpdateCenterContent({
  buildNumber,
  platform,
  update,
  updateQuery,
}: {
  buildNumber: number;
  platform: "android" | "ios";
  update: AppUpdateCheckResult | null;
  updateQuery: ReturnType<typeof useMobileAppUpdateQuery>;
}) {
  const [appInfo, setAppInfo] = useState<AppInfo | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [isOtaActionBusy, setIsOtaActionBusy] = useState(false);
  const otaActionRunningRef = useRef(false);
  const ota = useOtaPresentation();

  useEffect(() => {
    let cancelled = false;
    getAppInfo()
      .then((info) => {
        if (!cancelled) {
          setAppInfo(info);
        }
      })
      .catch(() => undefined);
    return () => {
      cancelled = true;
    };
  }, []);

  const assessment = useMemo(
    () =>
      assessManualUpdateCenter({
        currentBuild: buildNumber,
        currentVersion:
          appInfo?.version || Application.nativeApplicationVersion || "dev",
        trustedBaseUrl: vexApiBaseUrl,
        update,
      }),
    [appInfo?.version, buildNumber, update],
  );
  const signingMigration =
    platform === "android" && isAndroidSigningKeyMigration(update);
  const nativeUpdateRequired = requiresNativeUpdate(update);
  const otaUpdateAvailable = canUseOtaUpdate(update);
  const manualDownloadUrl = signingMigration
    ? androidSigningMigrationLandingUrl
    : update?.downloadUrl || "";
  const canOpenManualDownload = signingMigration && Boolean(manualDownloadUrl);
  const canStartInstall =
    platform === "ios"
      ? Boolean(update?.updateAvailable && update.downloadUrl)
      : nativeUpdateRequired &&
        (assessment.canInstall || canOpenManualDownload);
  const otaReadyWithoutMetadata = Boolean(
    ota?.isSupported && ota.status === "ready" && !nativeUpdateRequired,
  );
  const isPrimaryBusy =
    isOtaActionBusy ||
    Boolean(ota?.isBusy) ||
    (updateQuery.isFetching && !otaReadyWithoutMetadata);
  const needsNativeRecovery =
    assessment.updateAvailable &&
    nativeUpdateRequired &&
    !canStartInstall &&
    !signingMigration;
  const primaryDisabled =
    isPrimaryBusy ||
    (!needsNativeRecovery &&
      !otaReadyWithoutMetadata &&
      !canStartInstall &&
      assessment.updateAvailable &&
      !otaUpdateAvailable);

  const checkForUpdates = useCallback(async () => {
    if (otaActionRunningRef.current || ota?.isBusy || updateQuery.isFetching) return;
    otaActionRunningRef.current = true;
    setIsOtaActionBusy(true);
    try {
      playLightImpactHaptic();
      await Promise.all([
        updateQuery.refetch(),
        ota?.isSupported ? ota.checkForUpdate(true) : Promise.resolve(),
      ]);
    } finally {
      otaActionRunningRef.current = false;
      setIsOtaActionBusy(false);
    }
  }, [ota, updateQuery]);

  const handlePrimaryPress = useCallback(async () => {
    setActionError(null);
    if (signingMigration) {
      try {
        playLightImpactHaptic();
        await openAndroidSigningMigrationDownload();
        playSuccessHaptic();
      } catch (error) {
        playErrorHaptic();
        setActionError(
          error instanceof Error
            ? error.message
            : "Не удалось открыть страницу загрузки.",
        );
      }
      return;
    }
    if (needsNativeRecovery) {
      await checkForUpdates();
      return;
    }
    // A downloaded OTA can outlive (or be absent from) the API metadata. The shared
    // controller remains authoritative so this screen cannot start a second fetch flow.
    if (
      ota?.isSupported &&
      shouldShowOtaHeaderAction(ota.status) &&
      !nativeUpdateRequired
    ) {
      if (ota.status === "ready") {
        await ota.reload();
        return;
      }
      if (otaActionRunningRef.current || ota.isBusy) return;
      otaActionRunningRef.current = true;
      setIsOtaActionBusy(true);
      try {
        playLightImpactHaptic();
        await ota.checkForUpdate(true);
      } finally {
        otaActionRunningRef.current = false;
        setIsOtaActionBusy(false);
      }
      return;
    }
    if (!assessment.updateAvailable) {
      await checkForUpdates();
      return;
    }
    if (otaUpdateAvailable) {
      if (!ota?.isSupported) {
        setActionError(
          "Быстрое обновление недоступно в этой сборке. Проверьте установленную версию приложения.",
        );
        return;
      }
      if (ota.status === "ready") {
        await ota.reload();
        return;
      }
      if (otaActionRunningRef.current || ota.isBusy) return;
      otaActionRunningRef.current = true;
      setIsOtaActionBusy(true);
      try {
        playLightImpactHaptic();
        await ota.checkForUpdate(true);
      } finally {
        otaActionRunningRef.current = false;
        setIsOtaActionBusy(false);
      }
      return;
    }
    if (!canStartInstall || !update?.downloadUrl) {
      playErrorHaptic();
      setActionError(
        assessment.preflight.error || "Обновление недоступно для установки.",
      );
      return;
    }
    try {
      playLightImpactHaptic();
      if (signingMigration && !assessment.preflight.ok) {
        await Linking.openURL(update.downloadUrl);
        playSuccessHaptic();
        return;
      }
      await installManualUpdate(update, platform);
      playSuccessHaptic();
    } catch (error) {
      playErrorHaptic();
      setActionError(
        error instanceof Error
          ? error.message
          : "Не удалось открыть ссылку обновления.",
      );
    }
  }, [
    assessment.preflight.error,
    assessment.preflight.ok,
    assessment.updateAvailable,
    canStartInstall,
    checkForUpdates,
    nativeUpdateRequired,
    needsNativeRecovery,
    ota,
    otaUpdateAvailable,
    platform,
    signingMigration,
    update,
  ]);

  return (
    <ScrollView contentContainerStyle={styles.content}>
      <StatusHero
        assessmentTone={
          otaReadyWithoutMetadata ? "ok" : assessment.compatibilityTone
        }
        title={otaReadyWithoutMetadata ? "Обновление готово" : otaUpdateAvailable ? "Доступно обновление" : assessment.title}
        message={
          otaReadyWithoutMetadata
            ? ota?.message ||
              "Обновление скачано. Применим его безопасно, когда VPN можно отключить."
            : otaUpdateAvailable
              ? "Обновление установится без переустановки приложения."
              : assessment.message
        }
      />
      <View style={styles.section}>
        <InfoRow
          label="Ваша версия"
          value={appInfo?.version || Application.nativeApplicationVersion || "dev"}
        />
        {assessment.updateAvailable ? (
          <InfoRow
            label="Новая версия"
            value={update?.latestVersion || "Доступна"}
          />
        ) : null}
      </View>
      {assessment.updateAvailable && update?.changelog ? (
        <Text style={styles.notes}>{update.changelog}</Text>
      ) : null}
      {updateQuery.error ? (
        <Text style={styles.error}>
          Не удалось проверить обновления. Проверьте подключение.
        </Text>
      ) : null}
      {!canStartInstall &&
      assessment.updateAvailable &&
      nativeUpdateRequired ? (
        <Text style={styles.error}>{assessment.preflight.error}</Text>
      ) : null}
      {canOpenManualDownload && !assessment.preflight.ok ? (
        <Text style={styles.error}>
          Автоустановка недоступна для этой старой подписи. Скачайте APK с
          сайта, установите новую сборку и затем удалите старый VEX.
        </Text>
      ) : null}
      {actionError ? <Text style={styles.error}>{actionError}</Text> : null}
      <View style={styles.actions}>
        <Pressable
          disabled={primaryDisabled}
          onPress={handlePrimaryPress}
          style={[
            styles.primaryButton,
            primaryDisabled && styles.primaryButtonDisabled,
          ]}
        >
          <Text style={styles.primaryText}>
            {isPrimaryBusy
              ? "Проверяем"
              : otaReadyWithoutMetadata
                ? "Применить"
                : needsNativeRecovery
                  ? "Повторить проверку"
                  : assessment.updateAvailable
                    ? "Обновить"
                    : "Проверить обновления"}
          </Text>
        </Pressable>
      </View>
    </ScrollView>
  );
}

function StatusHero({
  assessmentTone,
  message,
  title,
}: {
  assessmentTone: "ok" | "warning" | "danger";
  message: string;
  title: string;
}) {
  const danger = assessmentTone === "danger";
  return (
    <View style={[styles.hero, danger && styles.heroDanger]}>
      <View style={[styles.heroIcon, danger && styles.heroIconDanger]}>
        {danger ? (
          <ShieldAlert color="#031012" size={28} strokeWidth={2.7} />
        ) : (
          <ShieldCheck color="#031012" size={28} strokeWidth={2.7} />
        )}
      </View>
      <Text style={styles.heroTitle}>{title}</Text>
      <Text style={styles.heroText}>{message}</Text>
    </View>
  );
}

function InfoRow({
  label,
  tone,
  value,
}: {
  label: string;
  tone?: "ok" | "warning" | "danger";
  value: string;
}) {
  return (
    <View style={styles.infoRow}>
      <Text style={styles.infoLabel}>{label}</Text>
      <Text
        numberOfLines={2}
        style={[
          styles.infoValue,
          tone === "ok" && styles.infoValueOk,
          tone === "warning" && styles.infoValueWarning,
          tone === "danger" && styles.infoValueDanger,
        ]}
      >
        {value}
      </Text>
    </View>
  );
}

function currentNativeBuild() {
  const parsed = Number.parseInt(
    String(Application.nativeBuildVersion ?? "0"),
    10,
  );
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 0;
}

function isAndroidSigningKeyMigration(
  update: AppUpdateCheckResult | null,
): boolean {
  const changelog = update?.changelog?.toLowerCase() || "";
  return (
    update?.reason === "android_signing_key_migration" ||
    changelog.includes("android-signing-key-migration") ||
    changelog.includes("новую сборку vex") ||
    changelog.includes("новую подпись") ||
    changelog.includes("новой подпись")
  );
}

async function openAndroidSigningMigrationDownload(): Promise<void> {
  const directUrl = androidSigningMigrationLandingUrl;
  try {
    await Linking.openURL(directUrl);
  } catch (error) {
    throw error;
  }
}

const styles = StyleSheet.create({
  headerButton: {
    alignItems: "center",
    height: 48,
    justifyContent: "center",
    width: 48,
  },
  headerButtonPressed: {
    opacity: 0.68,
  },
  noticeBanner: {
    alignItems: "center",
    backgroundColor: "rgba(255,122,122,0.14)",
    borderColor: "rgba(255,122,122,0.34)",
    borderRadius: 18,
    borderWidth: 1,
    flexDirection: "row",
    gap: 12,
    paddingHorizontal: 14,
    paddingVertical: 12,
  },
  noticeBannerMigration: {
    backgroundColor: "rgba(248,212,119,0.14)",
    borderColor: "rgba(248,212,119,0.38)",
  },
  noticeIcon: {
    alignItems: "center",
    backgroundColor: "#F8D477",
    borderRadius: 14,
    height: 34,
    justifyContent: "center",
    width: 34,
  },
  noticeCopy: {
    flex: 1,
    gap: 3,
  },
  noticeTitle: {
    color: "#F4FCFD",
    fontSize: 14,
    fontWeight: "900",
  },
  noticeText: {
    color: "#C6D6D9",
    fontSize: 12,
    fontWeight: "700",
    lineHeight: 16,
  },
  noticeAction: {
    color: "#F8D477",
    fontSize: 13,
    fontWeight: "900",
  },
  modal: {
    backgroundColor: "transparent",
    flex: 1,
  },
  routeShell: {
    paddingHorizontal: 18,
    paddingTop: Platform.OS === "android" ? 12 : 20,
  },
  modalHeader: {
    alignItems: "center",
    flexDirection: "row",
    justifyContent: "space-between",
    marginBottom: 16,
  },
  eyebrow: {
    color: "#22D3EE",
    fontSize: 12,
    fontWeight: "900",
    letterSpacing: 0,
  },
  modalTitle: {
    color: "#F4FCFD",
    fontSize: 22,
    fontWeight: "900",
    marginTop: 2,
  },
  closeButton: {
    alignItems: "center",
    backgroundColor: "rgba(255,255,255,0.06)",
    borderColor: "rgba(255,255,255,0.1)",
    borderRadius: 14,
    borderWidth: 1,
    height: 42,
    justifyContent: "center",
    width: 42,
  },
  content: {
    gap: 12,
    paddingBottom: 22,
  },
  hero: {
    alignItems: "center",
    backgroundColor: "rgba(8,25,29,0.84)",
    borderColor: "rgba(34,211,238,0.22)",
    borderRadius: 26,
    borderWidth: 1,
    gap: 12,
    padding: 22,
  },
  heroDanger: {
    borderColor: "rgba(255,122,122,0.34)",
  },
  heroIcon: {
    alignItems: "center",
    backgroundColor: "#22D3EE",
    borderRadius: 20,
    height: 48,
    justifyContent: "center",
    width: 48,
  },
  heroIconDanger: {
    backgroundColor: "#FFB4A8",
  },
  heroTitle: {
    color: "#F4FCFD",
    fontSize: 24,
    fontWeight: "900",
    textAlign: "center",
  },
  heroText: {
    color: "#C6D6D9",
    fontSize: 15,
    fontWeight: "700",
    lineHeight: 21,
    textAlign: "center",
  },
  section: {
    backgroundColor: "rgba(7,17,19,0.86)",
    borderColor: "rgba(96,118,123,0.32)",
    borderRadius: 22,
    borderWidth: 1,
    overflow: "hidden",
  },
  infoRow: {
    alignItems: "center",
    borderBottomColor: "rgba(96,118,123,0.18)",
    borderBottomWidth: 1,
    flexDirection: "row",
    gap: 12,
    justifyContent: "space-between",
    minHeight: 52,
    paddingHorizontal: 12,
    paddingVertical: 9,
  },
  infoLabel: {
    color: "#8FBEC6",
    flex: 0.8,
    fontSize: 13,
    fontWeight: "900",
  },
  infoValue: {
    color: "#EAF7F8",
    flex: 1.2,
    fontSize: 13,
    fontWeight: "900",
    textAlign: "right",
  },
  infoValueOk: {
    color: "#6CF5FF",
  },
  infoValueWarning: {
    color: "#F8D477",
  },
  infoValueDanger: {
    color: "#FFB4A8",
  },
  notes: {
    backgroundColor: "rgba(34,211,238,0.08)",
    borderColor: "rgba(34,211,238,0.16)",
    borderRadius: 18,
    borderWidth: 1,
    color: "#A7B9BD",
    fontSize: 14,
    fontWeight: "700",
    lineHeight: 20,
    padding: 12,
  },
  error: {
    color: "#FF9F9F",
    fontSize: 13,
    fontWeight: "800",
    textAlign: "center",
  },
  actions: {
    flexDirection: "row",
    gap: 10,
  },
  secondaryButton: {
    alignItems: "center",
    borderColor: "rgba(167,185,189,0.24)",
    borderRadius: 18,
    borderWidth: 1,
    flex: 1,
    flexDirection: "row",
    gap: 8,
    justifyContent: "center",
    minHeight: 50,
  },
  secondaryText: {
    color: "#A7B9BD",
    fontSize: 15,
    fontWeight: "900",
  },
  primaryButton: {
    alignItems: "center",
    backgroundColor: "#22D3EE",
    borderRadius: 8,
    flex: 1.25,
    justifyContent: "center",
    minHeight: 50,
    paddingHorizontal: 10,
  },
  primaryButtonDisabled: {
    opacity: 0.46,
  },
  primaryText: {
    color: "#031012",
    fontSize: 15,
    fontWeight: "900",
    textAlign: "center",
  },
  footnote: {
    color: "#78969C",
    fontSize: 12,
    fontWeight: "700",
    lineHeight: 17,
    textAlign: "center",
  },
});
