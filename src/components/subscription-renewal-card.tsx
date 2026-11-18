import { StyleSheet, Text, View } from 'react-native';
import React, { useCallback, useState } from 'react';

import type { Entitlement } from '@/api/types';
import { createCheckoutSession } from '@/api/billing';
import { openWebAuthUrl } from '@/auth/systemAuth';
import { playSelectionHaptic } from '@/native/haptics';
import { vexWebsite } from '@/navigation/website';
import { subscriptionRenewalPresentation } from '@/screens/subscription-renewal-presentation';
import { useToast } from '@/ui/toast';
import { VexPressable } from '@/ui/vex-ui';

export const SubscriptionRenewalCard = React.memo(function SubscriptionRenewalCard({ entitlement }: { entitlement: Entitlement | null }) {
  const { showToast } = useToast();
  const [isCreatingCheckout, setIsCreatingCheckout] = useState(false);
  const presentation = subscriptionRenewalPresentation(entitlement);
  if (!presentation) return null;
  const planId = entitlement?.planId || 'basic_monthly';
  const openPayment = useCallback(async () => {
    playSelectionHaptic();
    setIsCreatingCheckout(true);
    try {
      const session = await createCheckoutSession('', planId);
      if (session.url) {
        void openWebAuthUrl(session.url).catch(() => {
          showToast({ message: 'Не удалось открыть оплату Platega. Попробуйте ещё раз.', variant: 'error' });
        });
      } else {
        showToast({ message: 'Не удалось создать сессию оплаты.', variant: 'error' });
      }
    } catch {
      showToast({ message: 'Не удалось создать сессию оплаты Platega.', variant: 'error' });
    } finally {
      setIsCreatingCheckout(false);
    }
  }, [planId, showToast]);
  return (
    <View style={styles.card}>
      <Text style={styles.title}>{presentation.title}</Text>
      <Text style={styles.message}>{presentation.message}</Text>
      <View style={styles.actions}>
        <VexPressable accessibilityRole="button" accessibilityLabel="Оплатить подписку через Platega"
          onPress={openPayment} style={styles.primary} title={presentation.action} disabled={isCreatingCheckout}>
          <Text style={styles.primaryLabel}>{isCreatingCheckout ? 'Оформляем…' : presentation.action}</Text>
        </VexPressable>
        <VexPressable accessibilityRole="button" accessibilityLabel="VPN не работает — открыть поддержку в приложении"
          onPress={() => openWebAuthUrl(vexWebsite.support()).catch(() => {
            showToast({ message: 'Не удалось открыть поддержку.', variant: 'error' });
          })} style={styles.support} title="Нужна помощь?">
          <Text style={styles.supportLabel}>Нужна помощь?</Text>
        </VexPressable>
      </View>
    </View>
  );
});

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
