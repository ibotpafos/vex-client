import { NativeModules, Platform } from 'react-native';
import { exchangeGoogleIDToken } from '@/api/auth';
import { exchangeNativeGoogleCredential } from '@/auth/googleSignIn';
export { isGoogleSignInCancelled } from '@/auth/googleSignIn';

type GoogleAuthModule = {
  signIn(): Promise<string>;
  clearCredentialState(): Promise<void>;
};

function nativeModule(): GoogleAuthModule | undefined {
  return NativeModules.VexGoogleAuth as GoogleAuthModule | undefined;
}

export async function signInWithGoogleAndroid() {
  const module = nativeModule();
  if (Platform.OS !== 'android' || !module?.signIn) {
    throw new Error('Обновите VEX для входа через Google.');
  }
  return exchangeNativeGoogleCredential(() => module.signIn(), exchangeGoogleIDToken);
}

export async function clearGoogleCredentialState(): Promise<void> {
  if (Platform.OS === 'android') await nativeModule()?.clearCredentialState();
}
