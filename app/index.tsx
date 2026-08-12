import { Redirect } from 'expo-router';
import { Column, Host, Spacer, Text as UniversalText } from '@expo/ui';
import { StyleSheet } from 'react-native';
import { useSession } from '@/auth/session-context';

export default function IndexRoute() {
  const { isLoading, session } = useSession();

  if (isLoading) {
    return <StartupFallback />;
  }

  return <Redirect href={session ? '/(app)' : '/sign-in'} />;
}

function StartupFallback() {
  return (
    <Host colorScheme="dark" seedColor="#22D3EE" style={styles.host} useViewportSizeMeasurement>
      <Column alignment="center" spacing={16} style={styles.screen}>
        <Spacer flexible />
        <UniversalText textStyle={styles.title}>VEX</UniversalText>
        <UniversalText textStyle={styles.message}>Открываем защищённое подключение…</UniversalText>
        <Spacer flexible />
      </Column>
    </Host>
  );
}

const styles = StyleSheet.create({
  host: { flex: 1 },
  screen: {
    backgroundColor: '#041315',
    flex: 1,
    paddingHorizontal: 24,
  },
  title: {
    color: '#43D9E7',
    fontSize: 42,
    fontWeight: '900',
  },
  message: {
    color: '#A7B9BD',
    fontSize: 16,
    textAlign: 'center',
  },
});
