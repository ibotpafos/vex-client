import { useQueryClient } from '@tanstack/react-query';
import { Button, Column, Host, Spacer, Text } from '@expo/ui';
import { router, useLocalSearchParams } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { useEffect, useMemo, useRef, useState } from 'react';
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
    <Host colorScheme="dark" seedColor="#22D3EE" style={styles.host} useViewportSizeMeasurement>
      <StatusBar style="light" />
      <Column alignment="center" spacing={16} style={styles.content}>
        <Spacer flexible />
        <Text textStyle={styles.title}>VEX</Text>
        <Text textStyle={styles.message}>{message}</Text>
        {status === 'error' ? (
          <Button label="Вернуться ко входу" onPress={() => router.replace('/sign-in')} />
        ) : null}
        <Spacer flexible />
      </Column>
    </Host>
  );
}

function firstParam(value: string | string[] | undefined): string {
  if (Array.isArray(value)) {
    return value[0] || '';
  }
  return value || '';
}

const styles = {
  content: {
    backgroundColor: '#041315',
    padding: 24,
  },
  host: {
    flex: 1,
  },
  title: {
    color: '#43D9E7',
    fontSize: 30,
    fontWeight: '800' as const,
  },
  message: {
    color: '#DCECEE',
    fontSize: 15,
    lineHeight: 22,
    textAlign: 'center' as const,
  },
};
