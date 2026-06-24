import { useQueryClient } from '@tanstack/react-query';
import { router, useLocalSearchParams } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { useEffect, useMemo, useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { exchangeAppAuthCode } from '@/api/vexApi';
import { resolveAuthCallbackExchange } from '@/auth/callbackParams';
import { useSession } from '@/auth/session-context';
import { loadWithRetry } from '@/auth/sessionLoadRetry';
import * as SecureStore from '@/native/secureStore';
import { VexNativeActivityIndicator } from '@/ui/native-activity-indicator';
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

  useEffect(() => {
    let isMounted = true;

    async function completeSignIn() {
      try {
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

        if (!isMounted) {
          return;
        }
        setStatus('success');
        setMessage('Вход выполнен.');
        router.replace('/');
      } catch (error) {
        if (!isMounted) {
          return;
        }
        setStatus('error');
        setMessage(error instanceof Error ? error.message : 'Не удалось завершить вход.');
      }
    }

    completeSignIn();

    return () => {
      isMounted = false;
    };
  }, [code, queryClient, signIn, state]);

  return (
    <View style={styles.screen}>
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
    </View>
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
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: '#031012',
    padding: 24,
  },
  panel: {
    width: '100%',
    maxWidth: 360,
    alignItems: 'center',
    gap: 14,
  },
  title: {
    color: '#F8FAFC',
    fontSize: 28,
    fontWeight: '800',
  },
  message: {
    color: '#A7F3F3',
    fontSize: 15,
    lineHeight: 22,
    textAlign: 'center',
  },
  button: {
    marginTop: 10,
    minHeight: 48,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: 14,
    backgroundColor: '#22D3EE',
    paddingHorizontal: 18,
  },
  buttonText: {
    color: '#031012',
    fontSize: 15,
    fontWeight: '800',
  },
});
