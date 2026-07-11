import { router } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { Settings, User } from 'lucide-react-native';
import React from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';

import { hasPaidEntitlement } from '@/api/vexApi';
import { HomeNativeHeader } from '@/components/home-native-header';
import { SubscriptionContent } from '@/components/subscription-content';
import { playSelectionHaptic } from '@/native/haptics';
import { VexNativeActivityIndicator } from '@/ui/native-activity-indicator';
import { VexScreen, vexSharedStyles, VexPressable } from '@/ui/vex-ui';
import { vexTheme } from '@/ui/vex-theme';
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
          contentInsetAdjustmentBehavior="automatic"
          contentContainerStyle={styles.content}
          showsVerticalScrollIndicator={false}
        >
          <View style={styles.accountPanel}>
            <View style={styles.accountHero}>
              <View style={styles.userBadge}>
                <User color={vexTheme.colors.accent} size={24} strokeWidth={2.5} />
              </View>
              <View style={styles.accountCopy}>
                <Text style={styles.accountLabel}>Профиль</Text>
                <Text numberOfLines={1} selectable style={styles.accountEmail}>{session.user.email}</Text>
                <View style={styles.accountStatusRow}>
                  <View style={[styles.accountStatusDot, hasEntitlement && styles.accountStatusDotActive]} />
                  <Text numberOfLines={1} style={styles.accountMeta}>{accountSummaryText}</Text>
                </View>
              </View>
            </View>

            <View style={styles.accountDivider} />
            <View style={styles.accessCard}>
              <View style={styles.accessCopy}>
                <Text style={styles.accessCaption}>Тариф</Text>
                <Text numberOfLines={1} style={styles.accessValue}>{accountTierLabel || 'Проверяем подписку'}</Text>
              </View>
              <View style={[styles.accessPill, hasEntitlement && styles.accessPillActive]}>
                <Text style={[styles.accessPillText, hasEntitlement && styles.accessPillTextActive]}>
                  {hasEntitlement ? 'Активен' : 'Проверка'}
                </Text>
              </View>
            </View>
          </View>

          <View style={styles.subscriptionSection}>
            <SubscriptionContent embedded entitlementFallback={activeProfile?.entitlement ?? null} />
          </View>
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
    gap: vexTheme.spacing.md,
    paddingBottom: 30,
  },
  subscriptionSection: {
    alignSelf: 'stretch',
    minHeight: 320,
    width: '100%',
  },
  centerState: {
    alignItems: 'center',
    flex: 1,
    justifyContent: 'center',
  },
  centerStateText: {
    color: vexTheme.colors.textMuted,
    fontSize: 16,
    fontWeight: '700',
    marginTop: 16,
  },
  accountPanel: {
    backgroundColor: vexTheme.colors.surface,
    borderColor: vexTheme.colors.line,
    borderRadius: vexTheme.radius.lg,
    borderWidth: 1,
    gap: 12,
    padding: 16,
  },
  accountHero: {
    alignItems: 'center',
    flexDirection: 'row',
    gap: 10,
    minHeight: 52,
  },
  userBadge: {
    alignItems: 'center',
    backgroundColor: vexTheme.colors.accentMuted,
    borderColor: vexTheme.colors.accentLine,
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
    color: vexTheme.colors.textMuted,
    fontSize: 11,
    fontWeight: '900',
    textTransform: 'uppercase',
  },
  accountEmail: {
    color: vexTheme.colors.text,
    fontSize: 17,
    fontWeight: '900',
    marginTop: 2,
  },
  accountMeta: {
    color: vexTheme.colors.textSecondary,
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
    backgroundColor: vexTheme.colors.textMuted,
    borderRadius: 5,
    height: 10,
    width: 10,
  },
  accountStatusDotActive: {
    backgroundColor: vexTheme.colors.success,
  },
  accountDivider: {
    backgroundColor: vexTheme.colors.line,
    height: 1,
    width: '100%',
  },
  accessCard: {
    alignItems: 'center',
    flexDirection: 'row',
    gap: 12,
    minHeight: 44,
  },
  accessCopy: {
    flex: 1,
    minWidth: 0,
  },
  accessCaption: {
    color: vexTheme.colors.textMuted,
    fontSize: 11,
    fontWeight: '900',
    textTransform: 'uppercase',
  },
  accessValue: {
    color: vexTheme.colors.text,
    fontSize: 15,
    fontWeight: '900',
    marginTop: 2,
  },
  accessPill: {
    alignItems: 'center',
    backgroundColor: vexTheme.colors.surface,
    borderColor: vexTheme.colors.line,
    borderRadius: 999,
    borderWidth: 1,
    justifyContent: 'center',
    minHeight: 30,
    paddingHorizontal: 9,
  },
  accessPillActive: {
    backgroundColor: vexTheme.colors.successMuted,
    borderColor: 'rgba(85,214,169,0.3)',
  },
  accessPillText: {
    color: vexTheme.colors.textMuted,
    fontSize: 11,
    fontWeight: '900',
  },
  accessPillTextActive: {
    color: vexTheme.colors.success,
  },
});
