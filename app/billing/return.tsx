import { useQueryClient } from '@tanstack/react-query';
import { router, useLocalSearchParams } from 'expo-router';
import { useEffect } from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { VexNativeActivityIndicator } from '@/ui/native-activity-indicator';

export default function BillingReturnRoute() {
  const queryClient = useQueryClient();
  const params = useLocalSearchParams<{ status?: string }>();
  const status = Array.isArray(params.status) ? params.status[0] : params.status;

  useEffect(() => {
    let mounted = true;
    Promise.all([
      queryClient.invalidateQueries({ queryKey: ['entitlement'] }),
      queryClient.invalidateQueries({ queryKey: ['vpn-profile'] }),
      queryClient.invalidateQueries({ queryKey: ['vpn-devices'] }),
    ]).finally(() => {
      if (mounted) {
        router.replace('/');
      }
    });

    return () => {
      mounted = false;
    };
  }, [queryClient, status]);

  return (
    <View style={styles.screen}>
      <VexNativeActivityIndicator color="#22D3EE" />
      <Text style={styles.title}>{status === 'failed' ? 'Оплата не завершена' : 'Проверяем оплату'}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  screen: {
    alignItems: 'center',
    backgroundColor: '#020A0B',
    flex: 1,
    gap: 14,
    justifyContent: 'center',
    padding: 24,
  },
  title: {
    color: '#F4FCFD',
    fontSize: 18,
    fontWeight: '800',
    textAlign: 'center',
  },
});
