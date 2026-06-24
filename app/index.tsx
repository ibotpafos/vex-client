import { Redirect } from 'expo-router';
import { StyleSheet, Text, View } from 'react-native';
import { useSession } from '@/auth/session-context';
import { VexNativeActivityIndicator } from '@/ui/native-activity-indicator';

export default function IndexRoute() {
  const { isLoading, session } = useSession();

  if (isLoading) {
    return <StartupFallback />;
  }

  return <Redirect href={session ? '/(app)' : '/sign-in'} />;
}

function StartupFallback() {
  return (
    <View style={styles.screen}>
      <Text style={styles.title}>VEX</Text>
      <VexNativeActivityIndicator color="#22D3EE" size="large" />
    </View>
  );
}

const styles = StyleSheet.create({
  screen: {
    alignItems: 'center',
    backgroundColor: '#020A0B',
    flex: 1,
    gap: 18,
    justifyContent: 'center',
  },
  title: {
    color: '#F4FCFD',
    fontSize: 42,
    fontWeight: '900',
  },
});
