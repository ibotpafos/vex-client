import * as Application from 'expo-application';
import { Download, RefreshCw, ShieldAlert, ShieldCheck, X } from 'lucide-react-native';
import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { ActivityIndicator, Linking, Modal, Platform, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { assessManualUpdateCenter } from '@/api/updatePreflight';
import { vexApiBaseUrl, type AppUpdateCheckResult } from '@/api/vexApi';
import { useDesktopUpdate } from '@/components/desktop-update-overlay';
import { useMobileAppUpdateQuery } from '@/components/mobile-app-update-query';
import { getAppInfo, type AppInfo } from '@/native/appInfo';
import { playErrorHaptic, playLightImpactHaptic, playSelectionHaptic, playSuccessHaptic } from '@/native/haptics';
import { vexSharedStyles } from '@/ui/vex-ui';

type UpdateCenterButtonProps = {
  visible: boolean;
  onOpen: () => void;
  onClose: () => void;
};

export function UpdateCenterButton({ visible, onOpen, onClose }: UpdateCenterButtonProps) {
  if (isTauriRuntime()) {
    return <DesktopUpdateCenterButton visible={visible} onClose={onClose} onOpen={onOpen} />;
  }
  if (Platform.OS === 'android' || Platform.OS === 'ios') {
    return <MobileUpdateCenterButton platform={Platform.OS} visible={visible} onClose={onClose} onOpen={onOpen} />;
  }
  return null;
}

function MobileUpdateCenterButton({
  onClose,
  onOpen,
  platform,
  visible,
}: UpdateCenterButtonProps & { platform: 'android' | 'ios' }) {
  const buildNumber = currentNativeBuild();
  const updateQuery = useMobileAppUpdateQuery(platform, buildNumber);
  const update = updateQuery.data ?? null;
  const needsAttention = Boolean(update?.required || update?.currentBuildBlocked);
  const hasUpdate = Boolean(update?.updateAvailable);

  return (
    <>
      <HeaderButton
        busy={updateQuery.isFetching}
        danger={needsAttention}
        highlighted={hasUpdate}
        onPress={onOpen}
      />
      <UpdateCenterModal visible={visible} onClose={onClose}>
        <MobileUpdateCenterContent buildNumber={buildNumber} platform={platform} update={update} updateQuery={updateQuery} />
      </UpdateCenterModal>
    </>
  );
}

function DesktopUpdateCenterButton({ onClose, onOpen, visible }: UpdateCenterButtonProps) {
  const update = useDesktopUpdate();
  const needsAttention = Boolean(update.required || update.status === 'error');
  const hasUpdate = update.status === 'downloading' || update.status === 'ready';

  return (
    <>
      <HeaderButton
        busy={update.status === 'checking' || update.status === 'downloading'}
        danger={needsAttention}
        highlighted={hasUpdate}
        onPress={onOpen}
      />
      <UpdateCenterModal visible={visible} onClose={onClose}>
        <DesktopUpdateCenterContent />
      </UpdateCenterModal>
    </>
  );
}

function HeaderButton({
  busy,
  danger,
  highlighted,
  onPress,
}: {
  busy: boolean;
  danger: boolean;
  highlighted: boolean;
  onPress: () => void;
}) {
  return (
    <Pressable
      accessibilityLabel="Центр обновлений"
      accessibilityRole="button"
      onPress={() => {
        playSelectionHaptic();
        onPress();
      }}
      style={[
        vexSharedStyles.iconButton,
        highlighted && styles.headerButtonHighlighted,
        danger && styles.headerButtonDanger,
      ]}
    >
      {busy ? <ActivityIndicator color="#22D3EE" size="small" /> : <Download color={danger ? '#FFB4A8' : highlighted ? '#031012' : '#A7B9BD'} size={23} strokeWidth={2.5} />}
      {danger || highlighted ? <View style={[styles.headerBadge, danger && styles.headerBadgeDanger]} /> : null}
    </Pressable>
  );
}

function UpdateCenterModal({
  children,
  onClose,
  visible,
}: {
  children: React.ReactNode;
  onClose: () => void;
  visible: boolean;
}) {
  if (!visible) {
    return null;
  }

  return (
    <Modal animationType="slide" onRequestClose={onClose} presentationStyle="fullScreen" visible={visible}>
      <View style={styles.modal}>
        <View style={styles.modalHeader}>
          <View>
            <Text style={styles.eyebrow}>VEX</Text>
            <Text style={styles.modalTitle}>Обновления</Text>
          </View>
          <Pressable accessibilityLabel="Закрыть центр обновлений" onPress={onClose} style={styles.closeButton}>
            <X color="#A7B9BD" size={24} strokeWidth={2.5} />
          </Pressable>
        </View>
        {children}
      </View>
    </Modal>
  );
}

function MobileUpdateCenterContent({
  buildNumber,
  platform,
  update,
  updateQuery,
}: {
  buildNumber: number;
  platform: 'android' | 'ios';
  update: AppUpdateCheckResult | null;
  updateQuery: ReturnType<typeof useMobileAppUpdateQuery>;
}) {
  const [appInfo, setAppInfo] = useState<AppInfo | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);

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

  const assessment = useMemo(() => assessManualUpdateCenter({
    currentBuild: buildNumber,
    currentVersion: appInfo?.version || Application.nativeApplicationVersion || 'dev',
    trustedBaseUrl: vexApiBaseUrl,
    update,
  }), [appInfo?.version, buildNumber, update]);

  const handlePrimaryPress = useCallback(async () => {
    setActionError(null);
    if (!assessment.updateAvailable) {
      playLightImpactHaptic();
      await updateQuery.refetch();
      return;
    }
    if (!assessment.canInstall || !update?.downloadUrl) {
      playErrorHaptic();
      setActionError(assessment.preflight.error || 'Обновление недоступно для установки.');
      return;
    }
    try {
      playLightImpactHaptic();
      await Linking.openURL(update.downloadUrl);
      playSuccessHaptic();
    } catch {
      playErrorHaptic();
      setActionError('Не удалось открыть ссылку обновления.');
    }
  }, [assessment, update?.downloadUrl, updateQuery]);

  return (
    <ScrollView contentContainerStyle={styles.content}>
      <StatusHero assessmentTone={assessment.compatibilityTone} title={assessment.title} message={assessment.message} />
      <View style={styles.section}>
        <InfoRow label="Текущая версия" value={`${appInfo?.version || Application.nativeApplicationVersion || 'dev'} (${buildNumber || 0})`} />
        <InfoRow label="Доступная версия" value={update?.updateAvailable ? `${update.latestVersion || 'unknown'} (${update.latestBuild || 0})` : 'Нет новой версии'} />
        <InfoRow label="Канал" value={update?.channel || appInfo?.channel || 'production'} />
        <InfoRow label="Совместимость" tone={assessment.compatibilityTone} value={assessment.compatibilityLabel} />
        <InfoRow label="Подпись" tone={assessment.signatureTone} value={assessment.signatureLabel} />
        {update?.minSupportedBuild ? <InfoRow label="Минимальная сборка" value={String(update.minSupportedBuild)} /> : null}
        {update?.rolloutPercent !== undefined ? <InfoRow label="Rollout" value={`${update.rolloutPercent}%`} /> : null}
      </View>
      {update?.changelog ? <Text style={styles.notes}>{update.changelog}</Text> : null}
      {updateQuery.error ? <Text style={styles.error}>Не удалось проверить обновления. Проверьте подключение.</Text> : null}
      {!assessment.canInstall && assessment.updateAvailable ? <Text style={styles.error}>{assessment.preflight.error}</Text> : null}
      {actionError ? <Text style={styles.error}>{actionError}</Text> : null}
      <View style={styles.actions}>
        <Pressable disabled={updateQuery.isFetching} onPress={() => { void updateQuery.refetch(); }} style={styles.secondaryButton}>
          <RefreshCw color="#A7B9BD" size={18} strokeWidth={2.5} />
          <Text style={styles.secondaryText}>{updateQuery.isFetching ? 'Проверяем' : 'Проверить'}</Text>
        </Pressable>
        <Pressable onPress={handlePrimaryPress} style={[styles.primaryButton, !assessment.canInstall && assessment.updateAvailable && styles.primaryButtonDisabled]}>
          <Text style={styles.primaryText}>{assessment.actionLabel}</Text>
        </Pressable>
      </View>
      <Text style={styles.footnote}>
        {platform === 'android'
          ? 'Android откроет официальный APK. После загрузки подтвердите установку в системном установщике.'
          : 'iOS откроет официальную страницу обновления.'}
      </Text>
    </ScrollView>
  );
}

function DesktopUpdateCenterContent() {
  const update = useDesktopUpdate();
  const progress = update.contentLength > 0
    ? Math.min(99, Math.max(1, Math.round((update.downloadedBytes / update.contentLength) * 100)))
    : null;
  const isUpdaterError = update.status === 'error';
  const hasReadyUpdate = update.status === 'ready';
  const title = hasReadyUpdate
    ? 'Обновление готово'
    : update.status === 'downloading'
      ? 'Скачиваем обновление'
      : isUpdaterError
        ? 'Проверка не удалась'
        : 'VEX обновлен';
  const message = hasReadyUpdate
    ? 'Перезапустите приложение, чтобы применить уже загруженную версию.'
    : update.status === 'downloading'
      ? 'Tauri updater скачивает подписанный пакет обновления.'
      : isUpdaterError
        ? 'Не удалось проверить или скачать desktop update.'
        : 'Desktop-клиент совместим с текущим каналом обновлений.';
  const primaryLabel = hasReadyUpdate ? 'Перезапустить' : isUpdaterError ? 'Недоступно' : 'Актуально';

  return (
    <ScrollView contentContainerStyle={styles.content}>
      <StatusHero assessmentTone={isUpdaterError ? 'danger' : update.required ? 'warning' : 'ok'} title={title} message={message} />
      <View style={styles.section}>
        <InfoRow label="Текущая версия" value={update.currentVersion} />
        <InfoRow label="Доступная версия" value={update.latestVersion || 'Нет новой версии'} />
        <InfoRow label="Канал" value={update.releaseChannel || 'stable'} />
        <InfoRow label="Совместимость" tone={update.required ? 'danger' : 'ok'} value={update.required ? 'Требуется обновление' : 'Совместимо'} />
        <InfoRow label="Подпись" tone="ok" value="Проверяется Tauri updater" />
        {progress !== null && update.status === 'downloading' ? <InfoRow label="Загрузка" value={`${progress}%`} /> : null}
      </View>
      {update.releaseNotes ? <Text style={styles.notes}>{update.releaseNotes}</Text> : null}
      {update.error ? <Text style={styles.error}>{update.error}</Text> : null}
      <View style={styles.actions}>
        <Pressable disabled={update.status === 'checking' || update.status === 'downloading'} onPress={() => { void update.checkNow(); }} style={styles.secondaryButton}>
          <RefreshCw color="#A7B9BD" size={18} strokeWidth={2.5} />
          <Text style={styles.secondaryText}>{update.status === 'checking' ? 'Проверяем' : 'Проверить'}</Text>
        </Pressable>
        <Pressable disabled={!hasReadyUpdate} onPress={() => { void update.relaunchToUpdate(); }} style={[styles.primaryButton, !hasReadyUpdate && styles.primaryButtonDisabled]}>
          <Text style={styles.primaryText}>{primaryLabel}</Text>
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
  assessmentTone: 'ok' | 'warning' | 'danger';
  message: string;
  title: string;
}) {
  const danger = assessmentTone === 'danger';
  return (
    <View style={[styles.hero, danger && styles.heroDanger]}>
      <View style={[styles.heroIcon, danger && styles.heroIconDanger]}>
        {danger ? <ShieldAlert color="#031012" size={28} strokeWidth={2.7} /> : <ShieldCheck color="#031012" size={28} strokeWidth={2.7} />}
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
  tone?: 'ok' | 'warning' | 'danger';
  value: string;
}) {
  return (
    <View style={styles.infoRow}>
      <Text style={styles.infoLabel}>{label}</Text>
      <Text numberOfLines={2} style={[styles.infoValue, tone === 'ok' && styles.infoValueOk, tone === 'warning' && styles.infoValueWarning, tone === 'danger' && styles.infoValueDanger]}>
        {value}
      </Text>
    </View>
  );
}

function currentNativeBuild() {
  const parsed = Number.parseInt(String(Application.nativeBuildVersion ?? '0'), 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 0;
}

function isTauriRuntime(): boolean {
  return Platform.OS === 'web' && typeof window !== 'undefined' && ('__TAURI_INTERNALS__' in window || '__TAURI__' in window || '__TAURI_INVOKE__' in window);
}

const styles = StyleSheet.create({
  headerButtonHighlighted: {
    backgroundColor: '#22D3EE',
    borderColor: '#22D3EE',
  },
  headerButtonDanger: {
    backgroundColor: 'rgba(255,122,122,0.14)',
    borderColor: 'rgba(255,122,122,0.44)',
  },
  headerBadge: {
    backgroundColor: '#031012',
    borderColor: '#22D3EE',
    borderRadius: 5,
    borderWidth: 1,
    height: 10,
    position: 'absolute',
    right: 7,
    top: 7,
    width: 10,
  },
  headerBadgeDanger: {
    backgroundColor: '#FF7A7A',
    borderColor: '#071113',
  },
  modal: {
    backgroundColor: '#020A0B',
    flex: 1,
    paddingHorizontal: 14,
    paddingTop: Platform.OS === 'android' ? 34 : 46,
  },
  modalHeader: {
    alignItems: 'center',
    flexDirection: 'row',
    justifyContent: 'space-between',
    marginBottom: 12,
  },
  eyebrow: {
    color: '#22D3EE',
    fontSize: 12,
    fontWeight: '900',
    letterSpacing: 0,
  },
  modalTitle: {
    color: '#F4FCFD',
    fontSize: 22,
    fontWeight: '900',
    marginTop: 2,
  },
  closeButton: {
    alignItems: 'center',
    backgroundColor: 'rgba(255,255,255,0.06)',
    borderColor: 'rgba(255,255,255,0.1)',
    borderRadius: 14,
    borderWidth: 1,
    height: 42,
    justifyContent: 'center',
    width: 42,
  },
  content: {
    gap: 12,
    paddingBottom: 22,
  },
  hero: {
    alignItems: 'center',
    backgroundColor: 'rgba(8,25,29,0.84)',
    borderColor: 'rgba(34,211,238,0.22)',
    borderRadius: 8,
    borderWidth: 1,
    gap: 10,
    padding: 18,
  },
  heroDanger: {
    borderColor: 'rgba(255,122,122,0.34)',
  },
  heroIcon: {
    alignItems: 'center',
    backgroundColor: '#22D3EE',
    borderRadius: 20,
    height: 48,
    justifyContent: 'center',
    width: 48,
  },
  heroIconDanger: {
    backgroundColor: '#FFB4A8',
  },
  heroTitle: {
    color: '#F4FCFD',
    fontSize: 24,
    fontWeight: '900',
    textAlign: 'center',
  },
  heroText: {
    color: '#C6D6D9',
    fontSize: 15,
    fontWeight: '700',
    lineHeight: 21,
    textAlign: 'center',
  },
  section: {
    backgroundColor: 'rgba(7,17,19,0.86)',
    borderColor: 'rgba(96,118,123,0.32)',
    borderRadius: 8,
    borderWidth: 1,
    overflow: 'hidden',
  },
  infoRow: {
    alignItems: 'center',
    borderBottomColor: 'rgba(96,118,123,0.18)',
    borderBottomWidth: 1,
    flexDirection: 'row',
    gap: 12,
    justifyContent: 'space-between',
    minHeight: 52,
    paddingHorizontal: 12,
    paddingVertical: 9,
  },
  infoLabel: {
    color: '#8FBEC6',
    flex: 0.8,
    fontSize: 13,
    fontWeight: '900',
  },
  infoValue: {
    color: '#EAF7F8',
    flex: 1.2,
    fontSize: 13,
    fontWeight: '900',
    textAlign: 'right',
  },
  infoValueOk: {
    color: '#6CF5FF',
  },
  infoValueWarning: {
    color: '#F8D477',
  },
  infoValueDanger: {
    color: '#FFB4A8',
  },
  notes: {
    backgroundColor: 'rgba(34,211,238,0.08)',
    borderColor: 'rgba(34,211,238,0.16)',
    borderRadius: 8,
    borderWidth: 1,
    color: '#A7B9BD',
    fontSize: 14,
    fontWeight: '700',
    lineHeight: 20,
    padding: 12,
  },
  error: {
    color: '#FF9F9F',
    fontSize: 13,
    fontWeight: '800',
    textAlign: 'center',
  },
  actions: {
    flexDirection: 'row',
    gap: 10,
  },
  secondaryButton: {
    alignItems: 'center',
    borderColor: 'rgba(167,185,189,0.24)',
    borderRadius: 8,
    borderWidth: 1,
    flex: 1,
    flexDirection: 'row',
    gap: 8,
    justifyContent: 'center',
    minHeight: 50,
  },
  secondaryText: {
    color: '#A7B9BD',
    fontSize: 15,
    fontWeight: '900',
  },
  primaryButton: {
    alignItems: 'center',
    backgroundColor: '#22D3EE',
    borderRadius: 8,
    flex: 1.25,
    justifyContent: 'center',
    minHeight: 50,
    paddingHorizontal: 10,
  },
  primaryButtonDisabled: {
    opacity: 0.46,
  },
  primaryText: {
    color: '#031012',
    fontSize: 15,
    fontWeight: '900',
    textAlign: 'center',
  },
  footnote: {
    color: '#78969C',
    fontSize: 12,
    fontWeight: '700',
    lineHeight: 17,
    textAlign: 'center',
  },
});
