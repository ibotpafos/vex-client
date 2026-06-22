import { useQueryClient } from '@tanstack/react-query';
import * as ExpoLinking from 'expo-linking';
import * as WebBrowser from 'expo-web-browser';
import { router } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { ActivityIndicator, Image, Keyboard, KeyboardAvoidingView, Linking, Platform, Pressable, ScrollView, StyleSheet, Text, TextInput, View } from 'react-native';
import React, { useCallback, useState, useEffect, useRef } from 'react';
import { login, exchangeAppAuthCode, vexApiBaseUrl } from '@/api/vexApi';
import { useSession } from '@/auth/session-context';
import { loadSession } from '@/auth/sessionStore';
import { loadSessionWithRetry, loadWithRetry } from '@/auth/sessionLoadRetry';
import { authenticateWithBiometrics, getBiometricAuthAvailability } from '@/native/biometricAuth';
import { playErrorHaptic, playLightImpactHaptic, playSelectionHaptic, playSuccessHaptic, playWarningHaptic } from '@/native/haptics';
import { vexColors, VexScreen, vexSharedStyles } from '@/ui/vex-ui';
import { resetVpnProfileCache } from '@/vpn/profile';
import * as SecureStore from '@/native/secureStore';

const vexLogo = require('../../assets/vex-logo-header.png');
const appAuthCallbackPath = 'auth/callback';
const appAuthCallbackUrl = ExpoLinking.createURL(appAuthCallbackPath, { scheme: 'vexguard' });

WebBrowser.maybeCompleteAuthSession();

function isTauriRuntime(): boolean {
  return Platform.OS === 'web' && typeof window !== 'undefined' && ('__TAURI_INTERNALS__' in window || '__TAURI__' in window || '__TAURI_INVOKE__' in window);
}

function generateRandomString(length: number): string {
  const possible = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
  let text = '';
  if (typeof window !== 'undefined' && window.crypto && window.crypto.getRandomValues) {
    const values = new Uint8Array(length);
    window.crypto.getRandomValues(values);
    for (let i = 0; i < length; i++) {
      text += possible.charAt(values[i] % possible.length);
    }
  } else {
    for (let i = 0; i < length; i++) {
      text += possible.charAt(Math.floor(Math.random() * possible.length));
    }
  }
  return text;
}

async function sha256(plain: string): Promise<ArrayBuffer> {
  const data = encodeUtf8(plain);
  const subtle = typeof window !== 'undefined'
    ? window.crypto?.subtle
    : (globalThis as typeof globalThis & { crypto?: Crypto }).crypto?.subtle;
  if (subtle) {
    return await subtle.digest('SHA-256', data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) as ArrayBuffer);
  }
  return sha256Fallback(data);
}

function base64urlencode(a: ArrayBuffer): string {
  return bytesToBase64(new Uint8Array(a))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
}

function encodeUtf8(value: string): Uint8Array {
  if (typeof TextEncoder !== 'undefined') {
    return new TextEncoder().encode(value);
  }

  const encoded = unescape(encodeURIComponent(value));
  const bytes = new Uint8Array(encoded.length);
  for (let i = 0; i < encoded.length; i++) {
    bytes[i] = encoded.charCodeAt(i);
  }
  return bytes;
}

function bytesToBase64(bytes: Uint8Array): string {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  let output = '';
  for (let i = 0; i < bytes.length; i += 3) {
    const byte1 = bytes[i];
    const byte2 = i + 1 < bytes.length ? bytes[i + 1] : 0;
    const byte3 = i + 2 < bytes.length ? bytes[i + 2] : 0;
    const value = (byte1 << 16) | (byte2 << 8) | byte3;
    output += alphabet[(value >> 18) & 63];
    output += alphabet[(value >> 12) & 63];
    output += i + 1 < bytes.length ? alphabet[(value >> 6) & 63] : '=';
    output += i + 2 < bytes.length ? alphabet[value & 63] : '=';
  }
  return output;
}

function sha256Fallback(data: Uint8Array): ArrayBuffer {
  const words: number[] = [];
  const bitLength = data.length * 8;
  for (let i = 0; i < data.length; i++) {
    words[i >> 2] = (words[i >> 2] || 0) | (data[i] << (24 - (i % 4) * 8));
  }
  words[bitLength >> 5] = (words[bitLength >> 5] || 0) | (0x80 << (24 - (bitLength % 32)));
  words[(((bitLength + 64) >> 9) << 4) + 15] = bitLength;

  let h0 = 0x6a09e667;
  let h1 = 0xbb67ae85;
  let h2 = 0x3c6ef372;
  let h3 = 0xa54ff53a;
  let h4 = 0x510e527f;
  let h5 = 0x9b05688c;
  let h6 = 0x1f83d9ab;
  let h7 = 0x5be0cd19;

  for (let i = 0; i < words.length; i += 16) {
    const w = new Array<number>(64);
    for (let j = 0; j < 16; j++) {
      w[j] = words[i + j] || 0;
    }
    for (let j = 16; j < 64; j++) {
      const s0 = rightRotate(w[j - 15], 7) ^ rightRotate(w[j - 15], 18) ^ (w[j - 15] >>> 3);
      const s1 = rightRotate(w[j - 2], 17) ^ rightRotate(w[j - 2], 19) ^ (w[j - 2] >>> 10);
      w[j] = add32(w[j - 16], s0, w[j - 7], s1);
    }

    let a = h0;
    let b = h1;
    let c = h2;
    let d = h3;
    let e = h4;
    let f = h5;
    let g = h6;
    let h = h7;

    for (let j = 0; j < 64; j++) {
      const s1 = rightRotate(e, 6) ^ rightRotate(e, 11) ^ rightRotate(e, 25);
      const ch = (e & f) ^ (~e & g);
      const temp1 = add32(h, s1, ch, sha256RoundConstants[j], w[j]);
      const s0 = rightRotate(a, 2) ^ rightRotate(a, 13) ^ rightRotate(a, 22);
      const maj = (a & b) ^ (a & c) ^ (b & c);
      const temp2 = add32(s0, maj);
      h = g;
      g = f;
      f = e;
      e = add32(d, temp1);
      d = c;
      c = b;
      b = a;
      a = add32(temp1, temp2);
    }

    h0 = add32(h0, a);
    h1 = add32(h1, b);
    h2 = add32(h2, c);
    h3 = add32(h3, d);
    h4 = add32(h4, e);
    h5 = add32(h5, f);
    h6 = add32(h6, g);
    h7 = add32(h7, h);
  }

  return wordsToArrayBuffer([h0, h1, h2, h3, h4, h5, h6, h7]);
}

const sha256RoundConstants = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

function rightRotate(value: number, bits: number): number {
  return (value >>> bits) | (value << (32 - bits));
}

function add32(...values: number[]): number {
  return values.reduce((sum, value) => (sum + value) >>> 0, 0);
}

function wordsToArrayBuffer(words: number[]): ArrayBuffer {
  const bytes = new Uint8Array(words.length * 4);
  words.forEach((word, index) => {
    bytes[index * 4] = (word >>> 24) & 255;
    bytes[index * 4 + 1] = (word >>> 16) & 255;
    bytes[index * 4 + 2] = (word >>> 8) & 255;
    bytes[index * 4 + 3] = word & 255;
  });
  return bytes.buffer;
}

async function generateChallenge(verifier: string): Promise<string> {
  const hashed = await sha256(verifier);
  return base64urlencode(hashed);
}

async function getOrCreateDeviceId(): Promise<string> {
  const key = 'vex.auth.device_id';
  let deviceId = await SecureStore.getItemAsync(key).catch(() => null);
  if (!deviceId) {
    deviceId = generateRandomString(16);
    await SecureStore.setItemAsync(key, deviceId).catch(() => undefined);
  }
  return deviceId;
}

async function openExternalUrl(url: string): Promise<void> {
  if (isTauriRuntime()) {
    const { invoke } = await import('@tauri-apps/api/core');
    await invoke('open_external_url', { url });
    return;
  }
  await Linking.openURL(url);
}

async function openWebAuthUrl(url: string): Promise<string | null> {
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

function supportsWebsiteAuth(): boolean {
  return Platform.OS === 'android' || isTauriRuntime();
}

function getDeviceDetails() {
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

function parseQueryString(url: string) {
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

function isAppAuthCallbackUrl(url: string | null): url is string {
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

function useKeyboardVisible(): boolean {
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

export default function SignInScreen() {
  const queryClient = useQueryClient();
  const { loadError, signIn } = useSession();
  const isKeyboardVisible = useKeyboardVisible();
  const [authMode, setAuthMode] = useState<'login' | 'register'>('login');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [authError, setAuthError] = useState<string | null>(null);
  const [isAuthBusy, setIsAuthBusy] = useState(false);
  const [biometricAuthLabel, setBiometricAuthLabel] = useState('');
  const handledCallbackUrls = useRef(new Set<string>());
  const retryableCallbackUrls = useRef<Record<string, number>>({});
  const canUseBiometricAuth = authMode === 'login' && Boolean(biometricAuthLabel);

  useEffect(() => {
    if (loadError && !authError) {
      setAuthError(loadError);
    }
  }, [authError, loadError]);

  const handleCallbackUrl = useCallback(async (url: string) => {
    if (!url) return;
    if (handledCallbackUrls.current.has(url)) return;
    handledCallbackUrls.current.add(url);
    
    console.log('Received callback URL:', url);
    playLightImpactHaptic();
    setIsAuthBusy(true);
    setAuthError(null);

    try {
      const params = parseQueryString(url);
      const code = params['code'];
      const state = params['state'];

      if (!code || !state) {
        throw new Error('Неверные параметры авторизации от сервера.');
      }

      const savedState = await loadWithRetry(() => SecureStore.getItemAsync('vex.auth.pkce.state'));
      if (!savedState || state !== savedState) {
        throw new Error('Несовпадение параметров безопасности (state mismatch).');
      }

      const verifier = await loadWithRetry(() => SecureStore.getItemAsync('vex.auth.pkce.verifier'));
      if (!verifier) {
        throw new Error('Отсутствует сессия PKCE verifier.');
      }

      const sessionData = await exchangeAppAuthCode(code, verifier);
      
      resetVpnProfileCache();
      await signIn(sessionData);
      
      await SecureStore.deleteItemAsync('vex.auth.pkce.state');
      await SecureStore.deleteItemAsync('vex.auth.pkce.verifier');

      await queryClient.invalidateQueries({ queryKey: ['entitlement'] });
      await queryClient.invalidateQueries({ queryKey: ['vpn-profile'] });
      playSuccessHaptic();
      router.replace('/');
    } catch (err) {
      console.error('Failed to handle callback URL:', err);
      playErrorHaptic();
      setAuthError(err instanceof Error ? err.message : 'Не удалось завершить вход.');
      const now = Date.now();
      if (now - (retryableCallbackUrls.current[url] ?? 0) > 5_000) {
        retryableCallbackUrls.current[url] = now;
        handledCallbackUrls.current.delete(url);
      }
    } finally {
      setIsAuthBusy(false);
    }
  }, [queryClient, signIn]);

  const handleCallbackUrls = useCallback((urls: string[] | null | undefined) => {
    const callbackUrl = urls?.find(isAppAuthCallbackUrl);
    if (callbackUrl) {
      handleCallbackUrl(callbackUrl);
    }
  }, [handleCallbackUrl]);

  useEffect(() => {
    let disposed = false;
    let unlisten: (() => void) | null = null;

    async function initDeepLink() {
      if (disposed) {
        return;
      }
      if (Platform.OS === 'android' || Platform.OS === 'ios') {
        const initialUrl = await Linking.getInitialURL();
        if (disposed) {
          return;
        }
        handleCallbackUrls(initialUrl ? [initialUrl] : []);
        const subscription = Linking.addEventListener('url', ({ url }) => {
          handleCallbackUrls([url]);
        });
        unlisten = () => subscription.remove();
        return;
      }

      if (!isTauriRuntime()) return;

      try {
        const [{ onOpenUrl, getCurrent }, { invoke }] = await Promise.all([
          import('@tauri-apps/plugin-deep-link'),
          import('@tauri-apps/api/core'),
        ]);

        const readPendingUrls = async () => {
          if (disposed) {
            return;
          }
          const [currentUrls, pendingUrls] = await Promise.all([
            getCurrent().catch(() => [] as string[]),
            invoke<string[]>('take_pending_deep_links').catch(() => []),
          ]);
          if (disposed) {
            return;
          }
          handleCallbackUrls([...(currentUrls || []), ...pendingUrls]);
        };

        await readPendingUrls();
        if (disposed) {
          return;
        }

        unlisten = await onOpenUrl((urls) => {
          handleCallbackUrls(urls);
        });
        if (disposed) {
          unlisten();
          return;
        }

        const pollId = window.setInterval(readPendingUrls, 1000);
        const previousUnlisten = unlisten;
        unlisten = () => {
          window.clearInterval(pollId);
          previousUnlisten();
        };
      } catch (err) {
        console.error('Failed to initialize deep link listener:', err);
      }
    }

    initDeepLink();

    return () => {
      disposed = true;
      if (unlisten) {
        unlisten();
      }
    };
  }, [handleCallbackUrls]);

  useEffect(() => {
    let mounted = true;

    async function loadBiometricAuthState() {
      const [storedSession, availability] = await Promise.all([
        loadSessionWithRetry(loadSession),
        getBiometricAuthAvailability(),
      ]);

      if (mounted && storedSession && availability.isAvailable) {
        setBiometricAuthLabel(availability.label);
      }
    }

    loadBiometricAuthState().catch(() => undefined);

    return () => {
      mounted = false;
    };
  }, []);

  const handleWebAuthStart = useCallback(async () => {
    playLightImpactHaptic();
    setIsAuthBusy(true);
    setAuthError(null);

    try {
      const verifier = generateRandomString(64);
      const challenge = await generateChallenge(verifier);
      const state = generateRandomString(16);

      await SecureStore.setItemAsync('vex.auth.pkce.verifier', verifier);
      await SecureStore.setItemAsync('vex.auth.pkce.state', state);

      const deviceId = await getOrCreateDeviceId();
      const { platform, deviceName } = getDeviceDetails();

      const webAuthUrl = `${vexApiBaseUrl}/auth/app?` + new URLSearchParams({
        client_id: 'vex_app',
        code_challenge: challenge,
        code_verifier: verifier,
        state: state,
        device_id: deviceId,
        device_name: deviceName,
        platform: platform,
      }).toString();

      console.log('Opening Web Auth URL:', webAuthUrl);
      const callbackUrl = await openWebAuthUrl(webAuthUrl);
      if (isAppAuthCallbackUrl(callbackUrl)) {
        await handleCallbackUrl(callbackUrl);
      }
    } catch (err) {
      console.error('Failed to start web auth:', err);
      playErrorHaptic();
      setAuthError(err instanceof Error ? err.message : 'Не удалось запустить веб-авторизацию.');
    } finally {
      setIsAuthBusy(false);
    }
  }, [handleCallbackUrl]);

  const handleAuthSubmit = useCallback(async () => {
    if (isAuthBusy) {
      playWarningHaptic();
      return;
    }
    if (authMode === 'register') {
      await handleWebAuthStart();
      return;
    }
    if (!email.trim() || !password) {
      playWarningHaptic();
      setAuthError('Введите email и пароль.');
      return;
    }

    playLightImpactHaptic();
    setIsAuthBusy(true);
    setAuthError(null);
    try {
      const nextSession = await login(email.trim(), password);
      resetVpnProfileCache();
      await signIn(nextSession);
      setPassword('');
      await queryClient.invalidateQueries({ queryKey: ['entitlement'] });
      await queryClient.invalidateQueries({ queryKey: ['vpn-profile'] });
      playSuccessHaptic();
      router.replace('/');
    } catch (error) {
      playErrorHaptic();
      setAuthError(error instanceof Error ? error.message : 'Не удалось войти.');
    } finally {
      setIsAuthBusy(false);
    }
  }, [authMode, email, handleWebAuthStart, isAuthBusy, password, queryClient, signIn]);

  const handleBiometricAuth = useCallback(async () => {
    if (isAuthBusy) {
      playWarningHaptic();
      return;
    }

    playLightImpactHaptic();
    setIsAuthBusy(true);
    setAuthError(null);

    try {
      const storedSession = await loadSessionWithRetry(loadSession);
      if (!storedSession) {
        setBiometricAuthLabel('');
        throw new Error('Сохраненная сессия не найдена. Войдите по email и паролю.');
      }

      if (!(await authenticateWithBiometrics())) {
        throw new Error('Биометрическая проверка не подтверждена.');
      }

      resetVpnProfileCache();
      await signIn(storedSession);
      await queryClient.invalidateQueries({ queryKey: ['entitlement'] });
      await queryClient.invalidateQueries({ queryKey: ['vpn-profile'] });
      playSuccessHaptic();
      router.replace('/');
    } catch (error) {
      playErrorHaptic();
      setAuthError(error instanceof Error ? error.message : 'Не удалось войти по биометрии.');
    } finally {
      setIsAuthBusy(false);
    }
  }, [isAuthBusy, queryClient, signIn]);

  return (
    <VexScreen contentStyle={styles.shell}>
      <StatusBar style="light" />
      <KeyboardAvoidingView behavior={Platform.OS === 'ios' ? 'padding' : undefined} style={styles.keyboardLayer}>
        <ScrollView
          bounces={false}
          contentContainerStyle={[
            styles.scrollContent,
            isKeyboardVisible && styles.scrollContentWithKeyboard,
          ]}
          keyboardShouldPersistTaps="handled"
          showsVerticalScrollIndicator={false}
          style={styles.formScroll}
        >
          <View style={[
            styles.authPanel,
            isKeyboardVisible && styles.authPanelWithKeyboard,
          ]}>
            {isKeyboardVisible ? null : (
              <View style={styles.authIcon}>
                <Image source={vexLogo} resizeMode="contain" style={styles.authLogo as any} />
              </View>
            )}
            <Text maxFontSizeMultiplier={1.15} style={[styles.authTitle, isKeyboardVisible && styles.authTitleWithKeyboard]}>
              {authMode === 'login' ? 'Вход в VEX' : 'Регистрация'}
            </Text>
            {isKeyboardVisible ? null : (
              <Text maxFontSizeMultiplier={1.05} style={styles.authSubtitle}>Проверка доступа и VPN-профиля.</Text>
            )}
            <View style={styles.modeSegment}>
              <Pressable
                accessibilityRole="button"
                accessibilityState={{ selected: authMode === 'login' }}
                onPress={() => {
                  playSelectionHaptic();
                  setAuthError(null);
                  setAuthMode('login');
                }}
                style={[styles.modeSegmentButton, authMode === 'login' && styles.modeSegmentButtonActive]}
              >
                <Text maxFontSizeMultiplier={1.1} style={[styles.modeSegmentText, authMode === 'login' && styles.modeSegmentTextActive]}>Вход</Text>
              </Pressable>
              <Pressable
                accessibilityRole="button"
                accessibilityState={{ selected: authMode === 'register' }}
                onPress={() => {
                  playSelectionHaptic();
                  setAuthError(null);
                  setAuthMode('register');
                }}
                style={[styles.modeSegmentButton, authMode === 'register' && styles.modeSegmentButtonActive]}
              >
                <Text maxFontSizeMultiplier={1.1} style={[styles.modeSegmentText, authMode === 'register' && styles.modeSegmentTextActive]}>Регистрация</Text>
              </Pressable>
            </View>
            <TextInput
              autoCapitalize="none"
              autoComplete="off"
              importantForAutofill="no"
              keyboardType="email-address"
              maxFontSizeMultiplier={1.05}
              onChangeText={setEmail}
              onFocus={playSelectionHaptic}
              placeholder="Email"
              placeholderTextColor="#60767B"
              style={styles.input}
              textContentType="none"
              value={email}
            />
            <TextInput
              autoComplete="off"
              autoCapitalize="none"
              importantForAutofill="no"
              maxFontSizeMultiplier={1.05}
              onChangeText={setPassword}
              onFocus={playSelectionHaptic}
              placeholder="Пароль"
              placeholderTextColor="#60767B"
              secureTextEntry
              style={styles.input}
              textContentType="none"
              value={password}
            />
            {authError ? <Text maxFontSizeMultiplier={1.15} selectable style={styles.authError}>{authError}</Text> : null}
            <Pressable disabled={isAuthBusy} onPress={handleAuthSubmit} style={[styles.primaryButton, isAuthBusy && styles.busy]}>
              {isAuthBusy ? <ActivityIndicator color="#031012" /> : <Text maxFontSizeMultiplier={1.1} style={styles.primaryButtonText}>{authMode === 'login' ? 'Войти' : 'Создать аккаунт'}</Text>}
            </Pressable>
            {canUseBiometricAuth ? (
              <Pressable disabled={isAuthBusy} onPress={handleBiometricAuth} style={[styles.secondaryButton, isAuthBusy && styles.busy]}>
                {isAuthBusy ? <ActivityIndicator color="#22D3EE" /> : <Text maxFontSizeMultiplier={1.1} style={styles.secondaryButtonText}>Войти по {biometricAuthLabel}</Text>}
              </Pressable>
            ) : null}
            {supportsWebsiteAuth() ? (
              <Pressable disabled={isAuthBusy} onPress={handleWebAuthStart} style={[styles.secondaryButton, isAuthBusy && styles.busy]}>
                {isAuthBusy ? <ActivityIndicator color="#22D3EE" /> : <Text maxFontSizeMultiplier={1.1} style={styles.secondaryButtonText}>Войти через сайт</Text>}
              </Pressable>
            ) : null}
          </View>
        </ScrollView>
      </KeyboardAvoidingView>
    </VexScreen>
  );
}

const styles = StyleSheet.create({
  shell: {
    justifyContent: 'center',
  },
  keyboardLayer: {
    flex: 1,
    width: '100%',
  },
  formScroll: {
    flex: 1,
    width: '100%',
  },
  scrollContent: {
    flexGrow: 1,
    justifyContent: 'center',
    paddingBottom: 12,
    paddingTop: 8,
  },
  scrollContentWithKeyboard: {
    justifyContent: 'flex-start',
    paddingBottom: 12,
    paddingTop: 4,
  },
  authPanel: {
    alignItems: 'stretch',
    gap: 8,
    paddingHorizontal: 4,
    paddingVertical: 8,
  },
  authPanelWithKeyboard: {
    gap: 7,
    paddingHorizontal: 4,
    paddingVertical: 6,
  },
  authIcon: {
    alignItems: 'center',
    alignSelf: 'center',
    height: 44,
    justifyContent: 'center',
    width: 44,
  },
  authLogo: {
    height: 42,
    width: 42,
  },
  authTitle: {
    color: vexColors.text,
    fontSize: 18,
    fontWeight: '900',
    textAlign: 'center',
  },
  authTitleWithKeyboard: {
    fontSize: 16,
  },
  authSubtitle: {
    color: vexColors.muted,
    fontSize: 11,
    lineHeight: 14,
    textAlign: 'center',
  },
  modeSegment: {
    backgroundColor: vexColors.field,
    borderColor: 'rgba(96,118,123,0.28)',
    borderRadius: 12,
    borderWidth: 1,
    flexDirection: 'row',
    gap: 4,
    padding: 4,
  },
  modeSegmentButton: {
    alignItems: 'center',
    borderRadius: 10,
    flex: 1,
    justifyContent: 'center',
    minHeight: 30,
  },
  modeSegmentButtonActive: {
    backgroundColor: vexColors.accent,
  },
  modeSegmentText: {
    color: vexColors.muted,
    fontSize: 12,
    fontWeight: '900',
  },
  modeSegmentTextActive: {
    color: '#031012',
  },
  input: {
    backgroundColor: vexColors.field,
    borderColor: vexColors.lineStrong,
    borderRadius: 12,
    borderWidth: 1,
    color: vexColors.text,
    fontSize: 14,
    minHeight: 42,
    paddingHorizontal: 10,
  },
  authError: {
    color: vexColors.danger,
    fontSize: 12,
    fontWeight: '700',
    lineHeight: 16,
    textAlign: 'center',
  },
  primaryButton: {
    ...vexSharedStyles.primaryButton,
    borderRadius: 12,
    minHeight: 44,
  },
  primaryButtonText: {
    ...vexSharedStyles.primaryButtonText,
    fontSize: 14,
  },
  busy: {
    ...vexSharedStyles.busy,
  },
  secondaryButton: {
    alignItems: 'center',
    backgroundColor: 'transparent',
    borderColor: vexColors.accent,
    borderRadius: 12,
    borderWidth: 1,
    justifyContent: 'center',
    minHeight: 42,
  },
  secondaryButtonText: {
    color: vexColors.accent,
    fontSize: 14,
    fontWeight: '900',
  },
});
