import { NativeModules, Platform } from 'react-native';
import { requireNativeModule as requireExpoNativeModule } from 'expo';

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

export type WireGuardKeyPair = {
  privateKey: string;
  publicKey: string;
  keyEpoch?: number;
};

type VexVpnNativeModule = {
  needsPermission(): Promise<boolean>;
  requestPermission(): Promise<boolean>;
  connect(wgQuickConfig: string, antiLeakEnabled: boolean): Promise<VpnStatus>;
  disconnect(releaseAntiLeak: boolean): Promise<VpnStatus>;
  status(): Promise<VpnStatus>;
  openVpnSettings?(): Promise<boolean>;
  getOrCreateWireGuardKeyPair(): Promise<WireGuardKeyPair>;
  generateWireGuardKeyPair(): Promise<WireGuardKeyPair>;
  replaceWireGuardKeyPair(privateKey: string, publicKey: string, keyEpoch: number): Promise<boolean>;
  resetWireGuardKeyPair(): Promise<boolean>;
  measureEndpointLatency(endpoint: string): Promise<number | null>;
  readDiagnostics?(): Promise<Record<string, unknown>[]>;
  requestNotificationPermission?(): Promise<boolean>;
  getFirebaseMessagingToken?(): Promise<string>;
  downloadUpdateApk(downloadUrl: string, checksumSha256?: string | null): Promise<AndroidUpdateDownload>;
  installUpdateApk(filePath: string): Promise<AndroidUpdateInstallResult>;
};

const nativeModule = NativeModules.VexVpn as VexVpnNativeModule | undefined;

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
};

export type DisconnectVpnOptions = {
  releaseAntiLeak?: boolean;
};

export async function connectVpn(wgQuickConfig: string, options: ConnectVpnOptions = {}): Promise<VpnStatus> {
  return normalizeVpnStatus(await requireNativeModule().connect(wgQuickConfig, options.antiLeakEnabled !== false));
}

export async function disconnectVpn(options: DisconnectVpnOptions = {}): Promise<VpnStatus> {
  return normalizeVpnStatus(await requireNativeModule().disconnect(options.releaseAntiLeak !== false));
}

export async function getVpnStatus(): Promise<VpnStatus> {
  return normalizeVpnStatus(await requireNativeModule().status());
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
  if (Platform.OS !== 'ios') {
    return [];
  }
  return requireNativeModule().readDiagnostics?.() ?? [];
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
