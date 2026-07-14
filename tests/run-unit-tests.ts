import { billingDurationLabel, billingDurationMonths, billingSummaryFallbackCopy, buildBillingSummary, type BillingPlanSource } from '../src/api/billingSummary';
import { buildSubscriptionReminders } from '../src/notifications/subscriptionReminderSchedule';
import { normalizeApiRequestError, technicalWorksMessage } from '../src/api/error';
import { installManualUpdate, isTrustedIosUpdateUrl } from '../src/api/manualUpdateInstall';
import { errorMessage } from '../src/utils/error';
import { assessManualUpdateCenter, canUseOtaUpdate, requiresNativeUpdate, shouldOfferAppUpdate, updateCheckChannel, validateManualUpdatePayloadForBaseUrl } from '../src/api/updatePreflight';
import { resolveAuthCallbackExchange } from '../src/auth/callbackParams';
import { sessionLoadFailureDiagnosticsSnapshot } from '../src/auth/sessionDiagnostics';
import { isCurrentSessionMutation } from '../src/auth/sessionMutationGuard';
import { loadSessionWithRetry, loadWithRetry } from '../src/auth/sessionLoadRetry';
import { generateChallenge, generateRandomString } from '../src/auth/pkce';
import { buildAppWebAuthUrl } from '../src/auth/webAuthUrl';
import { loadSessionFromStorage, saveSessionToStorage, type SessionStorageAdapter } from '../src/auth/sessionStoreCore';
import { isSupportSocketConnecting } from '../src/api/supportSocketState';
import { optimisticSupportTicket, supportConnectionStatusText, supportHistoryErrorMessage, uniqueSupportMessages, supportChatItems } from '../src/screens/support-helpers';
import {
  deleteTauriSensitiveStorageItem,
  getTauriSensitiveStorageItem,
  isTauriSensitiveStorageKey,
  setTauriSensitiveStorageItem,
  shouldUseMemoryOnlySensitiveWebStorage,
  type TauriInvoke,
  type WebStorageAdapter,
} from '../src/native/secureStoreCore';
import { safeGetStoredValue } from '../src/settings/safeStorage';
import {
  hotVpnProfileSchemaVersion,
  hotVpnProfileTtlMs,
  hotVpnProfileRejectionReason,
  isUsableHotVpnProfileRecord,
  profileFromHotRecord,
  withLastSuccessfulEndpoint,
  type HotVpnProfileRecord,
} from '../src/vpn/hotProfileCacheCore';
import { connectionAttemptsForProfile, isVpnTransportFallbackError, profileEndpoint } from '../src/vpn/connectionFallback';
import { connectableLocalProfile, shouldUseLocalProfileBeforeOnline, vpnConnectTimingSamples } from '../src/vpn/connectFlow';
import { recoverVpnConnection } from '../src/vpn/connectionRecovery';
import { disconnectWithRecoveryTimeout } from '../src/vpn/disconnectRecovery';
import { waitForVerifiedVpnConnection } from '../src/vpn/connectVerification';
import { cleanupFailedVpnConnection } from '../src/vpn/failedConnectionCleanup';
import { androidExperimentalRoutingEnabled, androidProfilePlatform, androidVpnProfileRequiresRefresh, androidVpnProfileWithinBinderBudget, vpnProfileRouteCount } from '../src/vpn/androidRoutingSafety';
import { profileResolutionOrder } from '../src/vpn/profileResolutionFallback';
import { isKeyEpochMismatchError, nextManagedKeyEpoch } from '../src/vpn/keyEpochRecovery';
import { isVpnDeviceForLocation, type VpnLocationDevice } from '../src/vpn/deviceLocation';
import { nativeVpnDeviceForClient } from '../src/vpn/nativeDeviceSelection';
import { assessNativeTunnelHealth, localStatusHealthReasons } from '../src/vpn/nativeTunnelHealth';
import { hasVerifiedNativeTunnelActivity, resolveNativeTunnelVerified } from '../src/vpn/vpnStatusVerification';
import { probeNetworkHealth } from '../src/vpn/networkHealthProbe';
import { defaultVpnBypassRegion, defaultVpnRoutingMode, defaultVpnRoutingPolicyVersion, isSmartRoutingMode, normalizeVpnRoutingMode, resolvedVpnBypassRegion, vpnRoutingModeFromSmartMode } from '../src/vpn/routingPolicy';
import { autoSwitchTargetLocationId, chooseBestVpnLocation } from '../src/vpn/serverSelection';
import { switchVpnLocation } from '../src/vpn/serverSwitch';
import { normalizePackageNames } from '../src/vpn/applicationRouting';
import { assessVpnAutopilotIssue } from '../src/vpn/vpnAutopilotAssessment';
import { buildCreateDeviceRequest } from '../src/api/deviceCreateRequest';
import { HOME_TAB_ROUTE, SUPPORT_TAB_ROUTE } from '../src/navigation/routes';
import { fallbackLocationEndpoint } from '../src/vpn/locationEndpoint';
import type { VpnDevice, VpnDeviceUsage, VpnLocation, SupportMessage } from '../src/api/vexApi';
import type { VpnStatus } from '../src/native/vexVpn';
import type { VpnProfile } from '../src/vpn/profile';

const connectedStatus: VpnStatus = { state: 'connected', rxBytes: 0, txBytes: 0 };

{
  assertEqual(fallbackLocationEndpoint('de'), 'de-1.vexguard.app:51820');
  assertEqual(fallbackLocationEndpoint(' FI '), 'fi-1.vexguard.app:51820');
  assertEqual(fallbackLocationEndpoint('../bad'), '');
}

{
  assertEqual(billingDurationMonths('monthly'), 1);
  assertEqual(billingDurationMonths('quarterly'), 3);
  assertEqual(billingDurationMonths('semiannual'), 6);
  assertEqual(billingDurationMonths('annual'), 12);
  assertEqual(billingDurationLabel(1), '1 месяц');
  assertEqual(billingDurationLabel(3), '3 месяца');
  assertEqual(billingDurationLabel(12), '12 месяцев');

  const reminders = buildSubscriptionReminders('2026-08-20T18:00:00Z', new Date('2026-08-01T00:00:00Z'));
  assertDeepEqual(reminders.map((item) => item.daysBefore), [7, 3, 1, 0]);
  assertEqual(buildSubscriptionReminders('bad-date').length, 0);
  assertDeepEqual(
    buildSubscriptionReminders('2026-08-20T18:00:00Z', new Date('2026-08-19T12:00:00Z')).map((item) => item.daysBefore),
    [0],
  );
}

{
  assertDeepEqual(normalizePackageNames([
    ' com.telegram.messenger ',
    'com.google.android.youtube',
    'com.telegram.messenger',
    'invalid',
    '',
  ]), ['com.google.android.youtube', 'com.telegram.messenger']);
}

{
  assertEqual(defaultVpnRoutingMode, 'all_except_ru');
  assertEqual(defaultVpnBypassRegion, 'ru');
  assertEqual(defaultVpnRoutingPolicyVersion, '2026.06.22.1');
  assertEqual(normalizeVpnRoutingMode('full_tunnel'), 'full_tunnel');
  assertEqual(normalizeVpnRoutingMode('bad'), 'all_except_ru');
  assertEqual(vpnRoutingModeFromSmartMode(true), 'all_except_ru');
  assertEqual(vpnRoutingModeFromSmartMode(false), 'full_tunnel');
  assertEqual(isSmartRoutingMode('all_except_ru'), true);
  assertEqual(isSmartRoutingMode('full_tunnel'), false);
  assertEqual(resolvedVpnBypassRegion(), 'ru');
  assertEqual(resolvedVpnBypassRegion('all_except_ru', ' RU '), 'ru');
  assertEqual(resolvedVpnBypassRegion('full_tunnel', 'ru'), undefined);
}

{
  const profile: VpnProfile = {
    config: '[Interface]\nPrivateKey = key\n',
    entitlement: { active: true, vpnAccess: true },
    locationId: 'de',
    routingMode: 'all_except_ru',
    source: 'local',
  };
  assertEqual(Boolean(connectableLocalProfile(profile, 'de', null, 'all_except_ru')), true);
  assertEqual(connectableLocalProfile(profile, 'de', null, 'full_tunnel'), null);
  assertEqual(connectableLocalProfile({ ...profile, routingMode: undefined }, 'de', null, 'all_except_ru'), null);
  assertEqual(connectableLocalProfile({
    ...profile,
    config: '[Interface]\nAddress = 10.64.1.25/32\nPrivateKey = key\n',
    device: { id: 'android', name: 'Android', status: 'active', assignedIpv4: '10.64.1.34' },
  }, 'de', null, 'all_except_ru'), null);
}

{
  assertEqual(updateCheckChannel('local'), 'stable');
  assertEqual(updateCheckChannel('production'), 'stable');
  assertEqual(updateCheckChannel(' beta '), 'beta');
  assertEqual(updateCheckChannel(''), 'stable');

  assertEqual(shouldOfferAppUpdate({ updateAvailable: true, latestBuild: 1005254 }, 1005254), false);
  assertEqual(shouldOfferAppUpdate({ updateAvailable: true, latestBuild: 1005253 }, 1005254), false);
  assertEqual(shouldOfferAppUpdate({ updateAvailable: true, latestBuild: 1005255 }, 1005254), true);
  assertEqual(shouldOfferAppUpdate({ updateAvailable: false, latestBuild: 1005255 }, 1005254), false);
  assertEqual(shouldOfferAppUpdate({
    currentBuildBlocked: true,
    latestBuild: 1005253,
    updateAvailable: true,
  }, 1005254), true);
}

{
  const summary = buildBillingSummary(billingPlanCandidates(), null);

  assertEqual(summary.entitlementStatus, 'unknown');
  assertEqual(summary.title, 'Проверяем подписку');
  assertDeepEqual(summary.plans.map((plan) => plan.action), ['Проверяем', 'Проверяем']);
  assertDeepEqual(summary.plans.map((plan) => plan.disabled), [true, true]);
}

{
  const summary = buildBillingSummary(billingPlanCandidates(), {
    active: true,
    planId: 'team-monthly',
    tier: 'team',
    vpnAccess: true,
  });

  assertEqual(summary.entitlementStatus, 'active');
  assertEqual(summary.currentPlan?.id, 'team-monthly');
  assertDeepEqual(summary.plans.map((plan) => ({ id: plan.id, current: plan.current, disabled: plan.disabled })), [
    { id: 'pro-monthly', current: false, disabled: false },
    { id: 'team-monthly', current: true, disabled: true },
  ]);
}

{
  const summary = buildBillingSummary([], {
    active: true,
    planId: 'pro_monthly',
    tier: 'pro',
    vpnAccess: true,
  });

  assertEqual(summary.entitlementStatus, 'active');
  assertEqual(summary.currentPlan?.id, 'pro_monthly');
  assertDeepEqual(summary.plans.map((plan) => ({ id: plan.id, current: plan.current, disabled: plan.disabled })), [
    { id: 'basic_monthly', current: false, disabled: false },
    { id: 'pro_monthly', current: true, disabled: true },
    { id: 'family_monthly', current: false, disabled: false },
  ]);
}

{
  const summary = buildBillingSummary(billingPlanCandidates(), {
    active: true,
    planId: 'team-monthly',
    tier: 'team',
    currentPeriodEnd: '2026-07-22T00:00:00Z',
    effectiveExpiresAt: '2026-07-23T00:00:00Z',
    remainingText: '30 дней',
    status: 'canceled',
    vpnAccess: true,
  });

  assertEqual(summary.currentPlan?.id, 'team-monthly');
  assertEqual(summary.currentPeriodEnd, '2026-07-22T00:00:00Z');
  assertEqual(summary.effectiveExpiresAt, '2026-07-23T00:00:00Z');
  assertEqual(summary.remainingText, '30 дней');
  assertEqual(summary.status, 'canceled');
}

{
  const summary = buildBillingSummary(billingPlanCandidates(), {
    active: true,
    planId: 'legacy-annual',
    tier: 'legacy',
    vpnAccess: true,
  });

  assertEqual(summary.entitlementStatus, 'active');
  assertEqual(summary.title, 'Управление подпиской');
  assertDeepEqual(summary.plans.map((plan) => ({ id: plan.id, action: plan.action, disabled: plan.disabled })), [
    { id: 'pro-monthly', action: 'Сменить', disabled: false },
    { id: 'team-monthly', action: 'Сменить', disabled: false },
  ]);
}

{
  assertDeepEqual(billingSummaryFallbackCopy(true), {
    title: 'Проверяем подписку',
    subtitle: 'Проверяем текущий тариф и доступные планы.',
  });
  assertDeepEqual(billingSummaryFallbackCopy(false), {
    title: 'Выберите подписку',
    subtitle: 'Оплата откроется в браузере.',
  });
}

{
  assertDeepEqual(sessionLoadFailureDiagnosticsSnapshot('keychain unavailable'), {
    reason: 'auth_session_load_failed_before_sign_in',
    status: 'failed',
    vpnStatus: { state: 'disconnected', rxBytes: 0, txBytes: 0 },
    samples: {
      session_load_error: 'keychain unavailable',
    },
  });
}

{
  const checksum = 'a'.repeat(64);
  const trustedBaseUrl = 'https://vexguard.app';
  assertDeepEqual(validateManualUpdatePayloadForBaseUrl({
    downloadUrl: `${trustedBaseUrl}/downloads/Vex.apk`,
    checksumSha256: checksum,
    signatureUrl: `${trustedBaseUrl}/downloads/Vex.apk.sig`,
  }, trustedBaseUrl), { ok: true });
  assertEqual(validateManualUpdatePayloadForBaseUrl({
    downloadUrl: 'https://example.com/Vex.apk',
    checksumSha256: checksum,
    signatureUrl: `${trustedBaseUrl}/downloads/Vex.apk.sig`,
  }, trustedBaseUrl).ok, false);
  assertEqual(validateManualUpdatePayloadForBaseUrl({
    downloadUrl: `${trustedBaseUrl}/downloads/Vex.apk`,
    checksumSha256: checksum,
  }, trustedBaseUrl).ok, false);
}

{
  const trustedBaseUrl = 'https://vexguard.app';
  const checksum = 'a'.repeat(64);
  const assessment = assessManualUpdateCenter({
    currentBuild: 1004344,
    currentVersion: '1.0.43',
    trustedBaseUrl,
    update: {
      updateAvailable: true,
      required: false,
      latestVersion: '1.0.45',
      latestBuild: 1004546,
      minSupportedBuild: 1004300,
      downloadUrl: `${trustedBaseUrl}/downloads/Vex-Android.apk`,
      checksumSha256: checksum,
      signatureUrl: `${trustedBaseUrl}/downloads/Vex-Android.apk.sig`,
      reason: 'update_available',
    },
  });

  assertEqual(assessment.canInstall, true);
  assertEqual(assessment.actionLabel, 'Обновить сейчас');
  assertEqual(assessment.compatibilityLabel, 'Совместимо, доступна новая версия');
  assertEqual(assessment.signatureLabel, 'Checksum и подпись настроены');
  const optionalUpdate = {
    updateAvailable: true,
    required: false,
    latestVersion: '1.0.45',
    latestBuild: 1004546,
    minSupportedBuild: 1004300,
    downloadUrl: `${trustedBaseUrl}/downloads/Vex-Android.apk`,
    checksumSha256: checksum,
    signatureUrl: `${trustedBaseUrl}/downloads/Vex-Android.apk.sig`,
    reason: 'update_available',
  };
  assertEqual(requiresNativeUpdate(optionalUpdate), true);
  assertEqual(canUseOtaUpdate(optionalUpdate), false);
  assertEqual(requiresNativeUpdate({ ...optionalUpdate, delivery: 'native', reason: undefined }), true);
  assertEqual(canUseOtaUpdate({ ...optionalUpdate, delivery: 'ota', reason: undefined }), true);
  assertEqual(requiresNativeUpdate({ ...optionalUpdate, delivery: 'ota', reason: undefined }), false);
}

{
  const trustedBaseUrl = 'https://vexguard.app';
  const checksum = 'a'.repeat(64);
  const normalRequiredMetadata = {
    updateAvailable: true,
    required: true,
    latestVersion: '1.0.50',
    latestBuild: 1005052,
    minSupportedBuild: 1004850,
    downloadUrl: `${trustedBaseUrl}/downloads/Vex-Android-1.0.50.apk`,
    checksumSha256: checksum,
    signatureUrl: `${trustedBaseUrl}/downloads/Vex-Android-1.0.50.apk.sig`,
    reason: 'update_available',
  };
  const assessment = assessManualUpdateCenter({
    currentBuild: 1004951,
    currentVersion: '1.0.49',
    trustedBaseUrl,
    update: normalRequiredMetadata,
  });

  assertEqual(assessment.title, 'Нужно обновить VEX');
  assertEqual(assessment.actionLabel, 'Обновить сейчас');
  assertEqual(assessment.compatibilityTone, 'danger');
  assertEqual(assessment.compatibilityLabel, 'Текущая версия не поддерживается');
  assertEqual(requiresNativeUpdate(normalRequiredMetadata), true);
  assertEqual(canUseOtaUpdate(normalRequiredMetadata), false);
}

{
  const trustedBaseUrl = 'https://vexguard.app';
  const assessment = assessManualUpdateCenter({
    currentBuild: 1004445,
    currentVersion: '1.0.44',
    trustedBaseUrl,
    update: {
      updateAvailable: true,
      required: true,
      currentBuildBlocked: true,
      latestVersion: '1.0.43',
      latestBuild: 1004344,
      minSupportedBuild: 1004300,
      downloadUrl: `${trustedBaseUrl}/downloads/Vex-Android-1.0.43.apk`,
      checksumSha256: 'b'.repeat(64),
      signatureUrl: `${trustedBaseUrl}/downloads/Vex-Android-1.0.43.apk.sig`,
      reason: 'blocked_release',
    },
  });

  assertEqual(assessment.currentBuildBlocked, true);
  assertEqual(assessment.title, 'Сборка отозвана');
  assertEqual(assessment.actionLabel, 'Вернуться на стабильную');
  assertEqual(assessment.compatibilityTone, 'danger');
  assertEqual(requiresNativeUpdate({
    updateAvailable: true,
    required: true,
    currentBuildBlocked: true,
    latestVersion: '1.0.43',
    latestBuild: 1004344,
    minSupportedBuild: 1004300,
    downloadUrl: `${trustedBaseUrl}/downloads/Vex-Android-1.0.43.apk`,
    checksumSha256: 'b'.repeat(64),
    signatureUrl: `${trustedBaseUrl}/downloads/Vex-Android-1.0.43.apk.sig`,
    reason: 'blocked_release',
  }), true);
  assertEqual(canUseOtaUpdate({
    updateAvailable: true,
    required: true,
    currentBuildBlocked: true,
    latestVersion: '1.0.43',
    latestBuild: 1004344,
    minSupportedBuild: 1004300,
    downloadUrl: `${trustedBaseUrl}/downloads/Vex-Android-1.0.43.apk`,
    checksumSha256: 'b'.repeat(64),
    signatureUrl: `${trustedBaseUrl}/downloads/Vex-Android-1.0.43.apk.sig`,
    reason: 'blocked_release',
  }), false);
}

{
  const trustedBaseUrl = 'https://vexguard.app';
  const assessment = assessManualUpdateCenter({
    currentBuild: 1004748,
    currentVersion: '1.0.47',
    trustedBaseUrl,
    update: {
      updateAvailable: true,
      required: true,
      latestVersion: '1.0.48',
      latestBuild: 1004850,
      minSupportedBuild: 1004850,
      downloadUrl: `${trustedBaseUrl}/downloads/Vex-Android-1.0.48.apk`,
      changelog: 'Android: старая сборка больше не поддерживается из-за перехода на новую подпись.',
      reason: 'android_signing_key_migration',
    },
  });

  assertEqual(assessment.title, 'Новая Android-сборка VEX');
  assertEqual(assessment.actionLabel, 'Скачать новую сборку');
  assertEqual(assessment.compatibilityLabel, 'Нужна миграция на новую Android-сборку');
  assertEqual(assessment.canInstall, false);
  assertEqual(requiresNativeUpdate({
    updateAvailable: true,
    required: true,
    latestVersion: '1.0.48',
    latestBuild: 1004850,
    minSupportedBuild: 1004850,
    downloadUrl: `${trustedBaseUrl}/downloads/Vex-Android-1.0.48.apk`,
    changelog: 'Android: старая сборка больше не поддерживается из-за перехода на новую подпись.',
    reason: 'android_signing_key_migration',
  }), true);
  assertEqual(canUseOtaUpdate({
    updateAvailable: true,
    required: true,
    latestVersion: '1.0.48',
    latestBuild: 1004850,
    minSupportedBuild: 1004850,
    downloadUrl: `${trustedBaseUrl}/downloads/Vex-Android-1.0.48.apk`,
    changelog: 'Android: старая сборка больше не поддерживается из-за перехода на новую подпись.',
    reason: 'android_signing_key_migration',
  }), false);
}

{
  for (const reason of ['unsupported_config_schema', 'core_version_unsupported', 'api_client_version_unsupported']) {
    assertEqual(requiresNativeUpdate({
      updateAvailable: true,
      required: true,
      latestVersion: '1.0.50',
      latestBuild: 1005052,
      minSupportedBuild: 1004850,
      downloadUrl: 'https://vexguard.app/downloads/Vex-Android-1.0.50.apk',
      reason,
    }), true);
  }
}

{
  const assessment = assessManualUpdateCenter({
    currentBuild: 1004344,
    currentVersion: '1.0.43',
    trustedBaseUrl: 'https://vexguard.app',
    update: {
      updateAvailable: false,
      required: false,
      latestVersion: '',
      latestBuild: 0,
      minSupportedBuild: 1004300,
      downloadUrl: '',
    },
  });

  assertEqual(assessment.updateAvailable, false);
  assertEqual(assessment.title, 'VEX обновлен');
  assertEqual(assessment.compatibilityLabel, 'Совместимо');
}

function profileWithEndpoint(endpoint: string): VpnProfile {
  return {
    config: [
      '[Interface]',
      'PrivateKey = test',
      '[Peer]',
      `Endpoint = ${endpoint}`,
      'AllowedIPs = 0.0.0.0/0',
      '',
    ].join('\n'),
    locationId: 'de',
    source: 'api',
  };
}

async function runAuthStorageWarmStartTests(): Promise<void> {
  assertEqual(isTauriSensitiveStorageKey('vex.auth.session.v1'), true);
  assertEqual(isTauriSensitiveStorageKey('vex.auth.device_id'), true);
  assertEqual(isTauriSensitiveStorageKey('vex.billing.summary.v1'), true);
  assertEqual(isTauriSensitiveStorageKey('vex.entitlement.v1'), true);
  assertEqual(isTauriSensitiveStorageKey('vex.vpn.hot_profiles.v1'), true);
  assertEqual(isTauriSensitiveStorageKey('vex.settings.language.v1'), false);
  assertEqual(
    shouldUseMemoryOnlySensitiveWebStorage('web', false, 'vex.auth.session.v1', ['vex.auth.session.v1']),
    true,
  );
  assertEqual(
    shouldUseMemoryOnlySensitiveWebStorage('web', true, 'vex.auth.session.v1', ['vex.auth.session.v1']),
    false,
  );

  {
    const webStorage = memoryWebStorage({ 'vex.auth.session.v1': '{"accessToken":"legacy"}' });
    const secureStorage = new Map<string, string>();
    const calls: string[] = [];
    const value = await getTauriSensitiveStorageItem(
      'vex.auth.session.v1',
      tauriSensitiveStorageInvoke(secureStorage, calls),
      webStorage,
    );

    assertEqual(value, '{"accessToken":"legacy"}');
    assertEqual(secureStorage.get('vex.auth.session.v1'), '{"accessToken":"legacy"}');
    assertEqual(webStorage.getItem('vex.auth.session.v1'), '{"accessToken":"legacy"}');
    assertDeepEqual(calls, ['get:vex.auth.session.v1', 'set:vex.auth.session.v1']);
  }

  {
    const webStorage = memoryWebStorage();
    const secureStorage = new Map<string, string>([['vex.auth.session.v1', '{"accessToken":"secure"}']]);
    const value = await getTauriSensitiveStorageItem(
      'vex.auth.session.v1',
      tauriSensitiveStorageInvoke(secureStorage),
      webStorage,
    );

    assertEqual(value, '{"accessToken":"secure"}');
  }

  {
    const webStorage = memoryWebStorage();
    const failingInvoke: TauriInvoke = async () => {
      throw new Error('keychain unavailable');
    };
    await setTauriSensitiveStorageItem('vex.auth.session.v1', '{"accessToken":"fallback"}', failingInvoke, webStorage);

    assertEqual(webStorage.getItem('vex.auth.session.v1'), '{"accessToken":"fallback"}');
  }

  {
    const webStorage = memoryWebStorage();
    const secureStorage = new Map<string, string>();
    await setTauriSensitiveStorageItem(
      'vex.auth.session.v1',
      '{"accessToken":"mirrored"}',
      tauriSensitiveStorageInvoke(secureStorage),
      webStorage,
    );

    assertEqual(secureStorage.get('vex.auth.session.v1'), '{"accessToken":"mirrored"}');
    assertEqual(webStorage.getItem('vex.auth.session.v1'), null);
  }

  {
    const webStorage = memoryWebStorage({ 'vex.auth.session.v1': '{"accessToken":"legacy-after-failure"}' });
    const failingInvoke: TauriInvoke = async () => {
      throw new Error('keychain unavailable');
    };
    const value = await getTauriSensitiveStorageItem('vex.auth.session.v1', failingInvoke, webStorage);

    assertEqual(value, '{"accessToken":"legacy-after-failure"}');
  }

  {
    const webStorage = memoryWebStorage();
    const failingInvoke: TauriInvoke = async () => {
      throw new Error('keychain unavailable');
    };
    await assertRejects(
      () => getTauriSensitiveStorageItem('vex.auth.session.v1', failingInvoke, webStorage),
      'keychain unavailable',
    );
  }

  {
    const webStorage = memoryWebStorage({ 'vex.auth.device_id': 'legacy-device' });
    const secureStorage = new Map<string, string>([['vex.auth.device_id', 'secure-device']]);
    const calls: string[] = [];
    await deleteTauriSensitiveStorageItem(
      'vex.auth.device_id',
      tauriSensitiveStorageInvoke(secureStorage, calls),
      webStorage,
    );

    assertEqual(secureStorage.get('vex.auth.device_id'), undefined);
    assertEqual(webStorage.getItem('vex.auth.device_id'), null);
    assertDeepEqual(calls, ['delete:vex.auth.device_id']);
  }
}

async function runSessionLoadRetryTests(): Promise<void> {
  {
    const delays: number[] = [];
    let calls = 0;
    const session = authSessionCandidate();
    const value = await loadSessionWithRetry(
      async () => {
        calls += 1;
        if (calls < 3) {
          throw new Error('secure storage warming up');
        }
        return session;
      },
      async (ms) => {
        delays.push(ms);
      },
      [10, 20, 30],
    );

    assertEqual(value, session);
    assertEqual(calls, 3);
    assertDeepEqual(delays, [10, 20]);
  }

  {
    const delays: number[] = [];
    let calls = 0;
    await assertRejects(
      () => loadSessionWithRetry(
        async () => {
          calls += 1;
          throw new Error('secure storage unavailable');
        },
        async (ms) => {
          delays.push(ms);
        },
        [10, 20],
      ),
      'secure storage unavailable',
    );

    assertEqual(calls, 3);
    assertDeepEqual(delays, [10, 20]);
  }

  {
    const delays: number[] = [];
    let calls = 0;
    const value = await loadWithRetry(
      async () => {
        calls += 1;
        if (calls === 1) {
          throw new Error('secure storage warming up');
        }
        return 'pkce-verifier';
      },
      async (ms) => {
        delays.push(ms);
      },
      [10, 20],
    );

    assertEqual(value, 'pkce-verifier');
    assertEqual(calls, 2);
    assertDeepEqual(delays, [10]);
  }
}

async function runSessionStorePersistenceTests(): Promise<void> {
  const store = new Map<string, string>();
  const storage: SessionStorageAdapter = {
    getItemAsync: async (key) => store.get(key) ?? null,
    setItemAsync: async (key, value) => {
      store.set(key, value);
    },
    deleteItemAsync: async (key) => {
      store.delete(key);
    },
  };

  const session = authSessionCandidate();
  await saveSessionToStorage(session, storage);
  assertDeepEqual(await loadSessionFromStorage(storage), session);
  assertEqual(Boolean(store.get('vex.auth.session.v1')), true);
  assertEqual(Boolean(store.get('vex.auth.session.history.v1')), true);

  store.set('vex.auth.session.v1', '{"accessToken":"truncated"');
  assertDeepEqual(await loadSessionFromStorage(storage), session);
  assertDeepEqual(JSON.parse(store.get('vex.auth.session.v1') || '{}'), session);

  store.set('vex.auth.session.history.v1', 'not-json');
  store.set('vex.auth.session.v1', 'not-json');
  assertEqual(await loadSessionFromStorage(storage), null);
  assertEqual(store.has('vex.auth.session.v1'), false);
  assertEqual(store.has('vex.auth.session.history.v1'), false);
}

async function runSafeStorageTests(): Promise<void> {
  assertEqual(await safeGetStoredValue('vex.settings.vpn.location.v1', async () => 'de'), 'de');
  assertEqual(await safeGetStoredValue('vex.settings.vpn.location.v1', async () => null), null);
  assertEqual(await safeGetStoredValue('vex.settings.vpn.location.v1', async () => {
    throw new Error('secure storage unavailable');
  }), null);
}

function runHotVpnProfileTests(): void {
  const nowMs = 1_000_000;
  const runtimeKey = 'test-runtime';
  const profile = profileWithEndpoint('de.example.com:51820');
  const record: HotVpnProfileRecord = {
    schemaVersion: hotVpnProfileSchemaVersion,
    userId: 'user-1',
    runtimeKey,
    locationId: 'de',
    profile,
    savedAtMs: nowMs - 1_000,
    lastSuccessfulEndpoint: 'de.example.com:443',
  };

  assertEqual(isUsableHotVpnProfileRecord(record, 'user-1', 'de', runtimeKey, nowMs), true);
  assertEqual(profileFromHotRecord(record, nowMs).hotProfileUsed, true);
  assertEqual(profileFromHotRecord(record, nowMs).hotProfileAgeMs, 1_000);
  assertEqual(profileFromHotRecord(record, nowMs).lastSuccessfulEndpoint, 'de.example.com:443');
  assertEqual(isUsableHotVpnProfileRecord({
    ...record,
    savedAtMs: nowMs - hotVpnProfileTtlMs - 1,
  }, 'user-1', 'de', runtimeKey, nowMs), false);
  assertEqual(hotVpnProfileRejectionReason({
    ...record,
    savedAtMs: nowMs - hotVpnProfileTtlMs - 1,
  }, 'user-1', 'de', runtimeKey, nowMs), 'expired');
  assertEqual(isUsableHotVpnProfileRecord({
    ...record,
    profile: { ...profile, rotationRequired: true },
  }, 'user-1', 'de', runtimeKey, nowMs), false);
  assertEqual(hotVpnProfileRejectionReason({
    ...record,
    profile: { ...profile, rotationRequired: true },
  }, 'user-1', 'de', runtimeKey, nowMs), 'rotation_required');
  assertEqual(isUsableHotVpnProfileRecord(record, 'user-2', 'de', runtimeKey, nowMs), false);
  assertEqual(withLastSuccessfulEndpoint(profile, 'de.example.com:443').lastSuccessfulEndpoint, 'de.example.com:443');
}

function runHotConnectFlowTests(): void {
  const paidEntitlement = { active: true, vpnAccess: true };
  const hotProfile: VpnProfile = {
    ...profileWithEndpoint('de.example.com:51820'),
    entitlement: paidEntitlement,
    hotProfileAgeMs: 2_000,
    hotProfileUsed: true,
    source: 'local',
  };

  assertEqual(shouldUseLocalProfileBeforeOnline(hotProfile, null), true);
  assertEqual(shouldUseLocalProfileBeforeOnline({ ...hotProfile, rotationRequired: true }, null), false);
  assertEqual(shouldUseLocalProfileBeforeOnline({ ...hotProfile, entitlement: undefined }, paidEntitlement), true);
  assertEqual(shouldUseLocalProfileBeforeOnline({ ...hotProfile, entitlement: { active: false, vpnAccess: false } }, null), false);
  assertEqual(connectableLocalProfile(hotProfile, 'de', null)?.source, 'local');
  assertEqual(connectableLocalProfile(hotProfile, 'fi', null), null);
  assertEqual(connectableLocalProfile({ ...hotProfile, entitlement: undefined }, 'de', paidEntitlement)?.source, 'local');
  assertEqual(connectableLocalProfile({ ...hotProfile, rotationRequired: true }, 'de', paidEntitlement), null);
  assertDeepEqual(vpnConnectTimingSamples({
    endpointAttempts: ['de.example.com:443'],
    interfaceUpMs: 1_260,
    nativeStartMs: 1_200,
    profile: hotProfile,
    tapStartedAt: 1_000,
  }), {
    connect_profile_source: 'local',
    endpoint_attempts: ['de.example.com:443'],
    hot_profile_age_ms: 2_000,
    hot_profile_used: true,
    native_start_to_interface_up_ms: 60,
    profile_resolve_ms: 200,
    tap_to_native_start_ms: 200,
  });
}

function runCreateDeviceRequestTests(): void {
  const request = buildCreateDeviceRequest(
    { deviceName: 'Mac', idempotencyPrefix: 'macos', platform: 'macos' },
    ' DE ',
    ' macos-stable-device ',
    { platform: 'macos', version: '1.0.48' },
  );
  const repeated = buildCreateDeviceRequest(
    { deviceName: 'Mac', idempotencyPrefix: 'macos', platform: 'macos' },
    'de',
    'macos-stable-device',
    { platform: 'macos', version: '1.0.48' },
  );

  assertEqual(request.idempotencyKey, 'macos-macos-stable-device-de-device');
  assertEqual(repeated.idempotencyKey, request.idempotencyKey);
  assertDeepEqual(request.body, {
    name: 'Mac',
    location: 'de',
    protocol: 'amneziawg',
    external_device_id: 'macos-stable-device',
    platform: 'macos',
    app_version: '1.0.48',
  });
}

{
  const attempts = connectionAttemptsForProfile(profileWithEndpoint('de.example.com:51820'));

  assertEqual(attempts.length, 2);
  assertDeepEqual(attempts.map(profileEndpoint), ['de.example.com:51820', 'de.example.com:443']);
}

{
  const attempts = connectionAttemptsForProfile({
    ...profileWithEndpoint('de.example.com:51820'),
    lastSuccessfulEndpoint: 'de.example.com:443',
  });

  assertDeepEqual(attempts.map(profileEndpoint), ['de.example.com:443', 'de.example.com:51820']);
}

{
  const attempts = connectionAttemptsForProfile(profileWithEndpoint('de.example.com:443'));

  assertEqual(attempts.length, 2);
  assertDeepEqual(attempts.map(profileEndpoint), ['de.example.com:443', 'de.example.com:51820']);
}

{
  const attempts = connectionAttemptsForProfile(profileWithEndpoint('[2001:db8::1]:51820'));

  assertEqual(profileEndpoint(attempts[1]), '[2001:db8::1]:443');
}

{
  const profile: VpnProfile = {
    config: '[Interface]\nPrivateKey = test\n[Peer]\nAllowedIPs = 0.0.0.0/0\n',
    locationId: 'de',
    source: 'api',
  };

  assertDeepEqual(connectionAttemptsForProfile(profile), [profile]);
}

assertEqual(isVpnTransportFallbackError(new Error('VPN handshake did not complete')), true);
assertEqual(isVpnTransportFallbackError(new Error('Подписка не активна.')), false);

{
  const best = chooseBestVpnLocation([
    locationCandidate('de', { latencyMs: 80 }),
    locationCandidate('fi', { latencyMs: 24 }),
  ]);

  assertEqual(best?.id, 'fi');
}

{
  const best = chooseBestVpnLocation([
    locationCandidate('de', { latencyMs: 10, status: 'degraded' }),
    locationCandidate('fi', { latencyMs: 80, status: 'healthy' }),
  ]);

  assertEqual(best?.id, 'fi');
}

{
  const best = chooseBestVpnLocation([
    locationCandidate('de', { availability: 'retired', latencyMs: 10 }),
    locationCandidate('fi', { healthyNodes: 0, latencyMs: 12 }),
    locationCandidate('nl', { latencyMs: 55 }),
  ]);

  assertEqual(best?.id, 'nl');
}

{
  const locations = [
    locationCandidate('de', { latencyMs: 80 }),
    locationCandidate('fi', { latencyMs: 24 }),
  ];

  assertEqual(autoSwitchTargetLocationId('de', locations), 'fi');
  assertEqual(autoSwitchTargetLocationId('fi', locations), null);
}

{
  assertEqual(isVpnDeviceForLocation(deviceCandidate({ externalDeviceId: 'phone:de' }), 'de'), true);
  assertEqual(isVpnDeviceForLocation(deviceCandidate({ nodeId: 'de-1' }), 'de'), true);
  assertEqual(isVpnDeviceForLocation(deviceCandidate({ endpoint: 'de-1.vexguard.app:443' }), 'de'), true);
  assertEqual(isVpnDeviceForLocation(deviceCandidate({ nodeId: 'fi-1', endpoint: 'fi-1.vexguard.app:51820' }), 'de'), false);
  assertEqual(isVpnDeviceForLocation(deviceCandidate({ externalDeviceId: 'phone' }), 'de'), false);
}

{
  const staleMacDevice = vpnDeviceCandidate({
    externalDeviceId: 'old-mac:de',
    platform: 'macos',
  });

  assertEqual(
    nativeVpnDeviceForClient([staleMacDevice], 'de', 'new-mac:de', 'new-mac'),
    undefined,
  );
}

{
  const currentMacDevice = vpnDeviceCandidate({
    externalDeviceId: 'current-mac:de',
    platform: 'macos',
  });

  assertEqual(
    nativeVpnDeviceForClient([currentMacDevice], 'de', 'current-mac:de', 'current-mac'),
    currentMacDevice,
  );
}

{
  const legacyLocationDevice = vpnDeviceCandidate({
    externalDeviceId: 'android-123:fi',
    nodeId: 'fi-1',
    platform: 'android',
  });

  assertEqual(
    nativeVpnDeviceForClient([legacyLocationDevice], 'de', 'android-123', 'android-123'),
    legacyLocationDevice,
  );
}

void runAsyncTests().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

async function runAsyncTests(): Promise<void> {
  await runAuthStorageWarmStartTests();
  await runSessionLoadRetryTests();
  await runSessionStorePersistenceTests();
  await runSafeStorageTests();
  runHotVpnProfileTests();
  runHotConnectFlowTests();
  runCreateDeviceRequestTests();
  await runPkceTests();
  await runManualUpdateInstallTests();
  await runVpnDisconnectRecoveryTests();
  await runVpnHandshakeVerificationTests();
  await runFailedConnectionCleanupTests();
  runNavigationRouteTests();
  runAndroidRoutingSafetyTests();
  runSupportTests();
  runErrorMessageTests();
  await runServerSwitchTests();
}

function runAndroidRoutingSafetyTests(): void {
  assertEqual(androidExperimentalRoutingEnabled('android', undefined), false);
  assertEqual(androidExperimentalRoutingEnabled('android', '0'), false);
  assertEqual(androidExperimentalRoutingEnabled('android', '1'), true);
assertEqual(androidExperimentalRoutingEnabled('ios', '1'), false);
assertEqual(vpnProfileRouteCount('[Peer]\nAllowedIPs = 0.0.0.0/1, 128.0.0.0/1\n'), 2);
assertEqual(androidVpnProfileWithinBinderBudget('android', '[Peer]\nAllowedIPs = 0.0.0.0/1, 128.0.0.0/1', 2), true);
assertEqual(androidVpnProfileWithinBinderBudget('android', '[Peer]\nAllowedIPs = 0.0.0.0/1, 128.0.0.0/1', 1), false);
assertEqual(androidVpnProfileWithinBinderBudget('ios', '[Peer]\nAllowedIPs = 0.0.0.0/1, 128.0.0.0/1', 1), true);
const oversizedAndroidProfile = `[Peer]\nAllowedIPs = ${Array.from({ length: 1_501 }, (_, index) => `10.0.${Math.floor(index / 256)}.${index % 256}/32`).join(', ')}`;
assertEqual(androidVpnProfileRequiresRefresh('android', undefined, '[Peer]\nAllowedIPs = 0.0.0.0/0'), false);
assertEqual(androidVpnProfileRequiresRefresh('android', oversizedAndroidProfile), true);
assertEqual(androidVpnProfileRequiresRefresh('ios', oversizedAndroidProfile), false);
assertEqual(androidProfilePlatform('android', true), 'android-smart-v1');
assertEqual(androidProfilePlatform('android', false), 'android');

const profileFallbackLocations = [
  { id: 'de', availability: 'available', healthyNodes: 1 },
  { id: 'fi', availability: 'available', healthyNodes: 1 },
  { id: 'retired', availability: 'retired', healthyNodes: 1 },
] as any;
assertDeepEqual(
  profileResolutionOrder('de', profileFallbackLocations).map((location) => location.id),
  ['de', 'fi'],
);
}

async function runFailedConnectionCleanupTests(): Promise<void> {
  const calls: boolean[] = [];
  const disconnect = async ({ releaseAntiLeak }: { releaseAntiLeak: boolean }) => {
    calls.push(releaseAntiLeak);
  };
  await cleanupFailedVpnConnection(true, disconnect);
  await cleanupFailedVpnConnection(false, disconnect);
  assertDeepEqual(calls, [false, true]);
}

async function runVpnHandshakeVerificationTests(): Promise<void> {
  assertEqual(hasVerifiedNativeTunnelActivity({
    state: 'connected',
    rxBytes: 0,
    txBytes: 256,
    latestHandshakeEpochMillis: 0,
  }, 'android'), false);
  assertEqual(hasVerifiedNativeTunnelActivity({
    state: 'connected',
    rxBytes: 0,
    txBytes: 256,
    latestHandshakeEpochMillis: 1_000,
  }, 'android'), true);
  assertEqual(hasVerifiedNativeTunnelActivity({
    state: 'connected',
    rxBytes: 0,
    txBytes: 256,
    latestHandshakeEpochMillis: 0,
  }, 'macos'), true);
  assertEqual(resolveNativeTunnelVerified({
    state: 'connected',
    rxBytes: 0,
    txBytes: 256,
    latestHandshakeEpochMillis: 0,
    verified: true,
  }, 'android'), false);

  const pendingStatus: VpnStatus = { state: 'connected', rxBytes: 0, txBytes: 0, verified: false };
  const verifiedStatus: VpnStatus = { state: 'connected', rxBytes: 128, txBytes: 64, verified: true };
  let reads = 0;
  const result = await waitForVerifiedVpnConnection(pendingStatus, async () => {
    reads += 1;
    return reads === 1 ? pendingStatus : verifiedStatus;
  }, {
    attempts: 2,
    pollMs: 0,
    wait: async () => undefined,
  });
  assertEqual(result.verified, true);
  assertEqual(reads, 2);

  const staleVerifiedStatus: VpnStatus = {
    state: 'connected',
    rxBytes: 128,
    txBytes: 64,
    latestHandshakeEpochMillis: 10_000,
    verified: true,
  };
  const freshVerifiedStatus: VpnStatus = {
    ...staleVerifiedStatus,
    latestHandshakeEpochMillis: 20_000,
  };
  let freshnessReads = 0;
  const freshResult = await waitForVerifiedVpnConnection(staleVerifiedStatus, async () => {
    freshnessReads += 1;
    return freshVerifiedStatus;
  }, {
    attempts: 1,
    minimumHandshakeEpochMillis: 15_000,
    pollMs: 0,
    wait: async () => undefined,
  });
  assertEqual(freshResult.latestHandshakeEpochMillis, 20_000);
  assertEqual(freshnessReads, 1);

  await assertRejects(
    () => waitForVerifiedVpnConnection(pendingStatus, async () => pendingStatus, {
      attempts: 1,
      pollMs: 0,
      wait: async () => undefined,
    }),
    'handshake timed out',
  );
}

async function runVpnDisconnectRecoveryTests(): Promise<void> {
  let openedRecovery = false;
  await assertRejects(
    () => disconnectWithRecoveryTimeout(
      new Promise<never>(() => undefined),
      async () => {
        openedRecovery = true;
      },
      0,
    ),
    'перезагрузка и повторный вход не нужны',
  );
  assertEqual(openedRecovery, true);

  let unnecessaryRecovery = false;
  const status = await disconnectWithRecoveryTimeout(
    Promise.resolve('disconnected'),
    async () => {
      unnecessaryRecovery = true;
    },
    50,
  );
  assertEqual(status, 'disconnected');
  assertEqual(unnecessaryRecovery, false);
}

async function runServerSwitchTests(): Promise<void> {
  testNativeTunnelHealthIgnoresConnectedZeroHandshake();
  testNativeTunnelHealthDetectsLocalFailureStates();
  testNativeTunnelHealthDetectsBackendUsageDegradation();
  testVpnAutopilotClassifiesRecoverableAndBlockedFailures();
  await testNetworkHealthProbeReportsDnsAndHttpsState();
  await testProfileFetchFailureKeepsCurrentTunnel();
  await testTargetHandshakeFailureRollsBackToPreviousProfile();
  await testServerSwitchRefreshesProfileBeforeReplacingTunnel();
  await testRecoveryKeepsCurrentProfileWhenReconnectSucceeds();
  await testRecoveryUsesFreshSameLocationProfile();
  await testRecoveryRotatesProfileForKeyOrProfileFailure();
  await testRecoveryFailsOverToBestOtherLocation();
  await testRecoveryStopsOnNonRetryableError();
  await testRecoveryFailureDoesNotPersistNewLocation();
}

function testNativeTunnelHealthIgnoresConnectedZeroHandshake(): void {
  const status: VpnStatus = {
    latestHandshakeEpochMillis: 0,
    rxBytes: 100,
    state: 'connected',
    txBytes: 200,
  };

  assertDeepEqual(localStatusHealthReasons(status, 1_000_000, 180), []);
}

function testNativeTunnelHealthDetectsLocalFailureStates(): void {
  assertDeepEqual(
    localStatusHealthReasons({ state: 'disconnected', rxBytes: 0, txBytes: 0 }, 1_000_000, 180),
    ['local_status_disconnected'],
  );
  assertDeepEqual(
    localStatusHealthReasons({ state: 'error', rxBytes: 0, txBytes: 0, leakProtection: 'blocking' }, 1_000_000, 180),
    ['leak_blocking', 'local_status_error'],
  );
  assertDeepEqual(
    localStatusHealthReasons({
      latestHandshakeEpochMillis: 1_000_000 - 181_000,
      rxBytes: 100,
      state: 'connected',
      txBytes: 200,
    }, 1_000_000, 180),
    ['stale_local_handshake'],
  );
}

function testNativeTunnelHealthDetectsBackendUsageDegradation(): void {
  const health = assessNativeTunnelHealth({
    deviceUsage: vpnDeviceUsageCandidate({ connected: false, connectionStatus: 'stale' }),
    nowMs: 1_000_000,
    staleHandshakeSeconds: 180,
    status: { state: 'connected', rxBytes: 100, txBytes: 200 },
  });

  assertEqual(health.healthy, false);
  assertDeepEqual(health.reasons, ['device_usage_degraded']);
}

function testVpnAutopilotClassifiesRecoverableAndBlockedFailures(): void {
  const server = assessVpnAutopilotIssue({
    healthReasons: ['stale_local_handshake'],
    probe: { endpointLatencyMs: 1200, dnsOk: true, httpsOk: true },
  });
  assertEqual(server.cause, 'server');
  assertEqual(server.canFailover, true);

  const dns = assessVpnAutopilotIssue({
    probe: { dnsOk: false, endpointProbeError: 'lookup de-1.vexguard.app failed' },
  });
  assertEqual(dns.cause, 'dns');
  assertEqual(dns.canFailover, true);

  const subscription = assessVpnAutopilotIssue({ error: new Error('Подписка не активна.') });
  assertEqual(subscription.cause, 'subscription');
  assertEqual(subscription.canFailover, false);

  const permission = assessVpnAutopilotIssue({ error: new Error('VPN permission denied') });
  assertEqual(permission.cause, 'permission');
  assertEqual(permission.canFailover, false);

  const key = assessVpnAutopilotIssue({ error: new Error('profile config invalid public key') });
  assertEqual(key.cause, 'key_or_profile');
  assertEqual(key.canFailover, false);
}

async function testNetworkHealthProbeReportsDnsAndHttpsState(): Promise<void> {
  const probe = await probeNetworkHealth({
    apiBaseUrl: 'https://vexguard.app',
    endpoint: 'de-1.vexguard.app:51820',
    fetchImpl: async () => ({ ok: true, status: 204 }) as Response,
    measureEndpointLatency: async () => {
      throw new Error('lookup failed');
    },
  });

  assertEqual(probe.dnsOk, false);
  assertEqual(probe.httpsOk, true);
  assertEqual(probe.endpointLatencyMs, null);
}

async function testProfileFetchFailureKeepsCurrentTunnel(): Promise<void> {
  const previousProfile = profileForLocation('fi', 'fi.example.com:51820');
  const calls: string[] = [];

  const result = await switchVpnLocation({
    connectProfile: async (profile) => {
      calls.push(`connect:${profile.locationId}`);
      return { profile, status: connectedStatus };
    },
    isRetryableConnectError: isVpnTransportFallbackError,
    persistLocation: async (locationId) => {
      calls.push(`persist:${locationId}`);
      return locationId;
    },
    previousLocationId: 'fi',
    previousProfile,
    previousStatus: connectedStatus,
    resolveProfile: async (locationId) => {
      calls.push(`resolve:${locationId}`);
      throw new Error('profile fetch failed');
    },
    setCachedProfile: (locationId, profile) => {
      calls.push(`cache:${locationId}:${profile.locationId}`);
    },
    targetLocationId: 'de',
  });

  assertEqual(result.ok, false);
  if (!result.ok) {
    assertEqual(result.rollback, 'not_started');
  }
  assertDeepEqual(calls, ['resolve:de', 'persist:fi', 'cache:fi:fi']);
}

async function testTargetHandshakeFailureRollsBackToPreviousProfile(): Promise<void> {
  const previousProfile = profileForLocation('fi', 'fi.example.com:51820');
  const targetProfile = profileForLocation('de', 'de.example.com:51820');
  const calls: string[] = [];

  const result = await switchVpnLocation({
    connectProfile: async (profile) => {
      calls.push(`connect:${profile.locationId}`);
      if (profile.locationId === 'de') {
        throw new Error('handshake timeout');
      }
      return { profile, status: connectedStatus };
    },
    isRetryableConnectError: isVpnTransportFallbackError,
    persistLocation: async (locationId) => {
      calls.push(`persist:${locationId}`);
      return locationId;
    },
    previousLocationId: 'fi',
    previousProfile,
    previousStatus: connectedStatus,
    reportConnect: (profile) => {
      calls.push(`reportConnect:${profile.locationId}`);
    },
    resolveProfile: async (locationId) => {
      calls.push(`resolve:${locationId}`);
      return targetProfile;
    },
    setCachedProfile: (locationId, profile) => {
      calls.push(`cache:${locationId}:${profile.locationId}`);
    },
    targetLocationId: 'de',
  });

  assertEqual(result.ok, false);
  if (!result.ok) {
    assertEqual(result.rollback, 'reconnected');
    assertEqual(result.profile?.locationId, 'fi');
  }
  assertDeepEqual(calls, [
    'resolve:de',
    'connect:de',
    'persist:fi',
    'cache:fi:fi',
    'connect:fi',
    'cache:fi:fi',
    'reportConnect:fi',
  ]);
}

async function testServerSwitchRefreshesProfileBeforeReplacingTunnel(): Promise<void> {
  const previousProfile = profileForLocation('fi', 'fi.example.com:51820');
  const cachedTargetProfile = profileForLocation('de', 'de-old.example.com:51820');
  const freshTargetProfile = profileForLocation('de', 'de.example.com:51820');
  const calls: string[] = [];

  const result = await switchVpnLocation({
    cachedTargetProfile,
    connectProfile: async (profile) => {
      calls.push(`connect:${profileEndpoint(profile)}`);
      if (profileEndpoint(profile) === 'de-old.example.com:51820') {
        throw new Error('handshake timeout');
      }
      return { profile, status: connectedStatus };
    },
    isRetryableConnectError: isVpnTransportFallbackError,
    persistLocation: async (locationId) => {
      calls.push(`persist:${locationId}`);
      return locationId;
    },
    previousLocationId: 'fi',
    previousProfile,
    previousStatus: connectedStatus,
    resolveProfile: async (locationId, options) => {
      calls.push(`resolve:${locationId}:${options.forceRefresh ? 'fresh' : 'cached'}`);
      return options.cachedProfile ?? freshTargetProfile;
    },
    setCachedProfile: (locationId, profile) => {
      calls.push(`cache:${locationId}:${profileEndpoint(profile)}`);
    },
    targetLocationId: 'de',
  });

  assertEqual(result.ok, true);
  if (result.ok) {
    assertEqual(profileEndpoint(result.profile), 'de.example.com:51820');
  }
  assertDeepEqual(calls, [
    'resolve:de:fresh',
    'connect:de.example.com:51820',
    'persist:de',
    'cache:de:de.example.com:51820',
  ]);
}

async function testRecoveryKeepsCurrentProfileWhenReconnectSucceeds(): Promise<void> {
  const activeProfile = profileForLocation('de', 'de.example.com:51820');
  const calls: string[] = [];

  const result = await recoverVpnConnection({
    activeLocationId: 'de',
    activeProfile,
    availableLocations: [locationCandidate('de'), locationCandidate('fi')],
    connectProfile: async (profile) => {
      calls.push(`connect:${profile.locationId}`);
      return { profile, status: connectedStatus };
    },
    isRetryableConnectError: isVpnTransportFallbackError,
    persistLocation: async (locationId) => {
      calls.push(`persist:${locationId}`);
      return locationId;
    },
    resolveProfile: async (locationId) => {
      calls.push(`resolve:${locationId}`);
      return profileForLocation(locationId, `${locationId}.example.com:51820`);
    },
    setCachedProfile: (locationId, profile) => {
      calls.push(`cache:${locationId}:${profile.locationId}`);
    },
  });

  assertEqual(result.ok, true);
  if (result.ok) {
    assertEqual(result.outcome, 'same_profile');
    assertEqual(result.locationId, 'de');
  }
  assertDeepEqual(calls, ['connect:de', 'cache:de:de']);
}

async function testRecoveryUsesFreshSameLocationProfile(): Promise<void> {
  const activeProfile = profileForLocation('de', 'de-old.example.com:51820');
  const freshProfile = profileForLocation('de', 'de.example.com:51820');
  const calls: string[] = [];

  const result = await recoverVpnConnection({
    activeLocationId: 'de',
    activeProfile,
    availableLocations: [locationCandidate('de'), locationCandidate('fi')],
    connectProfile: async (profile) => {
      calls.push(`connect:${profileEndpoint(profile)}`);
      if (profileEndpoint(profile) === 'de-old.example.com:51820') {
        throw new Error('handshake timeout');
      }
      return { profile, status: connectedStatus };
    },
    isRetryableConnectError: isVpnTransportFallbackError,
    persistLocation: async (locationId) => {
      calls.push(`persist:${locationId}`);
      return locationId;
    },
    resolveProfile: async (locationId, options) => {
      calls.push(`resolve:${locationId}:${options.forceRefresh ? 'fresh' : 'cached'}`);
      return freshProfile;
    },
    setCachedProfile: (locationId, profile) => {
      calls.push(`cache:${locationId}:${profileEndpoint(profile)}`);
    },
  });

  assertEqual(result.ok, true);
  if (result.ok) {
    assertEqual(result.outcome, 'same_location_fresh_profile');
    assertEqual(profileEndpoint(result.profile), 'de.example.com:51820');
  }
  assertDeepEqual(calls, [
    'connect:de-old.example.com:51820',
    'resolve:de:fresh',
    'connect:de.example.com:51820',
    'cache:de:de.example.com:51820',
  ]);
}

async function testRecoveryRotatesProfileForKeyOrProfileFailure(): Promise<void> {
  const activeProfile = profileForLocation('de', 'de-old.example.com:51820');
  const rotatedProfile = profileForLocation('de', 'de-new.example.com:51820');
  const calls: string[] = [];

  const result = await recoverVpnConnection({
    activeLocationId: 'de',
    activeProfile,
    availableLocations: [locationCandidate('de'), locationCandidate('fi')],
    connectProfile: async (profile) => {
      calls.push(`connect:${profileEndpoint(profile)}`);
      if (profileEndpoint(profile) === 'de-old.example.com:51820') {
        throw new Error('profile config invalid public key');
      }
      return { profile, status: connectedStatus };
    },
    isRetryableConnectError: isVpnTransportFallbackError,
    persistLocation: async (locationId) => {
      calls.push(`persist:${locationId}`);
      return locationId;
    },
    resolveProfile: async (locationId) => {
      calls.push(`resolve:${locationId}`);
      return profileForLocation(locationId, `${locationId}.example.com:51820`);
    },
    rotateProfile: async (profile, locationId) => {
      calls.push(`rotate:${locationId}:${profileEndpoint(profile)}`);
      return rotatedProfile;
    },
    setCachedProfile: (locationId, profile) => {
      calls.push(`cache:${locationId}:${profileEndpoint(profile)}`);
    },
  });

  assertEqual(result.ok, true);
  if (result.ok) {
    assertEqual(result.outcome, 'rotated_profile');
    assertEqual(profileEndpoint(result.profile), 'de-new.example.com:51820');
  }
  assertDeepEqual(calls, [
    'connect:de-old.example.com:51820',
    'rotate:de:de-old.example.com:51820',
    'connect:de-new.example.com:51820',
    'cache:de:de-new.example.com:51820',
  ]);
}

async function testRecoveryFailsOverToBestOtherLocation(): Promise<void> {
  const activeProfile = profileForLocation('de', 'de-old.example.com:51820');
  const freshProfile = profileForLocation('de', 'de.example.com:51820');
  const failoverProfile = profileForLocation('fi', 'fi.example.com:51820');
  const calls: string[] = [];

  const result = await recoverVpnConnection({
    activeLocationId: 'de',
    activeProfile,
    availableLocations: [
      locationCandidate('de', { latencyMs: 10 }),
      locationCandidate('nl', { latencyMs: 80 }),
      locationCandidate('fi', { latencyMs: 20 }),
    ],
    connectProfile: async (profile) => {
      calls.push(`connect:${profileEndpoint(profile)}`);
      if (profile.locationId === 'de') {
        throw new Error('handshake timeout');
      }
      return { profile, status: connectedStatus };
    },
    isRetryableConnectError: isVpnTransportFallbackError,
    persistLocation: async (locationId) => {
      calls.push(`persist:${locationId}`);
      return locationId;
    },
    resolveProfile: async (locationId, options) => {
      calls.push(`resolve:${locationId}:${options.forceRefresh ? 'fresh' : 'cached'}`);
      return locationId === 'fi' ? failoverProfile : freshProfile;
    },
    setCachedProfile: (locationId, profile) => {
      calls.push(`cache:${locationId}:${profileEndpoint(profile)}`);
    },
  });

  assertEqual(result.ok, true);
  if (result.ok) {
    assertEqual(result.outcome, 'failover_location');
    assertEqual(result.locationId, 'fi');
  }
  assertDeepEqual(calls, [
    'connect:de-old.example.com:51820',
    'resolve:de:fresh',
    'connect:de.example.com:51820',
    'resolve:fi:fresh',
    'connect:fi.example.com:51820',
    'persist:fi',
    'cache:fi:fi.example.com:51820',
  ]);
}

async function testRecoveryStopsOnNonRetryableError(): Promise<void> {
  const activeProfile = profileForLocation('de', 'de.example.com:51820');
  const calls: string[] = [];

  const result = await recoverVpnConnection({
    activeLocationId: 'de',
    activeProfile,
    availableLocations: [locationCandidate('de'), locationCandidate('fi')],
    connectProfile: async (profile) => {
      calls.push(`connect:${profile.locationId}`);
      throw new Error('Подписка не активна.');
    },
    isRetryableConnectError: isVpnTransportFallbackError,
    persistLocation: async (locationId) => {
      calls.push(`persist:${locationId}`);
      return locationId;
    },
    resolveProfile: async (locationId) => {
      calls.push(`resolve:${locationId}`);
      return profileForLocation(locationId, `${locationId}.example.com:51820`);
    },
    setCachedProfile: (locationId, profile) => {
      calls.push(`cache:${locationId}:${profile.locationId}`);
    },
  });

  assertEqual(result.ok, false);
  if (!result.ok) {
    assertEqual(result.outcome, 'failed');
    assertEqual(result.locationId, 'de');
  }
  assertDeepEqual(calls, ['connect:de']);
}

async function testRecoveryFailureDoesNotPersistNewLocation(): Promise<void> {
  const activeProfile = profileForLocation('de', 'de-old.example.com:51820');
  const calls: string[] = [];

  const result = await recoverVpnConnection({
    activeLocationId: 'de',
    activeProfile,
    availableLocations: [
      locationCandidate('de', { latencyMs: 10 }),
      locationCandidate('fi', { latencyMs: 20 }),
    ],
    connectProfile: async (profile) => {
      calls.push(`connect:${profileEndpoint(profile)}`);
      throw new Error('handshake timeout');
    },
    isRetryableConnectError: isVpnTransportFallbackError,
    persistLocation: async (locationId) => {
      calls.push(`persist:${locationId}`);
      return locationId;
    },
    resolveProfile: async (locationId, options) => {
      calls.push(`resolve:${locationId}:${options.forceRefresh ? 'fresh' : 'cached'}`);
      return profileForLocation(locationId, `${locationId}.example.com:51820`);
    },
    setCachedProfile: (locationId, profile) => {
      calls.push(`cache:${locationId}:${profileEndpoint(profile)}`);
    },
  });

  assertEqual(result.ok, false);
  if (!result.ok) {
    assertEqual(result.outcome, 'failed');
    assertEqual(result.locationId, 'de');
  }
  assertDeepEqual(calls, [
    'connect:de-old.example.com:51820',
    'resolve:de:fresh',
    'connect:de.example.com:51820',
    'resolve:fi:fresh',
    'connect:fi.example.com:51820',
  ]);
}

function profileForLocation(locationId: string, endpoint: string): VpnProfile {
  return {
    ...profileWithEndpoint(endpoint),
    locationId,
  };
}

function locationCandidate(id: string, overrides: Partial<VpnLocation> = {}): VpnLocation {
  return {
    id,
    countryCode: id.toUpperCase(),
    city: id.toUpperCase(),
    availability: 'available',
    status: 'healthy',
    healthyNodes: 1,
    ...overrides,
  };
}

function billingPlanCandidates(): BillingPlanSource[] {
  return [
    {
      id: 'pro-monthly',
      amount_cents: 99000,
      currency: 'RUB',
      device_limit: 3,
      interval: 'month',
      status: 'active',
      tier: 'pro',
    },
    {
      id: 'team-monthly',
      amount_cents: 199000,
      currency: 'RUB',
      device_limit: 10,
      interval: 'month',
      status: 'active',
      tier: 'team',
    },
    {
      id: 'legacy-monthly',
      amount_cents: 49000,
      currency: 'RUB',
      device_limit: 1,
      interval: 'month',
      status: 'archived',
      tier: 'legacy',
    },
  ];
}

function memoryWebStorage(initial: Record<string, string> = {}): WebStorageAdapter {
  const values = new Map(Object.entries(initial));
  return {
    getItem: (key) => values.get(key) ?? null,
    setItem: (key, value) => {
      values.set(key, value);
    },
    deleteItem: (key) => {
      values.delete(key);
    },
  };
}

function tauriSensitiveStorageInvoke(values: Map<string, string>, calls: string[] = []): TauriInvoke {
  return async <T>(command: string, args?: Record<string, unknown>): Promise<T> => {
    const key = String(args?.key ?? '');
    if (command === 'secure_storage_get') {
      calls.push(`get:${key}`);
      return (values.get(key) ?? null) as T;
    }
    if (command === 'secure_storage_set') {
      calls.push(`set:${key}`);
      values.set(key, String(args?.value ?? ''));
      return true as T;
    }
    if (command === 'secure_storage_delete') {
      calls.push(`delete:${key}`);
      values.delete(key);
      return true as T;
    }
    throw new Error(`unexpected command: ${command}`);
  };
}

function deviceCandidate(overrides: Partial<VpnLocationDevice> = {}): VpnLocationDevice {
  return {
    ...overrides,
  };
}

function vpnDeviceCandidate(overrides: Partial<VpnDevice> = {}): VpnDevice {
  return {
    id: 'dev_1',
    name: 'Device',
    status: 'active',
    protocol: 'amneziawg',
    provisioningMode: 'managed_native',
    ...overrides,
  };
}

function vpnDeviceUsageCandidate(overrides: Partial<VpnDeviceUsage> = {}): VpnDeviceUsage {
  return {
    deviceId: 'dev_1',
    connectionStatus: 'connected',
    connected: true,
    rxBytes: 100,
    totalBytes: 300,
    txBytes: 200,
    ...overrides,
  };
}

function authSessionCandidate() {
  return {
    accessToken: 'token',
    user: {
      email: 'user@example.com',
      id: 'user_1',
      status: 'active',
    },
  };
}

function appUpdateCandidate() {
  return {
    updateAvailable: true,
    required: false,
    latestVersion: '1.0.47',
    latestBuild: 1004748,
    minSupportedBuild: 1004300,
    downloadUrl: 'https://vexguard.app/downloads/VEX-Android.apk',
    checksumSha256: 'a'.repeat(64),
    signatureUrl: 'https://vexguard.app/downloads/VEX-Android.apk.sig',
  };
}

function assertEqual<T>(actual: T, expected: T): void {
  if (actual !== expected) {
    throw new Error(`Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

function assertDeepEqual<T>(actual: T, expected: T): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

async function assertRejects(fn: () => Promise<unknown>, expectedMessage: string): Promise<void> {
  try {
    await fn();
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (!message.includes(expectedMessage)) {
      throw new Error(`Expected rejection containing ${JSON.stringify(expectedMessage)}, got ${JSON.stringify(message)}`);
    }
    return;
  }
  throw new Error(`Expected rejection containing ${JSON.stringify(expectedMessage)}`);
}
async function runPkceTests(): Promise<void> {
  const verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
  const expectedChallenge = 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM';
  const challenge = await generateChallenge(verifier);
  assertEqual(challenge, expectedChallenge);

  const rand = generateRandomString(32);
  assertEqual(rand.length, 32);
  assertEqual(typeof rand, 'string');

  const authUrl = buildAppWebAuthUrl({
    baseUrl: 'https://vexguard.app/',
    challenge: 'challenge',
    deviceId: 'device-1',
    deviceName: 'Android',
    platform: 'android',
    state: 'state-1',
  });
  assertEqual(authUrl.includes('code_challenge=challenge'), true);
  assertEqual(authUrl.includes('state=state-1'), true);
  assertEqual(authUrl.includes('code_verifier='), false);

  assertDeepEqual(
    resolveAuthCallbackExchange({ code: 'code-1', state: 'state-1' }, 'state-1', 'verifier-1'),
    { code: 'code-1', verifier: 'verifier-1' },
  );
  await assertRejects(
    async () => resolveAuthCallbackExchange({ code: 'code-1', state: 'attacker-state' }, 'state-1', 'verifier-1'),
    'Проверка безопасности входа',
  );
  await assertRejects(
    async () => resolveAuthCallbackExchange({ code: 'code-1', state: 'state-1' }, 'state-1', null),
    'Сессия входа устарела',
  );
}

async function runManualUpdateInstallTests(): Promise<void> {
  const calls: string[] = [];
  const update = appUpdateCandidate();
  const result = await installManualUpdate(update, 'android', {
    downloadAndroidUpdateApk: async (downloadUrl, checksumSha256) => {
      calls.push(`download:${downloadUrl}:${checksumSha256}`);
      return { filePath: '/tmp/VEX.apk', sizeBytes: 123, checksumSha256: checksumSha256 || undefined };
    },
    installAndroidUpdateApk: async (filePath) => {
      calls.push(`install:${filePath}`);
      return { status: 'installer_started' };
    },
    openUrl: async (url) => {
      calls.push(`open:${url}`);
    },
  });

  assertDeepEqual(calls, [
    `download:${update.downloadUrl}:${update.checksumSha256}`,
    'install:/tmp/VEX.apk',
  ]);
  assertDeepEqual(result, { status: 'installer_started' });
  await assertRejects(
    () => installManualUpdate({ ...update, checksumSha256: undefined }, 'android', {}),
    'SHA-256',
  );

  assertEqual(isTrustedIosUpdateUrl('https://apps.apple.com/app/vex/id123'), true);
  assertEqual(isTrustedIosUpdateUrl('https://testflight.apple.com/join/abc'), true);
  assertEqual(isTrustedIosUpdateUrl('https://vexguard.app/downloads/VEX.ipa'), false);
  const iosCalls: string[] = [];
  await installManualUpdate({ ...update, downloadUrl: 'https://apps.apple.com/app/vex/id123' }, 'ios', {
    openUrl: async (url) => {
      iosCalls.push(url);
    },
  });
  assertDeepEqual(iosCalls, ['https://apps.apple.com/app/vex/id123']);
}

function runSupportTests(): void {
  assertEqual(isSupportSocketConnecting({ readyState: 0 }, undefined), true);
  assertEqual(isSupportSocketConnecting({ readyState: 1 }, undefined), false);
  assertEqual(isSupportSocketConnecting(
    { readyState: 7 as WebSocket['readyState'] },
    { CONNECTING: 7 as typeof WebSocket.CONNECTING },
  ), true);
  assertEqual(supportConnectionStatusText('reconnecting'), 'обновляем чат...');
  assertEqual(supportConnectionStatusText('offline'), 'нужен вход');
  assertEqual(
    supportHistoryErrorMessage(
      'fetch failed: java.net.UnknownHostException: Unable to resolve host "vexguard.app": No address associated with hostname',
    ),
    'Нет соединения с сервером VEX. Проверьте интернет или отключите VPN и попробуйте снова.',
  );

  const t1 = optimisticSupportTicket('Payment Issue', 'I paid but it says expired.');
  assertEqual(t1.subject, 'Payment Issue');
  assertEqual(t1.status, 'open');
  assertEqual(t1.messages?.[0]?.body, 'I paid but it says expired.');

  const now = new Date().toISOString();
  const m1: SupportMessage = { id: 'm1', ticketId: 't1', sender: 'user', body: 'hello', createdAt: now };
  const m2: SupportMessage = { id: 'm2', ticketId: 't1', sender: 'user', body: 'hello', createdAt: now };
  const unique = uniqueSupportMessages([m1, m2]);
  assertEqual(unique.length, 1);

  const diagMsg1: SupportMessage = { id: 'd1', ticketId: 't1', sender: 'user', body: 'generated_at: 2026\ncheck.dns: ok\nstatus: connected', createdAt: now };
  const diagMsg2: SupportMessage = { id: 'd2', ticketId: 't1', sender: 'user', body: 'generated_at: 2026\ncheck.dns: fail\nstatus: disconnected', createdAt: now };
  const chatItemsList = supportChatItems([diagMsg1, diagMsg2]);
  assertEqual(chatItemsList.length, 1);
  assertEqual(chatItemsList[0].type, 'diagnosticGroup');
}

function runNavigationRouteTests(): void {
  assertEqual(HOME_TAB_ROUTE, '/(app)/(tabs)/');
  assertEqual(SUPPORT_TAB_ROUTE, '/(app)/(tabs)/support');
  assertEqual(HOME_TAB_ROUTE.includes('/index'), false);
  assertEqual(SUPPORT_TAB_ROUTE.includes('support-chat'), false);
}

function runErrorMessageTests(): void {
  assertEqual(errorMessage(new Error('Test message'), 'fallback'), 'Test message');
  assertEqual(errorMessage('String message', 'fallback'), 'String message');
  assertEqual(errorMessage(''), '');
  assertEqual(errorMessage('', 'fallback'), 'fallback');
  assertEqual(errorMessage(null, 'fallback'), 'fallback');
  assertEqual(errorMessage(undefined, 'fallback'), 'fallback');
  assertEqual(errorMessage({}), '');
  assertEqual(errorMessage(new Error('Another Test')), 'Another Test');
  assertEqual(errorMessage(null), '');
  assertEqual(normalizeApiRequestError(new Error('Network request failed')).message, technicalWorksMessage);
  assertEqual(normalizeApiRequestError(new Error('Превышено время ожидания API.')).message, technicalWorksMessage);
  assertEqual(normalizeApiRequestError(new Error('regular failure')).message, 'regular failure');
  assertEqual(isKeyEpochMismatchError(new Error('key_epoch does not match next device epoch')), true);
  assertEqual(isKeyEpochMismatchError(new Error('network request failed')), false);
  assertEqual(nextManagedKeyEpoch(2, 5), 6);
  assertEqual(nextManagedKeyEpoch(8, 5), 6);
  assertEqual(nextManagedKeyEpoch(undefined, undefined), 1);
  assertEqual(isCurrentSessionMutation(2, 2, 'token-a', 'token-a'), true);
  assertEqual(isCurrentSessionMutation(2, 3, 'token-a', 'token-a'), false);
  assertEqual(isCurrentSessionMutation(2, 2, 'token-a', 'token-b'), false);
}
