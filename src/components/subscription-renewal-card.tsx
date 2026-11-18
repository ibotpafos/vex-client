import { vexTheme } from '@/ui/vex-theme';
import { StyleSheet, Text, View } from 'react-native';
import React from 'react';

import type { Entitlement } from '@/api/types';
import { openExternalUrl } from '@/auth/systemAuth';
import { playSelectionHaptic } from '@/native/haptics';
import { vexWebsite } from '@/navigation/website';
import { subscriptionRenewalPresentation } from '@/screens/subscription-renewal-presentation';
import { useToast } from '@/ui/toast';
import { VexPressable } from '@/ui/vex-ui';

export const SubscriptionRenewalCard = React.memo(function SubscriptionRenewalCard({ entitlement }: { entitlement: Entitlement | null }) {
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
});

const styles = StyleSheet.create({
  card: {backgroundColor: vexTheme.colors.surface, borderColor: vexTheme.colors.line, borderWidth: 1, borderRadius: 16, padding: 16, gap: 8},
  title: {color: vexTheme.colors.text, fontSize: 14, fontWeight: '600'},
  message: {color: vexTheme.colors.textSecondary, fontSize: 12, lineHeight: 20},
  actions: {flexDirection: 'row', flexWrap: 'wrap', gap: 8},
  primary: {minHeight: 44, paddingHorizontal: 16, borderRadius: 10, backgroundColor: vexTheme.colors.accent, justifyContent: 'center'},
  primaryLabel: {color: vexTheme.colors.accentInk, fontSize: 13, fontWeight: '600'},
  support: {minHeight: 44, borderRadius: 10, paddingHorizontal: 12, justifyContent: 'center'},
  supportLabel: {color: vexTheme.colors.textSecondary, fontSize: 13},
});
