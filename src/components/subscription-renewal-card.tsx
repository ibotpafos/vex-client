import React from 'react';
import { StyleSheet, Text, View } from 'react-native';

import type { Entitlement } from '@/api/types';
import { openExternalUrl } from '@/auth/systemAuth';
import { playSelectionHaptic } from '@/native/haptics';
import { vexWebsite } from '@/navigation/website';
import { subscriptionRenewalPresentation } from '@/screens/subscription-renewal-presentation';
import { useToast } from '@/ui/toast';
import { VexPressable } from '@/ui/vex-ui';

export function SubscriptionRenewalCard({ entitlement }: { entitlement: Entitlement | null }) {
  const { showToast } = useToast();
  const presentation = subscriptionRenewalPresentation(entitlement);
  if (!presentation) return null;
  const openWebsite = (url: string) => {
    playSelectionHaptic();
    void openExternalUrl(url).catch(() => {
      showToast({ message: 'Не удалось открыть сайт VEX. Попробуйте ещё раз.', variant: 'error' });
    });
  };
  return (
    <View style={styles.card}>
      <Text style={styles.title}>{presentation.title}</Text>
      <Text style={styles.message}>{presentation.message}</Text>
      <View style={styles.actions}>
        <VexPressable accessibilityRole="button" accessibilityLabel="Продлить VPN в личном кабинете на сайте"
          onPress={() => openWebsite(vexWebsite.dashboard())} style={styles.primary} title={presentation.action}>
          <Text style={styles.primaryLabel}>{presentation.action}</Text>
        </VexPressable>
        <VexPressable accessibilityRole="button" accessibilityLabel="VPN не работает — открыть поддержку на сайте"
          onPress={() => openWebsite(vexWebsite.support())} style={styles.support} title="Нужна помощь?">
          <Text style={styles.supportLabel}>Нужна помощь?</Text>
        </VexPressable>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  card: {backgroundColor: 'rgba(6,23,29,0.96)', borderColor: 'rgba(132,239,250,0.3)', borderWidth: 1, borderRadius: 16, padding: 12, gap: 8},
  title: {color: '#ECFCFD', fontSize: 14, fontWeight: '700'},
  message: {color: '#C4DADD', fontSize: 12, lineHeight: 18},
  actions: {flexDirection: 'row', flexWrap: 'wrap', gap: 8},
  primary: {minHeight: 44, paddingHorizontal: 14, borderRadius: 12, backgroundColor: '#22D3EE', justifyContent: 'center'},
  primaryLabel: {color: '#06171D', fontSize: 13, fontWeight: '700'},
  support: {minHeight: 44, paddingHorizontal: 10, justifyContent: 'center'},
  supportLabel: {color: '#C4DADD', fontSize: 13},
});
