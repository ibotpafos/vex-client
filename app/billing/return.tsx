import { useQueryClient } from '@tanstack/react-query';
import { router, useLocalSearchParams } from 'expo-router';
import { useEffect } from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { VexNativeActivityIndicator } from '@/ui/native-activity-indicator';
import { VexScreen, vexColors } from '@/ui/vex-ui';

export default function BillingReturnRoute() {
  const queryClient = useQueryClient();
  const params = useLocalSearchParams<{ status?: string }>();
  const status = Array.isArray(params.status) ? params.status[0] : params.status;

  useEffect(() => {
    let mounted = true;
    Promise.all([
      queryClient.invalidateQueries({ queryKey: ['entitlement'] }),
      queryClient.invalidateQueries({ queryKey: ['billing-summary'] }),
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
    <VexScreen contentStyle={styles.screen}>
      <View style={styles.panel}>
        <VexNativeActivityIndicator color={vexColors.accent} />
        <Text style={styles.eyebrow}>VEX PAYMENTS</Text>
        <Text style={styles.title}>{status === 'failed' ? 'Оплата не завершена' : 'Проверяем оплату'}</Text>
      </View>
    </VexScreen>
  );
}

const styles = StyleSheet.create({
  screen: {
    flex: 1,
    justifyContent: 'center',
  },
  panel: {
    alignItems: 'center',
    alignSelf: 'stretch',
    backgroundColor: vexColors.card,
    borderColor: vexColors.line,
    borderRadius: 28,
    borderWidth: 1,
    gap: 12,
    paddingHorizontal: 24,
    paddingVertical: 28,
  },
  eyebrow: { color: vexColors.accent, fontSize: 11, fontWeight: '900', letterSpacing: 1.2 },
  title: {
    color: vexColors.text,
    fontSize: 20,
    fontWeight: '900',
    textAlign: 'center',
  },
});
