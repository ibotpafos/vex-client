import * as LocalAuthentication from 'expo-local-authentication';
import { Platform } from 'react-native';
import { isTauriRuntime } from './tauriPlatform';

export type BiometricAuthAvailability = {
  isAvailable: boolean;
  label: string;
};

const unavailableBiometrics: BiometricAuthAvailability = {
  isAvailable: false,
  label: 'биометрии',
};

export async function getBiometricAuthAvailability(): Promise<BiometricAuthAvailability> {
  if (isTauriRuntime()) {
    return getDesktopBiometricAuthAvailability();
  }

  if (!isNativeMobilePlatform()) {
    return unavailableBiometrics;
  }

  try {
    const [hasHardware, isEnrolled, supportedTypes] = await Promise.all([
      LocalAuthentication.hasHardwareAsync(),
      LocalAuthentication.isEnrolledAsync(),
      LocalAuthentication.supportedAuthenticationTypesAsync(),
    ]);

    return {
      isAvailable: hasHardware && isEnrolled && supportedTypes.length > 0,
      label: biometricAuthLabel(supportedTypes),
    };
  } catch {
    return unavailableBiometrics;
  }
}

export async function authenticateWithBiometrics(): Promise<boolean> {
  if (isTauriRuntime()) {
    return authenticateWithDesktopBiometrics();
  }

  const availability = await getBiometricAuthAvailability();
  if (!availability.isAvailable) {
    return false;
  }

  const result = await LocalAuthentication.authenticateAsync({
    biometricsSecurityLevel: 'strong',
    cancelLabel: 'Отмена',
    disableDeviceFallback: false,
    fallbackLabel: 'Код-пароль',
    promptDescription: 'Подтвердите личность, чтобы открыть сохраненную сессию.',
    promptMessage: 'Вход в VEX',
    promptSubtitle: 'Биометрическая проверка',
    requireConfirmation: true,
  });

  return result.success;
}

function isNativeMobilePlatform(): boolean {
  return Platform.OS === 'ios' || Platform.OS === 'android';
}


async function getDesktopBiometricAuthAvailability(): Promise<BiometricAuthAvailability> {
  try {
    const { invoke } = await import('@tauri-apps/api/core');
    return await invoke<BiometricAuthAvailability>('get_desktop_biometric_auth_availability');
  } catch {
    return unavailableBiometrics;
  }
}

async function authenticateWithDesktopBiometrics(): Promise<boolean> {
  try {
    const { invoke } = await import('@tauri-apps/api/core');
    return await invoke<boolean>('authenticate_with_desktop_biometrics');
  } catch {
    return false;
  }
}

function biometricAuthLabel(supportedTypes: LocalAuthentication.AuthenticationType[]): string {
  if (supportedTypes.includes(LocalAuthentication.AuthenticationType.FACIAL_RECOGNITION)) {
    return Platform.OS === 'ios' ? 'Face ID' : 'распознаванию лица';
  }

  if (supportedTypes.includes(LocalAuthentication.AuthenticationType.FINGERPRINT)) {
    return Platform.OS === 'ios' ? 'Touch ID' : 'отпечатку пальца';
  }

  return 'биометрии';
}
