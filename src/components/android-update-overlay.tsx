import * as Application from 'expo-application';
import { Download, ShieldCheck } from 'lucide-react-native';
import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { Linking, Modal, Platform, Pressable, StyleSheet, Text, View } from 'react-native';
import { installManualUpdate } from '@/api/manualUpdateInstall';
import { validateManualUpdatePayload, type AppUpdateCheckResult } from '@/api/vexApi';
import { useMobileAppUpdateQuery } from '@/components/mobile-app-update-query';
import { playErrorHaptic, playLightImpactHaptic, playSelectionHaptic, playSuccessHaptic } from '@/native/haptics';

const androidBuild = currentAndroidBuild();
const androidSigningMigrationLandingUrl = 'https://vexguard.app/download';

type DownloadState =
  | { status: 'idle' }
  | { status: 'ready'; build: number }
  | { status: 'installing'; build: number }
  | { status: 'permission_required'; build: number }
  | { status: 'installer_opened'; build: number }
  | { status: 'error'; build: number; message: string };

export function AndroidUpdateOverlay() {
  if (Platform.OS !== 'android') {
    return null;
  }

  return <AndroidUpdateOverlayContent />;
}

function AndroidUpdateOverlayContent() {
  const updateQuery = useMobileAppUpdateQuery('android', androidBuild);
  const update = updateQuery.data ?? null;
  const [downloadState, setDownloadState] = useState<DownloadState>({ status: 'idle' });
  const [dismissedBuild, setDismissedBuild] = useState<number | null>(null);
  const [installerOpenedBuild, setInstallerOpenedBuild] = useState<number | null>(null);

  const preflight = useMemo(() => {
    if (!update?.updateAvailable) {
      return { ok: false, error: 'Обновление не найдено.' };
    }
    return validateManualUpdatePayload({
      downloadUrl: update.downloadUrl,
      checksumSha256: update.checksumSha256,
      signatureUrl: update.signatureUrl,
    });
  }, [update]);

  useEffect(() => {
    if (!update?.updateAvailable || !preflight.ok || installerOpenedBuild === update.latestBuild) {
      return;
    }
    setDownloadState({ status: 'ready', build: update.latestBuild });
  }, [installerOpenedBuild, preflight.ok, update?.latestBuild, update?.updateAvailable]);

  useEffect(() => {
    if (updateQuery.error && update?.required) {
      setDownloadState({ status: 'error', build: update.latestBuild, message: 'Не удалось проверить обновление.' });
    }
  }, [update?.latestBuild, update?.required, updateQuery.error]);

  const shouldShow = shouldShowUpdateSheet(update, downloadState, dismissedBuild, installerOpenedBuild, preflight);
  const signingMigration = isAndroidSigningKeyMigration(update);
  const canOpenManualDownload = signingMigration;
  const handleDismiss = useCallback(() => {
    if (update?.latestBuild) {
      playSelectionHaptic();
      setDismissedBuild(update.latestBuild);
    }
  }, [update?.latestBuild]);

  const handleOpenManualDownload = useCallback(async () => {
    if (!update) {
      return;
    }
    try {
      playLightImpactHaptic();
      await Linking.openURL(androidSigningMigrationLandingUrl);
      setDismissedBuild(update.latestBuild);
    } catch (error) {
      playErrorHaptic();
      setDownloadState({
        status: 'error',
        build: update.latestBuild,
        message: error instanceof Error ? error.message : 'Не удалось открыть страницу загрузки.',
      });
    }
  }, [update]);

  const handleInstall = useCallback(async () => {
    if (downloadState.status !== 'ready' && downloadState.status !== 'permission_required') {
      return;
    }
    playLightImpactHaptic();
    try {
      if (!update) {
        throw new Error('Данные обновления недоступны.');
      }
      setDownloadState({ status: 'installing', build: downloadState.build });
      const result = await installManualUpdate(update, 'android');
      if (result.status === 'install_permission_required') {
        setDownloadState({ status: 'permission_required', build: update.latestBuild });
        return;
      }
      setInstallerOpenedBuild(update.latestBuild);
      setDismissedBuild(update.latestBuild);
      setDownloadState({ status: 'installer_opened', build: update.latestBuild });
      playSuccessHaptic();
    } catch (error) {
      playErrorHaptic();
      const message = error instanceof Error && error.message ? error.message : 'Не удалось открыть ссылку обновления.';
      setDownloadState({ status: 'error', build: downloadState.build, message });
    }
  }, [downloadState, update]);

  const handleRetryDownload = useCallback(() => {
    if (!update?.latestBuild || !preflight.ok) {
      return;
    }
    playLightImpactHaptic();
    setDownloadState({ status: 'ready', build: update.latestBuild });
  }, [preflight.ok, update?.latestBuild]);

  if (!shouldShow || !update) {
    return null;
  }

  const isReady = downloadState.status === 'ready';
  const isError = downloadState.status === 'error';
  const needsInstallPermission = downloadState.status === 'permission_required';
  const canRetry = isError && preflight.ok;
  const canUsePrimary = canOpenManualDownload || isReady || canRetry || needsInstallPermission;
  const primaryDisabled = !canUsePrimary;
  const title = update.currentBuildBlocked
    ? 'Сборка отозвана'
    : signingMigration
      ? 'Новая Android-сборка VEX'
      : needsInstallPermission
        ? 'Разрешите установку APK'
        : isReady
          ? 'Обновление готово'
          : update.required
            ? 'Нужно обновить VEX'
            : 'Готовим обновление';
  const text = isReady
    ? signingMigration
      ? 'Это новая сборка с другой подписью. Скачайте APK, установите его как новое приложение, войдите в аккаунт и после проверки доступа удалите старый VEX.'
      : update.currentBuildBlocked
        ? 'Установите предложенную стабильную версию, чтобы вернуться на поддерживаемую сборку.'
        : 'VEX скачает APK, проверит checksum и подпись приложения, затем откроет системный установщик.'
    : needsInstallPermission
      ? 'Android открыл настройки установки из этого источника. Включите разрешение для VEX, вернитесь сюда и нажмите продолжить установку.'
      : isError
        ? 'Не удалось подготовить обновление. Проверьте подключение и попробуйте позже.'
        : signingMigration
          ? 'Откройте сайт VEX, скачайте новую сборку, установите ее и удалите старую после входа в аккаунт.'
          : 'VEX готовит ссылку на новую версию.';

  return (
    <Modal animationType="slide" onRequestClose={handleDismiss} transparent visible>
      <View style={styles.backdrop}>
        <View style={styles.sheet}>
          <View style={styles.handle} />
          <View style={styles.header}>
            <View style={styles.icon}>
              {isReady ? <ShieldCheck color="#031012" size={26} strokeWidth={2.7} /> : <Download color="#031012" size={25} strokeWidth={2.7} />}
            </View>
            <View style={styles.headerCopy}>
              <Text style={styles.eyebrow}>VEX Android</Text>
              <Text style={styles.title}>{title}</Text>
            </View>
          </View>
          <Text style={styles.text}>{text}</Text>
          {update.changelog ? <Text style={styles.notes}>{update.changelog}</Text> : null}
          <View style={styles.versionRow}>
            <Text style={styles.versionText}>Сейчас: {Application.nativeApplicationVersion || 'dev'} ({androidBuild || 0})</Text>
            <Text style={styles.versionText}>Новая: {update.latestVersion} ({update.latestBuild})</Text>
          </View>
          {!preflight.ok ? <Text style={styles.error}>{preflight.error}</Text> : null}
          {isError ? <Text style={styles.error}>{downloadState.message}</Text> : null}
          <View style={styles.actions}>
            <Pressable onPress={handleDismiss} style={styles.secondaryButton}>
              <Text style={styles.secondaryText}>{update.required ? 'Закрыть' : 'Позже'}</Text>
            </Pressable>
            <Pressable
              disabled={primaryDisabled}
              onPress={canOpenManualDownload ? handleOpenManualDownload : isReady || needsInstallPermission ? handleInstall : handleRetryDownload}
              style={[styles.primaryButton, primaryDisabled && styles.primaryButtonDisabled]}
            >
              <Text style={styles.primaryText}>
                {isReady
                  ? signingMigration
                    ? 'Скачать с сайта'
                    : update.currentBuildBlocked
                      ? 'Вернуться на стабильную'
                      : 'Установить'
                  : needsInstallPermission
                    ? 'Продолжить установку'
                    : canOpenManualDownload
                      ? 'Скачать с сайта'
                      : canRetry
                        ? 'Повторить'
                        : 'Подождите'}
              </Text>
            </Pressable>
          </View>
        </View>
      </View>
    </Modal>
  );
}

function shouldShowUpdateSheet(
  update: AppUpdateCheckResult | null,
  downloadState: DownloadState,
  dismissedBuild: number | null,
  installerOpenedBuild: number | null,
  preflight: { ok: boolean; error?: string },
): boolean {
  if (!update?.updateAvailable) {
    return false;
  }
  if (installerOpenedBuild === update.latestBuild) {
    return false;
  }
  if (!update.required && dismissedBuild === update.latestBuild) {
    return false;
  }
  if (!preflight.ok) {
    return update.required;
  }
  if (update.required) {
    return true;
  }
  return downloadState.status === 'ready';
}

function isAndroidSigningKeyMigration(update: AppUpdateCheckResult | null): boolean {
  const changelog = update?.changelog?.toLowerCase() || '';
  return (
    update?.reason === 'android_signing_key_migration' ||
    changelog.includes('android-signing-key-migration') ||
    changelog.includes('новую сборку vex') ||
    changelog.includes('новую подпись') ||
    changelog.includes('новой подпись')
  );
}

function currentAndroidBuild() {
  const parsed = Number.parseInt(String(Application.nativeBuildVersion ?? '0'), 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 0;
}

const styles = StyleSheet.create({
  backdrop: {
    backgroundColor: 'rgba(2,10,11,0.46)',
    flex: 1,
    justifyContent: 'flex-end',
  },
  sheet: {
    backgroundColor: '#071113',
    borderColor: 'rgba(34,211,238,0.30)',
    borderTopLeftRadius: 22,
    borderTopRightRadius: 22,
    borderWidth: 1,
    gap: 12,
    paddingBottom: 18,
    paddingHorizontal: 18,
    paddingTop: 10,
  },
  handle: {
    alignSelf: 'center',
    backgroundColor: 'rgba(167,185,189,0.45)',
    borderRadius: 999,
    height: 4,
    marginBottom: 4,
    width: 42,
  },
  header: {
    alignItems: 'center',
    flexDirection: 'row',
    gap: 12,
  },
  icon: {
    alignItems: 'center',
    backgroundColor: '#22D3EE',
    borderRadius: 15,
    height: 42,
    justifyContent: 'center',
    width: 42,
  },
  headerCopy: {
    flex: 1,
    minWidth: 0,
  },
  eyebrow: {
    color: '#22D3EE',
    fontSize: 11,
    fontWeight: '900',
    textTransform: 'uppercase',
  },
  title: {
    color: '#F4FCFD',
    fontSize: 21,
    fontWeight: '900',
    marginTop: 2,
  },
  text: {
    color: '#C6D6D9',
    fontSize: 14,
    fontWeight: '600',
    lineHeight: 20,
  },
  notes: {
    backgroundColor: 'rgba(34,211,238,0.08)',
    borderColor: 'rgba(34,211,238,0.16)',
    borderRadius: 14,
    borderWidth: 1,
    color: '#A7B9BD',
    fontSize: 13,
    lineHeight: 18,
    padding: 10,
  },
  versionRow: {
    backgroundColor: 'rgba(2,10,11,0.72)',
    borderRadius: 14,
    gap: 5,
    padding: 10,
  },
  versionText: {
    color: '#A7B9BD',
    fontSize: 12,
    fontWeight: '800',
  },
  error: {
    color: '#FF9F9F',
    fontSize: 13,
    fontWeight: '800',
  },
  loadingRow: {
    alignItems: 'center',
    flexDirection: 'row',
    gap: 10,
    minHeight: 34,
  },
  loadingText: {
    color: '#A7B9BD',
    fontSize: 13,
    fontWeight: '800',
  },
  actions: {
    flexDirection: 'row',
    gap: 10,
  },
  primaryButton: {
    alignItems: 'center',
    backgroundColor: '#22D3EE',
    borderRadius: 15,
    flex: 1,
    justifyContent: 'center',
    minHeight: 48,
  },
  primaryButtonDisabled: {
    opacity: 0.48,
  },
  primaryText: {
    color: '#031012',
    fontSize: 15,
    fontWeight: '900',
  },
  secondaryButton: {
    alignItems: 'center',
    borderColor: 'rgba(167,185,189,0.24)',
    borderRadius: 15,
    borderWidth: 1,
    flex: 1,
    justifyContent: 'center',
    minHeight: 48,
  },
  secondaryText: {
    color: '#A7B9BD',
    fontSize: 15,
    fontWeight: '900',
  },
});
