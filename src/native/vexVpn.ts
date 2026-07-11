import { NativeEventEmitter, NativeModules, Platform, type NativeModule } from 'react-native';
import { requireNativeModule as requireExpoNativeModule } from 'expo';
import { disconnectWithRecoveryTimeout } from '@/vpn/disconnectRecovery';

export type VpnState = 'connected' | 'connecting' | 'disconnecting' | 'disconnected' | 'error' | 'verifying' | 'degraded';
export type LeakProtectionState = 'off' | 'armed' | 'blocking';
export type VpnVerificationReason = 'handshake_pending' | 'handshake_stale' | 'device_usage_degraded' | 'endpoint_failed';

export type VpnStatus = {
  state: VpnState;
  rxBytes: number;
  txBytes: number;
  latestHandshakeEpochMillis?: number;
  leakProtection?: LeakProtectionState;
  verified?: boolean;
  verificationReason?: VpnVerificationReason;
};

export type AndroidUpdateDownload = {
  filePath: string;
  sizeBytes: number;
  checksumSha256?: string;
};

export type AndroidUpdateInstallResult = {
  status: 'installer_started' | 'install_permission_required';
};

export type InstalledVpnApplication = {
  iconDataUri: string;
  label: string;
  packageName: string;
};

export type VpnLiveActivityPayload = {
  state: VpnState;
  phase: string;
  locationName: string;
  latencyText: string;
  receivedText: string;
  sentText: string;
  updatedAtEpochSeconds: number;
};

export type WireGuardKeyPair = {
  privateKey: string;
  publicKey: string;
  keyEpoch?: number;
};

type VexVpnNativeModule = {
  addListener?(eventName: string): void;
  removeListeners?(count: number): void;
  needsPermission(): Promise<boolean>;
  requestPermission(): Promise<boolean>;
  connect(wgQuickConfig: string, antiLeakEnabled: boolean): Promise<VpnStatus>;
  connectWithApplications?(
    wgQuickConfig: string,
    antiLeakEnabled: boolean,
    selectedApplications: string[],
    routeOnlySelectedApplications: boolean,
  ): Promise<VpnStatus>;
  disconnect(releaseAntiLeak: boolean): Promise<VpnStatus>;
  status(): Promise<VpnStatus>;
  openVpnSettings?(): Promise<boolean>;
  getOrCreateWireGuardKeyPair(): Promise<WireGuardKeyPair>;
  generateWireGuardKeyPair(): Promise<WireGuardKeyPair>;
  replaceWireGuardKeyPair(privateKey: string, publicKey: string, keyEpoch: number): Promise<boolean>;
  resetWireGuardKeyPair(): Promise<boolean>;
  measureEndpointLatency(endpoint: string): Promise<number | null>;
  readDiagnostics?(): Promise<Record<string, unknown>[]>;
  updateLiveActivity?(payload: VpnLiveActivityPayload): Promise<boolean>;
  endLiveActivity?(): Promise<boolean>;
  requestNotificationPermission?(): Promise<boolean>;
  getFirebaseMessagingToken?(): Promise<string>;
  downloadUpdateApk(downloadUrl: string, checksumSha256?: string | null): Promise<AndroidUpdateDownload>;
  installUpdateApk(filePath: string): Promise<AndroidUpdateInstallResult>;
  getInstalledApplications?(): Promise<InstalledVpnApplication[]>;
};

const nativeModule = NativeModules.VexVpn as VexVpnNativeModule | undefined;
const androidStatusCacheTtlMs = 1_200;
const vpnStatusChangedEvent = 'vpn-status-changed';

let cachedVpnStatus: { status: VpnStatus; cachedAt: number } | null = null;
let inflightVpnStatusPromise: Promise<VpnStatus> | null = null;
let nativeVpnEventEmitter: NativeEventEmitter | null = null;

function requireNativeModule(): VexVpnNativeModule {
  if (Platform.OS === 'ios') {
    try {
      return nativeModule ?? requireExpoNativeModule<VexVpnNativeModule>('VexVpn');
    } catch {
      throw new Error('VexVpn iOS native module is not linked. Rebuild the Expo iOS dev build.');
    }
  }
  if (Platform.OS !== 'android') {
    throw new Error('VexVpn is only available on Android and iOS.');
  }
  if (!nativeModule) {
    throw new Error('VexVpn native module is not linked. Rebuild the Expo dev build.');
  }
  return nativeModule;
}

export async function needsVpnPermission(): Promise<boolean> {
  return requireNativeModule().needsPermission();
}

export async function requestVpnPermission(): Promise<boolean> {
  return requireNativeModule().requestPermission();
}

export type ConnectVpnOptions = {
  antiLeakEnabled?: boolean;
  applicationRoutingMode?: 'all' | 'selected';
  selectedApplications?: string[];
};

export type DisconnectVpnOptions = {
  releaseAntiLeak?: boolean;
};

export async function connectVpn(wgQuickConfig: string, options: ConnectVpnOptions = {}): Promise<VpnStatus> {
  const module = requireNativeModule();
  const nativeStatus = Platform.OS === 'android' && module.connectWithApplications
    ? await module.connectWithApplications(
      wgQuickConfig,
      options.antiLeakEnabled !== false,
      options.selectedApplications ?? [],
      options.applicationRoutingMode === 'selected',
    )
    : await module.connect(wgQuickConfig, options.antiLeakEnabled !== false);
  const status = normalizeVpnStatus(nativeStatus);
  updateCachedVpnStatus(status);
  return status;
}

export async function getInstalledVpnApplications(): Promise<InstalledVpnApplication[]> {
  if (Platform.OS !== 'android') {
    return [];
  }
  const applications = await requireNativeModule().getInstalledApplications?.();
  return Array.isArray(applications)
    ? applications.filter(isInstalledVpnApplication)
    : [];
}

function isInstalledVpnApplication(value: unknown): value is InstalledVpnApplication {
  if (!value || typeof value !== 'object') {
    return false;
  }
  const application = value as Partial<InstalledVpnApplication>;
  return typeof application.label === 'string' &&
    typeof application.packageName === 'string' &&
    typeof application.iconDataUri === 'string';
}

export async function disconnectVpn(options: DisconnectVpnOptions = {}): Promise<VpnStatus> {
  const module = requireNativeModule();
  const releaseAntiLeak = options.releaseAntiLeak !== false;
  const operation = module.disconnect(releaseAntiLeak);
  const nativeStatus = Platform.OS === 'android'
    ? await disconnectWithRecoveryTimeout(
      operation,
      () => module.openVpnSettings?.() ?? Promise.resolve(false),
    )
    : await operation;
  const status = normalizeVpnStatus(nativeStatus);
  updateCachedVpnStatus(status);
  return status;
}

export async function getVpnStatus(): Promise<VpnStatus> {
  if (Platform.OS === 'android') {
    const now = Date.now();
    if (cachedVpnStatus && now - cachedVpnStatus.cachedAt <= androidStatusCacheTtlMs) {
      return cachedVpnStatus.status;
    }
    if (inflightVpnStatusPromise) {
      return inflightVpnStatusPromise;
    }
  }

  const request = requireNativeModule()
    .status()
    .then((status) => {
      const normalizedStatus = normalizeVpnStatus(status);
      updateCachedVpnStatus(normalizedStatus);
      return normalizedStatus;
    })
    .finally(() => {
      inflightVpnStatusPromise = null;
    });

  if (Platform.OS === 'android') {
    inflightVpnStatusPromise = request;
  }

  return request;
}

export function listenVpnStatusChanged(listener: (status: VpnStatus) => void): (() => void) | null {
  if (Platform.OS !== 'android') {
    return null;
  }

  const emitter = getNativeVpnEventEmitter();
  if (!emitter) {
    return null;
  }

  const subscription = emitter.addListener(vpnStatusChangedEvent, (status: VpnStatus) => {
    const normalizedStatus = normalizeVpnStatus(status);
    updateCachedVpnStatus(normalizedStatus);
    listener(normalizedStatus);
  });

  return () => {
    subscription.remove();
  };
}

export async function openVpnSettings(): Promise<boolean> {
  if (Platform.OS !== 'android') {
    return false;
  }
  return requireNativeModule().openVpnSettings?.() ?? false;
}

export async function getOrCreateWireGuardKeyPair(): Promise<WireGuardKeyPair | null> {
  if (Platform.OS !== 'android' && Platform.OS !== 'ios') {
    return null;
  }
  return requireNativeModule().getOrCreateWireGuardKeyPair();
}

export async function generateWireGuardKeyPair(): Promise<WireGuardKeyPair | null> {
  if (Platform.OS !== 'android' && Platform.OS !== 'ios') {
    return null;
  }
  return requireNativeModule().generateWireGuardKeyPair();
}

export async function replaceWireGuardKeyPair(keyPair: WireGuardKeyPair): Promise<boolean> {
  if (Platform.OS !== 'android' && Platform.OS !== 'ios') {
    return false;
  }
  return requireNativeModule().replaceWireGuardKeyPair(keyPair.privateKey, keyPair.publicKey, keyPair.keyEpoch ?? 1);
}

export async function resetWireGuardKeyPair(): Promise<boolean> {
  if (Platform.OS !== 'android' && Platform.OS !== 'ios') {
    return false;
  }
  return requireNativeModule().resetWireGuardKeyPair();
}

export async function measureEndpointLatency(endpoint: string): Promise<number | null> {
  const value = endpoint.trim();
  if (!value) {
    return null;
  }
  return requireNativeModule().measureEndpointLatency(value);
}

export async function readNativeVpnDiagnostics(): Promise<Record<string, unknown>[]> {
  if (Platform.OS !== 'ios' && Platform.OS !== 'android') {
    return [];
  }
  return requireNativeModule().readDiagnostics?.() ?? [];
}

export async function updateVpnLiveActivity(payload: VpnLiveActivityPayload): Promise<boolean> {
  if (Platform.OS !== 'ios') {
    return false;
  }
  return requireNativeModule().updateLiveActivity?.(payload) ?? false;
}

export async function endVpnLiveActivity(): Promise<boolean> {
  if (Platform.OS !== 'ios') {
    return false;
  }
  return requireNativeModule().endLiveActivity?.() ?? false;
}

export async function requestNotificationPermission(): Promise<boolean> {
  if (Platform.OS !== 'android') {
    return false;
  }
  return requireNativeModule().requestNotificationPermission?.() ?? false;
}

export async function getFirebaseMessagingToken(): Promise<string> {
  if (Platform.OS !== 'android') {
    return '';
  }
  return requireNativeModule().getFirebaseMessagingToken?.() ?? '';
}

export async function downloadAndroidUpdateApk(downloadUrl: string, checksumSha256?: string | null): Promise<AndroidUpdateDownload> {
  return requireNativeModule().downloadUpdateApk(downloadUrl, checksumSha256 ?? null);
}

export async function installAndroidUpdateApk(filePath: string): Promise<AndroidUpdateInstallResult> {
  return requireNativeModule().installUpdateApk(filePath);
}

export async function getStartupEnabled(): Promise<boolean> {
  return false;
}

export async function setStartupEnabled(enabled: boolean): Promise<boolean> {
  void enabled;
  return false;
}

function normalizeVpnStatus(status: VpnStatus): VpnStatus {
  const latestHandshakeEpochMillis = typeof status.latestHandshakeEpochMillis === 'number'
    ? status.latestHandshakeEpochMillis
    : undefined;
  const hasTunnelActivity = Boolean(
    (latestHandshakeEpochMillis && latestHandshakeEpochMillis > 0) ||
    status.rxBytes > 0 ||
    status.txBytes > 0,
  );
  const verified = status.state === 'connected'
    ? (hasTunnelActivity ? true : status.verified ?? false)
    : status.verified;
  return {
    ...status,
    latestHandshakeEpochMillis,
    leakProtection: status.leakProtection ?? 'off',
    verified,
    verificationReason: status.verificationReason ?? (status.state === 'connected' && verified === false ? 'handshake_pending' : undefined),
  };
}

function updateCachedVpnStatus(status: VpnStatus): void {
  cachedVpnStatus = {
    status,
    cachedAt: Date.now(),
  };
}

function getNativeVpnEventEmitter(): NativeEventEmitter | null {
  if (Platform.OS !== 'android') {
    return null;
  }
  if (!nativeVpnEventEmitter) {
    nativeVpnEventEmitter = new NativeEventEmitter(requireNativeModule() as NativeModule);
  }
  return nativeVpnEventEmitter;
}
