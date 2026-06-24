import { router } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { Settings, ShieldCheck, User } from 'lucide-react-native';
import React from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';

import { hasPaidEntitlement } from '@/api/vexApi';
import { SubscriptionContent } from '@/components/subscription-content';
import { playSelectionHaptic } from '@/native/haptics';
import { VexNativeActivityIndicator } from '@/ui/native-activity-indicator';
import { VexScreen, vexSharedStyles, VexPressable } from '@/ui/vex-ui';
import { useVpnConnectionContext } from '@/vpn/vpn-connection-context';

export default function AccountScreen() {
  const {
    activeProfile,
    accountSummaryText,
    accountTierLabel,
    session,
  } = useVpnConnectionContext();
  const hasEntitlement = hasPaidEntitlement(activeProfile?.entitlement ?? null);

  return (
    <VexScreen contentStyle={styles.shell}>
      <StatusBar style="light" />
      <View style={styles.header}>
        <View style={styles.headerCopy}>
          <Text style={styles.eyebrow}>VEX</Text>
          <Text style={styles.title}>Аккаунт</Text>
        </View>
        <VexPressable
          accessibilityLabel="Настройки"
          onPress={() => {
            playSelectionHaptic();
            router.push('/(app)/settings');
          }}
          style={vexSharedStyles.iconButton}
          hoverStyle={{ opacity: 0.72 }}
          title="Настройки"
        >
          <Settings color="#A7B9BD" size={25} strokeWidth={2.4} />
        </VexPressable>
      </View>

      {!session ? (
        <View style={styles.centerState}>
          <VexNativeActivityIndicator color="#22D3EE" size="large" />
          <Text style={styles.centerStateText}>Загружаем аккаунт</Text>
        </View>
      ) : (
        <ScrollView
          alwaysBounceVertical={false}
          contentContainerStyle={styles.content}
          showsVerticalScrollIndicator={false}
        >
          <View style={styles.accountCard}>
            <View style={styles.accountHeader}>
              <View style={styles.userBadge}>
                <User color="#22D3EE" size={25} strokeWidth={2.5} />
              </View>
              <View style={styles.accountCopy}>
                <Text numberOfLines={1} style={styles.accountEmail}>{session.user.email}</Text>
                <View style={styles.accountStatusRow}>
                  <View style={[styles.accountStatusDot, hasEntitlement && styles.accountStatusDotActive]} />
                  <Text numberOfLines={1} style={styles.accountMeta}>{accountSummaryText}</Text>
                </View>
              </View>
            </View>

            <View style={styles.planRow}>
              <View style={styles.planBadge}>
                <ShieldCheck color="#031012" size={18} strokeWidth={2.8} />
              </View>
              <View style={styles.planCopy}>
                <Text style={styles.planLabel}>Текущий доступ</Text>
                <Text numberOfLines={1} style={styles.planValue}>{accountTierLabel || 'Проверяем подписку'}</Text>
              </View>
            </View>
          </View>

          <SubscriptionContent embedded entitlementFallback={activeProfile?.entitlement ?? null} />
        </ScrollView>
      )}
    </VexScreen>
  );
}

const styles = StyleSheet.create({
  shell: {
    gap: 12,
  },
  header: {
    alignItems: 'center',
    flexDirection: 'row',
    justifyContent: 'space-between',
  },
  headerCopy: {
    flex: 1,
    minWidth: 0,
  },
  eyebrow: {
    color: '#22D3EE',
    fontSize: 12,
    fontWeight: '900',
    letterSpacing: 0,
    marginBottom: 4,
  },
  title: {
    color: '#F4FCFD',
    fontSize: 28,
    fontWeight: '900',
  },
  content: {
    gap: 12,
    paddingBottom: 32,
  },
  centerState: {
    alignItems: 'center',
    flex: 1,
    justifyContent: 'center',
  },
  centerStateText: {
    color: '#A7B9BD',
    fontSize: 16,
    fontWeight: '700',
    marginTop: 16,
  },
  accountCard: {
    backgroundColor: 'rgba(8,25,29,0.84)',
    borderColor: 'rgba(126,233,245,0.18)',
    borderRadius: 26,
    borderWidth: 1,
    gap: 14,
    padding: 14,
    shadowColor: '#22D3EE',
    shadowOpacity: 0.14,
    shadowRadius: 20,
  },
  accountHeader: {
    alignItems: 'center',
    flexDirection: 'row',
    gap: 12,
  },
  userBadge: {
    alignItems: 'center',
    backgroundColor: 'rgba(34,211,238,0.13)',
    borderColor: 'rgba(34,211,238,0.2)',
    borderRadius: 18,
    borderWidth: 1,
    height: 52,
    justifyContent: 'center',
    width: 52,
  },
  accountCopy: {
    flex: 1,
    minWidth: 0,
  },
  accountEmail: {
    color: '#EAF7F8',
    fontSize: 15,
    fontWeight: '900',
  },
  accountMeta: {
    color: '#B6CACE',
    fontSize: 13,
    fontWeight: '800',
    minWidth: 0,
  },
  accountStatusRow: {
    alignItems: 'center',
    flexDirection: 'row',
    gap: 6,
    marginTop: 4,
    minWidth: 0,
  },
  accountStatusDot: {
    backgroundColor: '#78969C',
    borderRadius: 5,
    height: 10,
    width: 10,
  },
  accountStatusDotActive: {
    backgroundColor: '#22D3EE',
  },
  planRow: {
    alignItems: 'center',
    backgroundColor: 'rgba(2,10,11,0.52)',
    borderColor: 'rgba(96,118,123,0.24)',
    borderRadius: 18,
    borderWidth: 1,
    flexDirection: 'row',
    gap: 10,
    padding: 12,
  },
  planBadge: {
    alignItems: 'center',
    backgroundColor: '#22D3EE',
    borderRadius: 14,
    height: 38,
    justifyContent: 'center',
    width: 38,
  },
  planCopy: {
    flex: 1,
    minWidth: 0,
  },
  planLabel: {
    color: '#8FBEC6',
    fontSize: 11,
    fontWeight: '900',
    textTransform: 'uppercase',
  },
  planValue: {
    color: '#F4FCFD',
    fontSize: 16,
    fontWeight: '900',
    marginTop: 3,
  },
});
