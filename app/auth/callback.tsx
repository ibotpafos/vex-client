import { useQueryClient } from '@tanstack/react-query';
import { router, useLocalSearchParams } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { useEffect, useMemo, useRef, useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { exchangeAppAuthCode } from '@/api/vexApi';
import {
  authCallbackAttemptKey,
  getOrCreateAuthCallbackAttempt,
  resolveAuthCallbackExchange,
  type AuthCallbackAttempt,
} from '@/auth/callbackParams';
import { useSession } from '@/auth/session-context';
import { loadWithRetry } from '@/auth/sessionLoadRetry';
import * as SecureStore from '@/native/secureStore';
import { VexNativeActivityIndicator } from '@/ui/native-activity-indicator';
import { VexScreen, vexColors } from '@/ui/vex-ui';
import { resetVpnProfileCache } from '@/vpn/profile';

type CallbackState = 'loading' | 'success' | 'error';

export default function AuthCallbackScreen() {
  const params = useLocalSearchParams<{ code?: string | string[]; state?: string | string[] }>();
  const code = useMemo(() => firstParam(params.code), [params.code]);
  const state = useMemo(() => firstParam(params.state), [params.state]);
  const queryClient = useQueryClient();
  const { signIn } = useSession();
  const [status, setStatus] = useState<CallbackState>('loading');
  const [message, setMessage] = useState('Завершаем вход...');
  const attemptRef = useRef<AuthCallbackAttempt<void> | null>(null);

  useEffect(() => {
    let isMounted = true;

    async function completeSignIn() {
      const [savedState, savedVerifier] = await Promise.all([
        loadWithRetry(() => SecureStore.getItemAsync('vex.auth.pkce.state')),
        loadWithRetry(() => SecureStore.getItemAsync('vex.auth.pkce.verifier')),
      ]);
      const exchange = resolveAuthCallbackExchange({ code, state }, savedState, savedVerifier);

      const session = await exchangeAppAuthCode(exchange.code, exchange.verifier);
      resetVpnProfileCache();
      await signIn(session);
      await SecureStore.deleteItemAsync('vex.auth.pkce.state');
      await SecureStore.deleteItemAsync('vex.auth.pkce.verifier');
      await queryClient.invalidateQueries({ queryKey: ['entitlement'] });
      await queryClient.invalidateQueries({ queryKey: ['vpn-profile'] });
    }

    const attemptKey = authCallbackAttemptKey({ code, state });
    const attempt = getOrCreateAuthCallbackAttempt(attemptRef.current, attemptKey, completeSignIn);
    attemptRef.current = attempt;
    void attempt.promise.then(
      () => {
        if (!isMounted) return;
        setStatus('success');
        setMessage('Вход выполнен.');
        router.replace('/');
      },
      (error: unknown) => {
        if (!isMounted) return;
        setStatus('error');
        setMessage(error instanceof Error ? error.message : 'Не удалось завершить вход.');
      },
    );

    return () => {
      isMounted = false;
    };
  }, [code, queryClient, signIn, state]);

  return (
    <VexScreen contentStyle={styles.screen}>
      <StatusBar style="light" />
      <View style={styles.panel}>
        {status === 'loading' ? <VexNativeActivityIndicator color="#22D3EE" size="large" /> : null}
        <Text style={styles.title}>VEX</Text>
        <Text style={styles.message}>{message}</Text>
        {status === 'error' ? (
          <Pressable accessibilityRole="button" onPress={() => router.replace('/sign-in')} style={styles.button}>
            <Text style={styles.buttonText}>Вернуться ко входу</Text>
          </Pressable>
        ) : null}
      </View>
    </VexScreen>
  );
}

function firstParam(value: string | string[] | undefined): string {
  if (Array.isArray(value)) {
    return value[0] || '';
  }
  return value || '';
}

const styles = StyleSheet.create({
  screen: {
    flex: 1,
    justifyContent: 'center',
  },
  panel: {
    alignSelf: 'stretch',
    alignItems: 'center',
    backgroundColor: vexColors.card,
    borderColor: vexColors.line,
    borderRadius: 28,
    borderWidth: 1,
    gap: 14,
    paddingHorizontal: 24,
    paddingVertical: 28,
    shadowColor: '#000',
    shadowOpacity: 0.25,
    shadowRadius: 24,
  },
  title: {
    color: vexColors.text,
    fontSize: 30,
    fontWeight: '900',
  },
  message: {
    color: vexColors.textSoft,
    fontSize: 15,
    lineHeight: 22,
    textAlign: 'center',
  },
  button: {
    marginTop: 10,
    minHeight: 48,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: 18,
    backgroundColor: vexColors.accent,
    paddingHorizontal: 18,
  },
  buttonText: {
    color: '#031012',
    fontSize: 15,
    fontWeight: '800',
  },
});
