import * as Application from 'expo-application';
import { Button, Column, Host, List, ListItem, Spacer, Text as UniversalText } from '@expo/ui';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { AppState, Linking, Modal, Platform, StyleSheet } from 'react-native';
import { installManualUpdate } from '@/api/manualUpdateInstall';
import { requiresNativeUpdate } from '@/api/updatePreflight';
import { validateManualUpdatePayload, type AppUpdateCheckResult } from '@/api/vexApi';
import { useMobileAppUpdateQuery } from '@/components/mobile-app-update-query';
import { createAndroidUpdateInstallGate } from '@/components/android-update-install-gate';
import { playErrorHaptic, playLightImpactHaptic, playSelectionHaptic, playSuccessHaptic } from '@/native/haptics';
import * as SecureStore from '@/native/secureStore';

const androidBuild = currentAndroidBuild();
const androidSigningMigrationLandingUrl = 'https://vexguard.app/download';
const pendingAndroidInstallKey = 'vex.android.update.pending-install.v1';

type PendingAndroidInstall = {
  build: number;
  resumeAttempted: boolean;
};

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
  const installGate = useRef(createAndroidUpdateInstallGate()).current;
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
    if (installGate.isRunning()) return;
    if (update?.latestBuild) {
      playSelectionHaptic();
      setDismissedBuild(update.latestBuild);
      void SecureStore.deleteItemAsync(pendingAndroidInstallKey).catch(() => undefined);
    }
  }, [installGate, update?.latestBuild]);

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

  const performInstall = useCallback(async (build: number, resumeAttempted: boolean) => {
    await installGate.run(async () => {
      playLightImpactHaptic();
      try {
        if (!update || update.latestBuild !== build) {
          throw new Error('Данные обновления недоступны.');
        }
        setDownloadState({ status: 'installing', build });
        await SecureStore.setItemAsync(pendingAndroidInstallKey, JSON.stringify({ build, resumeAttempted }));
        const result = await installManualUpdate(update, 'android');
        if (result.status === 'install_permission_required') {
          setDownloadState({ status: 'permission_required', build: update.latestBuild });
          return;
        }
        await SecureStore.deleteItemAsync(pendingAndroidInstallKey).catch(() => undefined);
        setInstallerOpenedBuild(update.latestBuild);
        setDismissedBuild(update.latestBuild);
        setDownloadState({ status: 'installer_opened', build: update.latestBuild });
        playSuccessHaptic();
      } catch (error) {
        await SecureStore.deleteItemAsync(pendingAndroidInstallKey).catch(() => undefined);
        playErrorHaptic();
        const message = error instanceof Error && error.message ? error.message : 'Не удалось открыть ссылку обновления.';
        setDownloadState({ status: 'error', build, message });
      }
    });
  }, [installGate, update]);

  const handleInstall = useCallback(async () => {
    if (downloadState.status !== 'ready' && downloadState.status !== 'permission_required') {
      return;
    }
    await performInstall(downloadState.build, false);
  }, [downloadState, performInstall]);

  useEffect(() => {
    if (!update?.latestBuild) {
      return;
    }
    let cancelled = false;
    let restoring = false;

    const restorePendingInstall = async () => {
      if (cancelled || restoring || installGate.isRunning()) {
        return;
      }
      restoring = true;
      try {
        const pending = parsePendingAndroidInstall(
          await SecureStore.getItemAsync(pendingAndroidInstallKey).catch(() => null),
        );
        if (cancelled || installGate.isRunning() || !pending || pending.build !== update.latestBuild) {
          return;
        }
        setDownloadState({ status: 'permission_required', build: pending.build });
        // Native onHostResume owns automatic permission-return installation.
        // JS restores the retry UI only, avoiding a second download/installer.
      } finally {
        restoring = false;
      }
    };

    void restorePendingInstall();
    const subscription = AppState.addEventListener('change', (state) => {
      if (state === 'active') {
        void restorePendingInstall();
      }
    });
    return () => {
      cancelled = true;
      subscription.remove();
    };
  }, [installGate, update?.latestBuild]);

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
        ? 'Продолжите установку'
        : isReady
          ? 'Обновление готово'
          : isError
            ? 'Ошибка обновления'
            : 'Загружаем обновление';
  const text = isReady
    ? signingMigration
      ? 'Это новая сборка с другой подписью. Скачайте APK, установите его как новое приложение, войдите в аккаунт и после проверки доступа удалите старый VEX.'
      : update.currentBuildBlocked
        ? 'Установите предложенную стабильную версию, чтобы вернуться на поддерживаемую сборку.'
        : 'VEX скачает APK, проверит checksum и подпись приложения, затем откроет системный установщик.'
    : needsInstallPermission
      ? 'Если Android запросил разрешение установки, включите его для VEX и вернитесь в приложение. Если установка не открылась или была отменена, нажмите «Продолжить установку».'
      : isError
        ? 'Не удалось подготовить обновление. Проверьте подключение и попробуйте позже.'
        : signingMigration
          ? 'Откройте сайт VEX, скачайте новую сборку, установите ее и удалите старую после входа в аккаунт.'
          : 'VEX скачивает и проверяет APK. Дождитесь открытия установщика Android.';

  const primaryLabel = isReady
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
          : 'Подождите';
  const handlePrimary = canOpenManualDownload ? handleOpenManualDownload : isReady || needsInstallPermission ? handleInstall : handleRetryDownload;

  return (
    <Modal animationType="slide" onRequestClose={handleDismiss} visible>
      <Host colorScheme="dark" seedColor="#22D3EE" style={styles.host} useViewportSizeMeasurement>
        <Column spacing={14} style={styles.content}>
          <Spacer flexible />
          <UniversalText textStyle={styles.eyebrow}>VEX Android</UniversalText>
          <UniversalText textStyle={styles.title}>{title}</UniversalText>
          <UniversalText textStyle={styles.text}>{text}</UniversalText>
          {update.changelog ? <UniversalText textStyle={styles.notes}>{update.changelog}</UniversalText> : null}
          <List>
            <ListItem supportingText={`Новая: ${update.latestVersion} (${update.latestBuild})`}>
              {`Сейчас: ${Application.nativeApplicationVersion || 'dev'} (${androidBuild || 0})`}
            </ListItem>
          </List>
          {!preflight.ok ? <UniversalText textStyle={styles.error}>{preflight.error}</UniversalText> : null}
          {isError ? <UniversalText textStyle={styles.error}>{downloadState.message}</UniversalText> : null}
          <Button disabled={downloadState.status === 'installing'} label={update.required ? 'Закрыть' : 'Позже'} onPress={handleDismiss} variant="outlined" />
          <Button disabled={primaryDisabled} label={primaryLabel} onPress={handlePrimary} />
          <Spacer flexible />
        </Column>
      </Host>
    </Modal>
  );
}

export function parsePendingAndroidInstall(value: string | null): PendingAndroidInstall | null {
  if (!value) {
    return null;
  }
  try {
    const parsed = JSON.parse(value) as Partial<PendingAndroidInstall>;
    if (!Number.isInteger(parsed.build) || (parsed.build ?? 0) <= 0 || typeof parsed.resumeAttempted !== 'boolean') {
      return null;
    }
    return { build: parsed.build as number, resumeAttempted: parsed.resumeAttempted };
  } catch {
    return null;
  }
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
  if (!requiresNativeUpdate(update)) {
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
  return downloadState.status === 'ready'
    || downloadState.status === 'installing'
    || downloadState.status === 'permission_required'
    || downloadState.status === 'error';
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
  host: { flex: 1 },
  content: { backgroundColor: '#041315', flex: 1, paddingHorizontal: 24, paddingVertical: 32 },
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
  error: {
    color: '#FF9F9F',
    fontSize: 13,
    fontWeight: '800',
  },
});
