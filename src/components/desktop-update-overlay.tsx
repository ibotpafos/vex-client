import React, { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react';
import { Platform, Pressable, StyleSheet, Text, View } from 'react-native';
import { updateCheckChannel } from '@/api/updatePreflight';
import { appUpdateCheck } from '@/api/vexApi';
import { getAppInfo, getOrCreateDeviceId } from '@/native/appInfo';

type DesktopUpdateStatus = 'idle' | 'checking' | 'downloading' | 'ready' | 'error';

type DesktopUpdateState = {
  status: DesktopUpdateStatus;
  currentVersion: string;
  latestVersion: string;
  latestBuild: number;
  releaseChannel: string;
  releaseNotes: string | null;
  required: boolean;
  downloadedBytes: number;
  contentLength: number;
  error: string | null;
  checkNow(): Promise<void>;
  relaunchToUpdate(): Promise<void>;
};

type PendingDesktopUpdate = {
  version: string;
  build: number;
  channel: string;
  notes: string | null;
  required: boolean;
};

const defaultDesktopUpdateState: DesktopUpdateState = {
  status: 'idle',
  currentVersion: '0.0.0',
  latestVersion: '',
  latestBuild: 0,
  releaseChannel: 'stable',
  releaseNotes: null,
  required: false,
  downloadedBytes: 0,
  contentLength: 0,
  error: null,
  checkNow: async () => undefined,
  relaunchToUpdate: async () => undefined,
};

const DesktopUpdateContext = createContext<DesktopUpdateState>(defaultDesktopUpdateState);

function isTauriRuntime(): boolean {
  return Platform.OS === 'web' && typeof window !== 'undefined' && ('__TAURI_INTERNALS__' in window || '__TAURI__' in window || '__TAURI_INVOKE__' in window);
}

const pendingUpdateStorageKey = 'vex.desktop.pending-update.v1';

type DesktopUpdaterResult = Awaited<ReturnType<typeof import('@tauri-apps/plugin-updater')['check']>>;
type AvailableDesktopUpdate = NonNullable<DesktopUpdaterResult>;

function hasAvailableUpdate(update: DesktopUpdaterResult): update is AvailableDesktopUpdate {
  return Boolean(update && (!('available' in update) || update.available !== false));
}

function readPendingUpdate(): PendingDesktopUpdate | null {
  if (typeof window === 'undefined') {
    return null;
  }
  try {
    const raw = window.localStorage.getItem(pendingUpdateStorageKey);
    if (!raw) {
      return null;
    }
    const parsed = JSON.parse(raw) as PendingDesktopUpdate;
    return parsed.version ? parsed : null;
  } catch {
    return null;
  }
}

function writePendingUpdate(value: PendingDesktopUpdate) {
  if (typeof window === 'undefined') {
    return;
  }
  window.localStorage.setItem(pendingUpdateStorageKey, JSON.stringify(value));
}

function clearPendingUpdate() {
  if (typeof window === 'undefined') {
    return;
  }
  window.localStorage.removeItem(pendingUpdateStorageKey);
}

export function DesktopUpdateProvider({ children }: { children: React.ReactNode }) {
  if (!isTauriRuntime()) {
    return (
      <DesktopUpdateContext.Provider value={defaultDesktopUpdateState}>
        {children}
      </DesktopUpdateContext.Provider>
    );
  }

  return <DesktopUpdateProviderContent>{children}</DesktopUpdateProviderContent>;
}

function DesktopUpdateProviderContent({ children }: { children: React.ReactNode }) {
  const [status, setStatus] = useState<DesktopUpdateStatus>('idle');
  const [currentVersion, setCurrentVersion] = useState('0.0.0');
  const [latestVersion, setLatestVersion] = useState('');
  const [latestBuild, setLatestBuild] = useState(0);
  const [releaseChannel, setReleaseChannel] = useState('stable');
  const [releaseNotes, setReleaseNotes] = useState<string | null>(null);
  const [required, setRequired] = useState(false);
  const [downloadedBytes, setDownloadedBytes] = useState(0);
  const [contentLength, setContentLength] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const isRunningRef = useRef(false);
  const isReadyRef = useRef(false);

  const checkAndInstall = useCallback(async () => {
    if (!isTauriRuntime() || isRunningRef.current || isReadyRef.current) {
      return;
    }

    isRunningRef.current = true;
    setStatus('checking');
    setError(null);

    try {
      const [{ getVersion }, { check }] = await Promise.all([
        import('@tauri-apps/api/app'),
        import('@tauri-apps/plugin-updater'),
      ]);
      const [appInfo, deviceId, installedVersion] = await Promise.all([
        getAppInfo(),
        getOrCreateDeviceId(),
        getVersion(),
      ]);
      setCurrentVersion(installedVersion);
      setReleaseChannel(updateCheckChannel(appInfo.channel));
      const metadata = await appUpdateCheck({
        platform: appInfo.platform,
        appVersion: appInfo.version,
        buildNumber: Number.parseInt(appInfo.build || '0', 10) || 0,
        channel: updateCheckChannel(appInfo.channel),
        coreVersion: appInfo.coreVersion,
        deviceId,
        osVersion: typeof navigator !== 'undefined' ? navigator.userAgent : '',
        arch: typeof navigator !== 'undefined' ? navigator.platform : '',
        apiClientVersion: appInfo.apiClientVersion,
        configSchemaVersion: appInfo.configSchemaVersion,
      });

      setLatestVersion(metadata.latestVersion || '');
      setLatestBuild(metadata.latestBuild || 0);
      setReleaseChannel(metadata.channel || updateCheckChannel(appInfo.channel));
      setReleaseNotes(metadata.changelog || null);
      setRequired(Boolean(metadata.required));

      const update = await check();
      const pendingUpdate = readPendingUpdate();
      if (pendingUpdate?.version === installedVersion) {
        clearPendingUpdate();
      } else if (pendingUpdate?.version && hasAvailableUpdate(update) && pendingUpdate.version === update.version) {
        setLatestVersion(pendingUpdate.version);
        setLatestBuild(pendingUpdate.build || metadata.latestBuild || 0);
        setReleaseChannel(pendingUpdate.channel || metadata.channel || updateCheckChannel(appInfo.channel));
        setReleaseNotes(pendingUpdate.notes || metadata.changelog || null);
        setRequired(Boolean(pendingUpdate.required || metadata.required));
        isReadyRef.current = true;
        setStatus('ready');
        return;
      } else if (pendingUpdate?.version) {
        clearPendingUpdate();
      }

      if (!hasAvailableUpdate(update)) {
        setStatus('idle');
        return;
      }

      setLatestVersion(update.version);
      setDownloadedBytes(0);
      setContentLength(0);
      setStatus('downloading');

      let downloaded = 0;
      let total = 0;
      await update.downloadAndInstall((event) => {
        if (event.event === 'Started') {
          downloaded = 0;
          total = event.data.contentLength ?? 0;
          setDownloadedBytes(0);
          setContentLength(total);
          return;
        }
        if (event.event === 'Progress') {
          downloaded += event.data.chunkLength;
          setDownloadedBytes(downloaded);
          return;
        }
        if (event.event === 'Finished' && total > 0) {
          setDownloadedBytes(total);
        }
      });

      isReadyRef.current = true;
      writePendingUpdate({
        version: update.version,
        build: metadata.latestBuild || 0,
        channel: metadata.channel || updateCheckChannel(appInfo.channel),
        notes: metadata.changelog || null,
        required: Boolean(metadata.required),
      });
      setStatus('ready');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Не удалось обновить приложение.');
      setStatus('error');
    } finally {
      isRunningRef.current = false;
    }
  }, []);

  useEffect(() => {
    if (!isTauriRuntime()) {
      return undefined;
    }

    void checkAndInstall();
    const timer = window.setInterval(() => {
      void checkAndInstall();
    }, 5 * 60 * 1000);
    const checkWhenVisible = () => {
      if (document.visibilityState === 'visible') {
        void checkAndInstall();
      }
    };
    window.addEventListener('focus', checkWhenVisible);
    document.addEventListener('visibilitychange', checkWhenVisible);

    return () => {
      window.clearInterval(timer);
      window.removeEventListener('focus', checkWhenVisible);
      document.removeEventListener('visibilitychange', checkWhenVisible);
    };
  }, [checkAndInstall]);

  const relaunchToUpdate = useCallback(async () => {
    if (!isTauriRuntime() || status !== 'ready') {
      return;
    }
    try {
      const { relaunch } = await import('@tauri-apps/plugin-process');
      await relaunch();
      return;
    } catch {
      const { invoke } = await import('@tauri-apps/api/core');
      await invoke('restart_app');
    }
  }, [status]);

  const value = useMemo<DesktopUpdateState>(() => ({
    status,
    currentVersion,
    latestVersion,
    latestBuild,
    releaseChannel,
    releaseNotes,
    required,
    downloadedBytes,
    contentLength,
    error,
    checkNow: checkAndInstall,
    relaunchToUpdate,
  }), [checkAndInstall, contentLength, currentVersion, downloadedBytes, error, latestBuild, latestVersion, releaseChannel, releaseNotes, relaunchToUpdate, required, status]);

  return (
    <DesktopUpdateContext.Provider value={value}>
      {children}
    </DesktopUpdateContext.Provider>
  );
}

export function useDesktopUpdate() {
  return useContext(DesktopUpdateContext);
}

export function DesktopUpdateOverlay() {
  if (!isTauriRuntime()) {
    return null;
  }

  return <DesktopUpdateOverlayContent />;
}

function DesktopUpdateOverlayContent() {
  const update = useDesktopUpdate();
  const [dismissedVersion, setDismissedVersion] = useState<string | null>(null);

  useEffect(() => {
    if (update.status === 'ready') {
      setDismissedVersion(null);
    }
  }, [update.latestVersion, update.status]);

  if (!isTauriRuntime() || update.status !== 'ready' || !update.latestVersion || dismissedVersion === update.latestVersion) {
    return null;
  }

  return (
    <View style={styles.overlay}>
      <View style={styles.panel}>
        <Text style={styles.title}>Обновление готово</Text>
        <Text style={styles.text}>{`Версия ${update.latestVersion} уже загружена. Перезапустите VEX, чтобы установить обновление.`}</Text>
        <View style={styles.versionBox}>
          <Text style={styles.versionText}>{`Сейчас: ${update.currentVersion}`}</Text>
          <Text style={styles.versionText}>{`Будет: ${update.latestVersion}${update.latestBuild ? ` (${update.latestBuild})` : ''}`}</Text>
        </View>
        <Pressable onPress={() => { void update.relaunchToUpdate(); }} style={styles.primaryButton}>
          <Text style={styles.primaryButtonText}>Перезапустить сейчас</Text>
        </Pressable>
        <Pressable onPress={() => setDismissedVersion(update.latestVersion)} style={styles.secondaryButton}>
          <Text style={styles.secondaryButtonText}>Позже</Text>
        </Pressable>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  overlay: {
    alignItems: 'center',
    backgroundColor: 'rgba(2,10,11,0.78)',
    bottom: 0,
    justifyContent: 'center',
    left: 0,
    paddingHorizontal: 16,
    position: 'absolute',
    right: 0,
    top: 0,
  },
  panel: {
    backgroundColor: '#071113',
    borderColor: 'rgba(34,211,238,0.32)',
    borderRadius: 28,
    borderWidth: 1,
    gap: 12,
    maxWidth: 430,
    padding: 20,
    width: '100%',
  },
  title: {
    color: '#F4FCFD',
    fontSize: 24,
    fontWeight: '900',
    textAlign: 'center',
  },
  text: {
    color: '#C6D6D9',
    fontSize: 15,
    fontWeight: '600',
    lineHeight: 21,
    textAlign: 'center',
  },
  versionBox: {
    backgroundColor: 'rgba(2,10,11,0.72)',
    borderRadius: 16,
    gap: 5,
    padding: 12,
  },
  versionText: {
    color: '#A7B9BD',
    fontSize: 13,
    fontWeight: '700',
  },
  primaryButton: {
    alignItems: 'center',
    backgroundColor: '#22D3EE',
    borderRadius: 18,
    justifyContent: 'center',
    minHeight: 54,
    marginTop: 4,
  },
  primaryButtonText: {
    color: '#031012',
    fontSize: 17,
    fontWeight: '900',
  },
  secondaryButton: {
    alignItems: 'center',
    justifyContent: 'center',
    minHeight: 44,
  },
  secondaryButtonText: {
    color: '#A7B9BD',
    fontSize: 15,
    fontWeight: '800',
  },
});
