import * as SecureStore from '@/native/secureStore';
import type { StagedDevicePSKProfile } from './devicePskRotation';

const stagedDevicePSKProfileKey = 'vex.vpn.psk-rotation.staged.v1';

export async function loadStagedDevicePSKProfile(): Promise<StagedDevicePSKProfile | null> {
  const raw = await SecureStore.getItemAsync(stagedDevicePSKProfileKey).catch(() => null);
  if (!raw) return null;
  try {
    const value = JSON.parse(raw) as StagedDevicePSKProfile;
    return value?.rotationId && value.deviceId && value.profileDigest && value.profile?.config ? value : null;
  } catch {
    return null;
  }
}

export async function saveStagedDevicePSKProfile(value: StagedDevicePSKProfile): Promise<void> {
  await SecureStore.setItemAsync(stagedDevicePSKProfileKey, JSON.stringify(value));
}

export async function clearStagedDevicePSKProfile(): Promise<void> {
  await SecureStore.deleteItemAsync(stagedDevicePSKProfileKey);
}
