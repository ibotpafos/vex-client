import { useMutation, useQuery, useQueryClient, type QueryClient } from '@tanstack/react-query';
import { router } from 'expo-router';
import * as WebBrowser from 'expo-web-browser';
import React, { useCallback, useEffect, useState } from 'react';
import { Alert, Linking, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { Ban, CalendarClock, CheckCircle2, Crown, RefreshCw, X } from 'lucide-react-native';
import { billingSummary, cancelSubscription, checkoutSession, vexApiBaseUrl, type BillingPlanOption, type Entitlement } from '@/api/vexApi';
import { billingSummaryFallbackCopy, buildBillingSummary, type BillingSummary } from '@/api/billingSummary';
import { loadCachedBillingSummary, saveCachedBillingSummary } from '@/api/billingSummaryCache';
import { useSession } from '@/auth/session-context';
import { playErrorHaptic, playLightImpactHaptic, playSelectionHaptic, playSuccessHaptic, playWarningHaptic } from '@/native/haptics';
import { VexNativeActivityIndicator } from '@/ui/native-activity-indicator';
import { vexColors, vexSharedStyles } from '@/ui/vex-ui';

const billingReturnScheme = 'vexguard:///billing/return';
const billingReturnUrl = process.env.EXPO_PUBLIC_VEX_BILLING_RETURN_URL || `${vexApiBaseUrl}/v1/billing/mobile-return?status=success`;
const billingFailedUrl = process.env.EXPO_PUBLIC_VEX_BILLING_FAILED_URL || `${vexApiBaseUrl}/v1/billing/mobile-return?status=failed`;
const HOME_ROUTE = '/(app)/(tabs)/index';

WebBrowser.maybeCompleteAuthSession();

type SubscriptionContentProps = {
  embedded?: boolean;
  entitlementFallback?: Entitlement | null;
  onClose?: () => void;
};

export function SubscriptionContent({ embedded = false, entitlementFallback = null, onClose }: SubscriptionContentProps) {
  const { session } = useSession();
  const queryClient = useQueryClient();
  const [cachedSummary, setCachedSummary] = useState<BillingSummary | null>(null);
  const cacheUserId = session?.user.id ?? '';

  const billingQuery = useQuery({
    queryKey: ['billing-summary', session?.accessToken],
    queryFn: () => billingSummary(session!.accessToken),
    enabled: Boolean(session?.accessToken),
    staleTime: 300_000,
    gcTime: 1_800_000,
    refetchInterval: false,
  });

  useEffect(() => {
    let cancelled = false;
    if (!cacheUserId) {
      setCachedSummary(null);
      return undefined;
    }
    loadCachedBillingSummary(cacheUserId)
      .then((storedSummary) => {
        if (cancelled || !storedSummary) {
          return;
        }
        setCachedSummary(storedSummary);
        if (session?.accessToken) {
          queryClient.setQueryData(['billing-summary', session.accessToken], (current: BillingSummary | undefined) => current ?? storedSummary);
        }
      })
      .catch(() => undefined);
    return () => {
      cancelled = true;
    };
  }, [cacheUserId, queryClient, session?.accessToken]);

  useEffect(() => {
    if (!cacheUserId || !billingQuery.data) {
      return;
    }
    setCachedSummary(billingQuery.data);
    void saveCachedBillingSummary(cacheUserId, billingQuery.data).catch(() => undefined);
  }, [billingQuery.data, cacheUserId]);

  const close = useCallback(() => {
    if (onClose) {
      onClose();
      return;
    }
    if (router.canGoBack()) {
      router.back();
      return;
    }
    router.replace(HOME_ROUTE);
  }, [onClose]);

  const checkoutMutation = useMutation({
    mutationFn: async (plan: BillingPlanOption) => {
      if (!session) {
        playWarningHaptic();
        throw new Error('Сначала войдите в аккаунт.');
      }
      playLightImpactHaptic();
      const checkout = await checkoutSession(session.accessToken, plan, {
        failedUrl: billingFailedUrl,
        returnUrl: billingReturnUrl,
      });
      if (!checkout.url) {
        playErrorHaptic();
        throw new Error('Платежная ссылка недоступна.');
      }
      close();
      try {
        await WebBrowser.openAuthSessionAsync(checkout.url, billingReturnScheme, {
          createTask: false,
          showInRecents: true,
          toolbarColor: '#071113',
        });
      } catch {
        await Linking.openURL(checkout.url);
      } finally {
        await refreshBillingQueries(queryClient);
        playSuccessHaptic();
      }
    },
    onError: () => {
      playErrorHaptic();
    },
  });

  const cancelMutation = useMutation({
    mutationFn: async () => {
      if (!session) {
        playWarningHaptic();
        throw new Error('Сначала войдите в аккаунт.');
      }
      playLightImpactHaptic();
      await cancelSubscription(session.accessToken);
      await refreshBillingQueries(queryClient);
      playSuccessHaptic();
    },
    onError: () => {
      playErrorHaptic();
    },
  });

  const fallbackSummary = entitlementFallback ? buildBillingSummary([], entitlementFallback) : null;
  const onlineSummary = billingQuery.data;
  const summary = onlineSummary?.entitlementStatus === 'unknown' && fallbackSummary
    ? fallbackSummary
    : onlineSummary ?? cachedSummary ?? fallbackSummary;
  const fallbackCopy = billingSummaryFallbackCopy(billingQuery.isLoading && !summary);
  const plans = summary?.plans ?? [];
  const currentPlan = summary?.currentPlan;
  const isSubscriptionActive = summary?.entitlementStatus === 'active';
  const isCanceled = normalizedSubscriptionStatus(summary?.status) === 'canceled';
  const accessUntil = subscriptionAccessUntilText(summary?.currentPeriodEnd ?? summary?.effectiveExpiresAt);
  const statusCopy = subscriptionStatusCopy({
    accessUntil,
    isCanceled,
    isSubscriptionActive,
    remainingText: summary?.remainingText,
  });
  const actionBusy = checkoutMutation.isPending || cancelMutation.isPending;
  const error = checkoutMutation.error instanceof Error
      ? checkoutMutation.error.message
      : cancelMutation.error instanceof Error
        ? cancelMutation.error.message
        : !summary && billingQuery.error instanceof Error
          ? billingQuery.error.message
        : null;
  const canClose = !embedded && Boolean(onClose || router.canGoBack());
  const handlePlanPress = useCallback((plan: BillingPlanOption) => {
    if (plan.disabled) {
      playWarningHaptic();
      return;
    }
    checkoutMutation.mutate(plan);
  }, [checkoutMutation]);

  return (
    <View style={[styles.screen, embedded && styles.embeddedScreen]}>
      <View style={[styles.header, embedded && styles.embeddedHeader]}>
        <View style={styles.headerCopy}>
          <Text style={styles.eyebrow}>VEX Team</Text>
          <Text style={styles.title}>Подписка</Text>
        </View>
        {canClose ? (
          <Pressable
            accessibilityLabel="Закрыть управление подпиской"
            accessibilityRole="button"
            onPress={() => {
              playSelectionHaptic();
              close();
            }}
            style={styles.closeButton}
          >
            <X color="#A7B9BD" size={24} strokeWidth={2.5} />
          </Pressable>
        ) : null}
      </View>

      <ScrollView
        alwaysBounceVertical={false}
        contentContainerStyle={[styles.content, embedded && styles.embeddedContent]}
        scrollEnabled={!embedded}
        showsVerticalScrollIndicator={false}
      >
        {isSubscriptionActive ? (
          <View style={styles.subscriptionPanel}>
            <View style={styles.subscriptionStatusRow}>
              <View style={styles.subscriptionStatusIcon}>
                <CalendarClock color="#22D3EE" size={19} strokeWidth={2.6} />
              </View>
              <View style={styles.subscriptionStatusCopy}>
                <Text style={styles.subscriptionLabel}>{isCanceled ? 'Доступ сохранен до' : 'Активна до'}</Text>
                <Text numberOfLines={2} style={styles.subscriptionValue}>{statusCopy.primary}</Text>
                <Text numberOfLines={2} style={styles.subscriptionHint}>{statusCopy.secondary}</Text>
              </View>
            </View>
            <View style={styles.subscriptionActions}>
              <Pressable
                accessibilityRole="button"
                accessibilityState={{ disabled: actionBusy || !currentPlan }}
                disabled={actionBusy || !currentPlan}
                onPress={() => {
                  if (!currentPlan) {
                    playWarningHaptic();
                    return;
                  }
                  checkoutMutation.mutate(currentPlan);
                }}
                style={[styles.subscriptionActionButton, styles.renewButton, (actionBusy || !currentPlan) && styles.disabledAction]}
              >
                <RefreshCw color="#031012" size={17} strokeWidth={2.8} />
                <Text numberOfLines={1} adjustsFontSizeToFit style={styles.renewButtonText}>Продлить</Text>
              </Pressable>
              <Pressable
                accessibilityRole="button"
                accessibilityState={{ disabled: actionBusy || isCanceled }}
                disabled={actionBusy || isCanceled}
                onPress={() => confirmCancelSubscription(() => cancelMutation.mutate())}
                style={[styles.subscriptionActionButton, styles.cancelButton, (actionBusy || isCanceled) && styles.disabledAction]}
              >
                <Ban color="#FF9E9E" size={17} strokeWidth={2.8} />
                <Text numberOfLines={1} adjustsFontSizeToFit style={styles.cancelButtonText}>{isCanceled ? 'Отменена' : 'Отменить'}</Text>
              </Pressable>
            </View>
          </View>
        ) : null}

        <View style={styles.planSectionHeader}>
          <Text style={styles.sectionTitle}>{summary?.title ?? fallbackCopy.title}</Text>
          <Text style={styles.sectionSubtitle}>{summary?.subtitle ?? fallbackCopy.subtitle}</Text>
        </View>

        {billingQuery.isLoading && !summary ? (
          <View style={styles.state}>
          <VexNativeActivityIndicator color="#22D3EE" />
            <Text style={styles.stateText}>Загружаем тарифы</Text>
          </View>
        ) : error ? (
          <Text selectable style={styles.error}>{error}</Text>
        ) : plans.length === 0 ? (
          <Text selectable style={styles.error}>{summary?.emptyMessage ?? 'Активные тарифы сейчас недоступны.'}</Text>
        ) : (
          <View style={styles.planList}>
            {plans.map((plan) => (
              <PlanOptionRow
                actionBusy={actionBusy}
                key={plan.id}
                onPress={handlePlanPress}
                plan={plan}
              />
            ))}
          </View>
        )}
      </ScrollView>
    </View>
  );
}

type PlanOptionRowProps = {
  actionBusy: boolean;
  onPress: (plan: BillingPlanOption) => void;
  plan: BillingPlanOption;
};

const PlanOptionRow = React.memo(function PlanOptionRow({ actionBusy, onPress, plan }: PlanOptionRowProps) {
  const disabled = actionBusy || plan.disabled;
  const handlePress = useCallback(() => onPress(plan), [onPress, plan]);
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityState={{ disabled, selected: plan.current }}
      disabled={disabled}
      onPress={handlePress}
      style={[styles.planOption, plan.current && styles.currentPlanOption, actionBusy && !plan.disabled && styles.busy]}
    >
      <View style={[styles.planIcon, plan.current && styles.currentPlanIcon]}>
        <Crown color={plan.current ? '#22D3EE' : '#031012'} size={22} strokeWidth={2.6} />
      </View>
      <View style={styles.planCopy}>
        <View style={styles.planNameRow}>
          <Text numberOfLines={1} style={[styles.planName, plan.current && styles.currentPlanName]}>{plan.name}</Text>
          {plan.current ? <CheckCircle2 color="#22D3EE" size={18} strokeWidth={2.6} /> : null}
        </View>
        <Text numberOfLines={2} style={styles.planMeta}>{plan.meta}</Text>
      </View>
      <View style={[styles.planActionPill, plan.current && styles.currentPlanActionPill]}>
        <Text numberOfLines={1} adjustsFontSizeToFit style={[styles.planAction, plan.current && styles.currentPlanAction]}>{plan.action}</Text>
      </View>
    </Pressable>
  );
});

function confirmCancelSubscription(onConfirm: () => void) {
  Alert.alert(
    'Отменить подписку?',
    'Доступ сохранится до конца оплаченного периода.',
    [
      { text: 'Не отменять', style: 'cancel' },
      { text: 'Отменить', style: 'destructive', onPress: onConfirm },
    ],
  );
}

function refreshBillingQueries(queryClient: QueryClient) {
  return Promise.all([
    queryClient.invalidateQueries({ queryKey: ['billing-summary'] }),
    queryClient.invalidateQueries({ queryKey: ['entitlement'] }),
    queryClient.invalidateQueries({ queryKey: ['vpn-profile'] }),
    queryClient.invalidateQueries({ queryKey: ['vpn-devices'] }),
  ]);
}

function normalizedSubscriptionStatus(value: string | undefined) {
  return (value || '').trim().toLowerCase();
}

function subscriptionAccessUntilText(value: string | undefined) {
  if (!value) {
    return null;
  }
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return value;
  }
  return new Intl.DateTimeFormat('ru-RU', {
    day: 'numeric',
    month: 'long',
    year: 'numeric',
  }).format(date);
}

function subscriptionStatusCopy(input: {
  accessUntil: string | null;
  isCanceled: boolean;
  isSubscriptionActive: boolean;
  remainingText?: string;
}) {
  if (!input.isSubscriptionActive) {
    return {
      primary: 'Нет активной подписки',
      secondary: 'Выберите тариф, чтобы включить доступ.',
    };
  }
  if (input.isCanceled) {
    return {
      primary: input.accessUntil ?? input.remainingText ?? 'до конца оплаченного периода',
      secondary: 'Автопродление отключено. Можно продлить вручную.',
    };
  }
  return {
    primary: input.accessUntil ?? input.remainingText ?? 'срок уточняется',
    secondary: 'Можно продлить текущий тариф или отменить автопродление.',
  };
}

const styles = StyleSheet.create({
  screen: {
    backgroundColor: '#020A0B',
    flex: 1,
  },
  embeddedScreen: {
    backgroundColor: 'transparent',
    flex: 0,
  },
  content: {
    gap: 10,
    paddingBottom: 16,
    paddingHorizontal: 12,
    paddingTop: 8,
  },
  embeddedContent: {
    paddingBottom: 0,
    paddingHorizontal: 0,
  },
  header: {
    alignItems: 'center',
    flexDirection: 'row',
    justifyContent: 'space-between',
    paddingHorizontal: 12,
    paddingTop: 42,
  },
  embeddedHeader: {
    paddingHorizontal: 0,
    paddingTop: 0,
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
    fontSize: 18,
    fontWeight: '900',
  },
  closeButton: {
    alignItems: 'center',
    backgroundColor: 'rgba(255,255,255,0.06)',
    borderColor: 'rgba(255,255,255,0.1)',
    borderRadius: 14,
    borderWidth: 1,
    height: 40,
    justifyContent: 'center',
    marginLeft: 12,
    width: 40,
  },
  subscriptionPanel: {
    backgroundColor: 'rgba(7,17,19,0.84)',
    borderColor: 'rgba(96,118,123,0.3)',
    borderRadius: 14,
    borderWidth: 1,
    gap: 10,
    padding: 10,
  },
  subscriptionStatusRow: {
    alignItems: 'center',
    flexDirection: 'row',
    gap: 9,
  },
  subscriptionStatusIcon: {
    alignItems: 'center',
    backgroundColor: 'rgba(34,211,238,0.12)',
    borderColor: 'rgba(34,211,238,0.44)',
    borderRadius: 11,
    borderWidth: 1,
    height: 34,
    justifyContent: 'center',
    width: 34,
  },
  subscriptionStatusCopy: {
    flex: 1,
    minWidth: 0,
  },
  subscriptionLabel: {
    color: '#8FBEC6',
    fontSize: 10,
    fontWeight: '900',
    textTransform: 'uppercase',
  },
  subscriptionValue: {
    color: '#F4FCFD',
    fontSize: 15,
    fontWeight: '900',
    lineHeight: 20,
    marginTop: 2,
  },
  subscriptionHint: {
    color: '#8FBEC6',
    fontSize: 11,
    fontWeight: '700',
    lineHeight: 15,
    marginTop: 2,
  },
  subscriptionActions: {
    flexDirection: 'row',
    gap: 8,
  },
  subscriptionActionButton: {
    alignItems: 'center',
    borderRadius: 12,
    borderWidth: 1,
    flex: 1,
    flexDirection: 'row',
    gap: 6,
    justifyContent: 'center',
    minHeight: 40,
    minWidth: 0,
    paddingHorizontal: 10,
  },
  renewButton: {
    backgroundColor: '#22D3EE',
    borderColor: 'rgba(34,211,238,0.62)',
  },
  cancelButton: {
    backgroundColor: 'rgba(255,158,158,0.08)',
    borderColor: 'rgba(255,158,158,0.36)',
  },
  disabledAction: {
    opacity: 0.52,
  },
  renewButtonText: {
    color: '#031012',
    fontSize: 13,
    fontWeight: '900',
    textAlign: 'center',
  },
  cancelButtonText: {
    color: '#FFB6B6',
    fontSize: 13,
    fontWeight: '900',
    textAlign: 'center',
  },
  sectionTitle: {
    color: '#A7B9BD',
    fontSize: 12,
    fontWeight: '900',
    textTransform: 'uppercase',
  },
  sectionSubtitle: {
    color: '#8FBEC6',
    fontSize: 11,
    fontWeight: '700',
    lineHeight: 15,
    marginTop: 3,
  },
  planSectionHeader: {
    paddingTop: 2,
  },
  state: {
    alignItems: 'center',
    gap: 10,
    minHeight: 200,
    justifyContent: 'center',
  },
  stateText: {
    color: vexColors.muted,
    fontSize: 14,
    fontWeight: '700',
  },
  error: {
    color: vexColors.danger,
    fontSize: 14,
    fontWeight: '700',
    lineHeight: 20,
    minHeight: 190,
    textAlign: 'center',
    textAlignVertical: 'center',
  },
  planList: {
    gap: 7,
  },
  planOption: {
    alignItems: 'center',
    backgroundColor: 'rgba(7,17,19,0.84)',
    borderColor: 'rgba(96,118,123,0.3)',
    borderRadius: 14,
    borderWidth: 1,
    flexDirection: 'row',
    gap: 8,
    minHeight: 60,
    paddingHorizontal: 10,
    paddingVertical: 7,
  },
  currentPlanOption: {
    backgroundColor: 'rgba(34,211,238,0.14)',
    borderColor: '#22D3EE',
  },
  busy: {
    ...vexSharedStyles.busy,
  },
  planIcon: {
    alignItems: 'center',
    backgroundColor: '#22D3EE',
    borderRadius: 12,
    height: 32,
    justifyContent: 'center',
    width: 32,
  },
  currentPlanIcon: {
    backgroundColor: 'rgba(34,211,238,0.12)',
    borderColor: 'rgba(34,211,238,0.55)',
    borderWidth: 1,
  },
  planCopy: {
    flex: 1,
    minWidth: 0,
  },
  planNameRow: {
    alignItems: 'center',
    flexDirection: 'row',
    gap: 7,
    minWidth: 0,
  },
  planName: {
    color: '#CFE4E8',
    fontSize: 14,
    flexShrink: 1,
    fontWeight: '900',
  },
  currentPlanName: {
    color: '#F4FCFD',
  },
  planMeta: {
    color: '#8FBEC6',
    fontSize: 11,
    fontWeight: '700',
    lineHeight: 15,
    marginTop: 3,
  },
  planActionPill: {
    alignItems: 'center',
    backgroundColor: 'rgba(2,10,11,0.58)',
    borderColor: 'rgba(96,118,123,0.26)',
    borderRadius: 999,
    borderWidth: 1,
    justifyContent: 'center',
    maxWidth: 100,
    minHeight: 30,
    minWidth: 72,
    paddingHorizontal: 8,
  },
  currentPlanActionPill: {
    backgroundColor: 'rgba(34,211,238,0.14)',
    borderColor: 'rgba(34,211,238,0.4)',
  },
  planAction: {
    color: '#A7B9BD',
    fontSize: 12,
    fontWeight: '900',
    textAlign: 'center',
  },
  currentPlanAction: {
    color: '#B9FBFF',
  },
});
