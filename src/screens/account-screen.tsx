import { router } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { Settings, ShieldCheck, User } from 'lucide-react-native';
import React from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';

import { hasPaidEntitlement } from '@/api/vexApi';
import { HomeNativeHeader } from '@/components/home-native-header';
import { SubscriptionContent } from '@/components/subscription-content';
import { playSelectionHaptic } from '@/native/haptics';
import { VexNativeActivityIndicator } from '@/ui/native-activity-indicator';
import { VexScreen, vexSharedStyles, VexPressable } from '@/ui/vex-ui';
import { useVpnConnectionContext } from '@/vpn/vpn-connection-context';

const vexLogo = require('../../assets/vex-logo-header.png');

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
      <HomeNativeHeader
        actions={(
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
            <Settings color="#EAF7F8" size={24} strokeWidth={2.4} />
          </VexPressable>
        )}
        logoSource={vexLogo}
        planLabel={accountTierLabel}
        showPlan={Boolean(session && accountTierLabel)}
      />

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
          <View style={styles.accountPanel}>
            <View style={styles.accountHero}>
              <View style={styles.userBadge}>
                <User color="#22D3EE" size={24} strokeWidth={2.5} />
              </View>
              <View style={styles.accountCopy}>
                <Text style={styles.accountLabel}>Аккаунт VEX</Text>
                <Text numberOfLines={1} style={styles.accountEmail}>{session.user.email}</Text>
                <View style={styles.accountStatusRow}>
                  <View style={[styles.accountStatusDot, hasEntitlement && styles.accountStatusDotActive]} />
                  <Text numberOfLines={1} style={styles.accountMeta}>{accountSummaryText}</Text>
                </View>
              </View>
            </View>

            <View style={styles.accessCard}>
              <View style={styles.accessIcon}>
                <ShieldCheck color="#031012" size={19} strokeWidth={2.8} />
              </View>
              <View style={styles.accessCopy}>
                <Text style={styles.accessCaption}>Текущий доступ</Text>
                <Text numberOfLines={1} style={styles.accessValue}>{accountTierLabel || 'Проверяем подписку'}</Text>
              </View>
              <View style={[styles.accessPill, hasEntitlement && styles.accessPillActive]}>
                <Text style={[styles.accessPillText, hasEntitlement && styles.accessPillTextActive]}>
                  {hasEntitlement ? 'Активен' : 'Проверка'}
                </Text>
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
    gap: 10,
  },
  content: {
    gap: 10,
    paddingBottom: 30,
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
  accountPanel: {
    backgroundColor: 'rgba(8,25,29,0.84)',
    borderColor: 'rgba(126,233,245,0.2)',
    borderRadius: 20,
    borderWidth: 1,
    gap: 10,
    padding: 10,
    shadowColor: '#22D3EE',
    shadowOpacity: 0.1,
    shadowRadius: 14,
  },
  accountHero: {
    alignItems: 'center',
    flexDirection: 'row',
    gap: 10,
    minHeight: 58,
  },
  userBadge: {
    alignItems: 'center',
    backgroundColor: 'rgba(34,211,238,0.13)',
    borderColor: 'rgba(34,211,238,0.2)',
    borderRadius: 16,
    borderWidth: 1,
    height: 46,
    justifyContent: 'center',
    width: 46,
  },
  accountCopy: {
    flex: 1,
    minWidth: 0,
  },
  accountLabel: {
    color: '#8FBEC6',
    fontSize: 11,
    fontWeight: '900',
    textTransform: 'uppercase',
  },
  accountEmail: {
    color: '#EAF7F8',
    fontSize: 16,
    fontWeight: '900',
    marginTop: 2,
  },
  accountMeta: {
    color: '#B6CACE',
    fontSize: 12,
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
  accessCard: {
    alignItems: 'center',
    backgroundColor: 'rgba(2,10,11,0.52)',
    borderColor: 'rgba(96,118,123,0.24)',
    borderRadius: 16,
    borderWidth: 1,
    flexDirection: 'row',
    gap: 9,
    minHeight: 58,
    paddingHorizontal: 10,
    paddingVertical: 9,
  },
  accessIcon: {
    alignItems: 'center',
    backgroundColor: '#22D3EE',
    borderRadius: 13,
    height: 36,
    justifyContent: 'center',
    width: 36,
  },
  accessCopy: {
    flex: 1,
    minWidth: 0,
  },
  accessCaption: {
    color: '#8FBEC6',
    fontSize: 11,
    fontWeight: '900',
    textTransform: 'uppercase',
  },
  accessValue: {
    color: '#F4FCFD',
    fontSize: 15,
    fontWeight: '900',
    marginTop: 2,
  },
  accessPill: {
    alignItems: 'center',
    backgroundColor: 'rgba(2,10,11,0.58)',
    borderColor: 'rgba(96,118,123,0.26)',
    borderRadius: 999,
    borderWidth: 1,
    justifyContent: 'center',
    minHeight: 30,
    paddingHorizontal: 9,
  },
  accessPillActive: {
    backgroundColor: 'rgba(34,211,238,0.12)',
    borderColor: 'rgba(34,211,238,0.44)',
  },
  accessPillText: {
    color: '#A7B9BD',
    fontSize: 11,
    fontWeight: '900',
  },
  accessPillTextActive: {
    color: '#B9FBFF',
  },
});
