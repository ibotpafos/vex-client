import { useEffect, useState } from 'react';
import { Keyboard, Linking, Platform } from 'react-native';
import * as WebBrowser from 'expo-web-browser';
import * as ExpoLinking from 'expo-linking';
import { isTauriRuntime } from '@/native/tauriPlatform';

const appAuthCallbackPath = 'auth/callback';
const appAuthCallbackUrl = ExpoLinking.createURL(appAuthCallbackPath, { scheme: 'vexguard' });

export async function openExternalUrl(url: string): Promise<void> {
  if (isTauriRuntime()) {
    const { invoke } = await import('@tauri-apps/api/core');
    await invoke('open_external_url', { url });
    return;
  }
  await Linking.openURL(url);
}

export async function openWebAuthUrl(url: string): Promise<string | null> {
  if (Platform.OS === 'android' || Platform.OS === 'ios') {
    const result = await WebBrowser.openAuthSessionAsync(url, appAuthCallbackUrl, {
      createTask: false,
      showInRecents: true,
      toolbarColor: '#071113',
    });
    return result.type === 'success' ? result.url : null;
  }

  await openExternalUrl(url);
  return null;
}

export function supportsWebsiteAuth(): boolean {
  return Platform.OS === 'android' || isTauriRuntime();
}

export function getDeviceDetails() {
  let platform = 'web';
  let deviceName = 'VEX Web Client';
  
  if (Platform.OS === 'android') {
    platform = 'android';
    deviceName = 'Android Device';
  } else if (Platform.OS === 'ios') {
    platform = 'ios';
    deviceName = 'iOS Device';
  } else if (Platform.OS === 'web' && typeof window !== 'undefined') {
    const ua = navigator.userAgent.toLowerCase();
    if (ua.includes('win')) {
      platform = 'windows';
      deviceName = 'VEX Windows Desktop';
    } else if (ua.includes('mac') || ua.includes('darwin')) {
      platform = 'macos';
      deviceName = 'VEX macOS Desktop';
    } else if (ua.includes('linux')) {
      platform = 'linux';
      deviceName = 'VEX Linux Desktop';
    }
  }
  return { platform, deviceName };
}

export function parseQueryString(url: string) {
  const params: Record<string, string> = {};
  const queryStringIndex = url.indexOf('?');
  if (queryStringIndex === -1) return params;
  const queryString = url.substring(queryStringIndex + 1).split('#', 1)[0];
  const searchParams = new URLSearchParams(queryString);
  searchParams.forEach((value, key) => {
    params[key] = value;
  });
  return params;
}

export function isAppAuthCallbackUrl(url: string | null): url is string {
  if (!url) {
    return false;
  }
  if (url.startsWith(appAuthCallbackUrl)) {
    return true;
  }
  try {
    const parsed = new URL(url);
    return parsed.protocol === 'vexguard:' && parsed.hostname === 'auth' && parsed.pathname.startsWith('/callback');
  } catch {
    return false;
  }
}

export function useKeyboardVisible(): boolean {
  const [isKeyboardVisible, setIsKeyboardVisible] = useState(false);

  useEffect(() => {
    const showEvent = Platform.OS === 'ios' ? 'keyboardWillShow' : 'keyboardDidShow';
    const hideEvent = Platform.OS === 'ios' ? 'keyboardWillHide' : 'keyboardDidHide';
    const showSubscription = Keyboard.addListener(showEvent, () => setIsKeyboardVisible(true));
    const hideSubscription = Keyboard.addListener(hideEvent, () => setIsKeyboardVisible(false));

    return () => {
      showSubscription.remove();
      hideSubscription.remove();
    };
  }, []);

  return isKeyboardVisible;
}
