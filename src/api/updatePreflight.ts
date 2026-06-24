export type ManualUpdatePreflightResult = {
  ok: boolean;
  error?: string;
};

export type ManualUpdateCenterInput = {
  update?: {
    updateAvailable: boolean;
    required: boolean;
    currentBuildBlocked?: boolean;
    latestVersion?: string;
    latestBuild?: number;
    minSupportedBuild?: number;
    minConfigSchemaVersion?: number;
    downloadUrl?: string | null;
    checksumSha256?: string | null;
    signatureUrl?: string | null;
    channel?: string;
    reason?: string;
    changelog?: string;
  } | null;
  currentVersion: string;
  currentBuild: number;
  trustedBaseUrl: string;
};

export type ManualUpdateCenterAssessment = {
  title: string;
  message: string;
  actionLabel: string;
  compatibilityLabel: string;
  compatibilityTone: 'ok' | 'warning' | 'danger';
  signatureLabel: string;
  signatureTone: 'ok' | 'warning' | 'danger';
  canInstall: boolean;
  required: boolean;
  updateAvailable: boolean;
  currentBuildBlocked: boolean;
  preflight: ManualUpdatePreflightResult;
};

export function validateManualUpdatePayloadForBaseUrl(input: {
  downloadUrl?: string | null;
  checksumSha256?: string | null;
  signatureUrl?: string | null;
}, trustedBaseUrl: string): ManualUpdatePreflightResult {
  const downloadUrl = input.downloadUrl?.trim() || '';
  if (!downloadUrl) {
    return { ok: false, error: 'Ссылка на обновление не настроена.' };
  }
  if (!isTrustedUpdateUrl(downloadUrl, trustedBaseUrl)) {
    return { ok: false, error: 'Ссылка на обновление указывает на недоверенный источник.' };
  }

  const checksumSha256 = input.checksumSha256?.trim() || '';
  if (!/^[a-f0-9]{64}$/i.test(checksumSha256)) {
    return { ok: false, error: 'Для обновления не настроен корректный SHA-256 checksum.' };
  }

  const signatureUrl = input.signatureUrl?.trim() || '';
  if (!signatureUrl) {
    return { ok: false, error: 'Для обновления не настроена ссылка на подпись.' };
  }
  if (!isTrustedUpdateUrl(signatureUrl, trustedBaseUrl)) {
    return { ok: false, error: 'Подпись обновления указывает на недоверенный источник.' };
  }

  return { ok: true };
}

export function updateCheckChannel(channel: string): string {
  const normalized = channel.trim().toLowerCase();
  if (normalized === 'production' || normalized === 'local' || normalized === 'test') {
    return 'stable';
  }
  return normalized || 'stable';
}

export function assessManualUpdateCenter(input: ManualUpdateCenterInput): ManualUpdateCenterAssessment {
  const update = input.update ?? null;
  const updateAvailable = Boolean(update?.updateAvailable);
  const required = Boolean(update?.required);
  const currentBuildBlocked = Boolean(update?.currentBuildBlocked);
  const preflight = updateAvailable
    ? validateManualUpdatePayloadForBaseUrl({
      checksumSha256: update?.checksumSha256,
      downloadUrl: update?.downloadUrl,
      signatureUrl: update?.signatureUrl,
    }, input.trustedBaseUrl)
    : { ok: false, error: 'Обновление не требуется.' };
  const reason = updateReason(update);
  const signatureLabel = signatureStatusLabel(update, preflight);
  const signatureTone = preflight.ok ? 'ok' : updateAvailable ? 'danger' : 'warning';
  const compatibility = compatibilityCopy(reason, required, currentBuildBlocked, updateAvailable);

  return {
    title: updateCenterTitle(reason, required, currentBuildBlocked, updateAvailable),
    message: updateCenterMessage(reason, required, currentBuildBlocked, updateAvailable),
    actionLabel: reason === 'android_signing_key_migration' ? 'Скачать новую сборку' : currentBuildBlocked ? 'Вернуться на стабильную' : required ? 'Обновить сейчас' : updateAvailable ? 'Установить обновление' : 'Проверить снова',
    compatibilityLabel: compatibility.label,
    compatibilityTone: compatibility.tone,
    signatureLabel,
    signatureTone,
    canInstall: updateAvailable && preflight.ok,
    required,
    updateAvailable,
    currentBuildBlocked,
    preflight,
  };
}

function updateCenterTitle(reason: string, required: boolean, currentBuildBlocked: boolean, updateAvailable: boolean): string {
  if (currentBuildBlocked || reason === 'blocked_release') {
    return 'Сборка отозвана';
  }
  if (reason === 'android_signing_key_migration') {
    return 'Новая Android-сборка VEX';
  }
  if (required) {
    return 'Нужно обновить VEX';
  }
  if (updateAvailable) {
    return 'Доступно обновление';
  }
  return 'VEX обновлен';
}

function updateCenterMessage(reason: string, required: boolean, currentBuildBlocked: boolean, updateAvailable: boolean): string {
  if (currentBuildBlocked || reason === 'blocked_release') {
    return 'Эта сборка заблокирована. Установите предложенную стабильную версию, чтобы вернуться на поддерживаемый канал.';
  }
  if (reason === 'android_signing_key_migration') {
    return 'Мы выпустили новую Android-сборку с обновленной подписью. Установите ее как новое приложение, войдите в аккаунт и после проверки доступа удалите старый VEX.';
  }
  if (reason === 'unsupported_config_schema') {
    return 'Текущий клиент несовместим с новым форматом конфигурации. Обновление обязательно перед выдачей VPN-профиля.';
  }
  if (reason === 'core_version_unsupported') {
    return 'Ядро клиента больше не поддерживается текущей серверной политикой.';
  }
  if (reason === 'api_client_version_unsupported') {
    return 'API-клиент устарел. Обновление нужно для совместимости с сервером.';
  }
  if (required) {
    return 'Эта версия больше не поддерживается. Установите новую сборку, чтобы продолжить пользоваться сервисом.';
  }
  if (updateAvailable) {
    return 'Новая версия прошла проверку метаданных и готова к установке.';
  }
  return 'Установленная версия совместима с текущим серверным контрактом.';
}

function compatibilityCopy(
  reason: string,
  required: boolean,
  currentBuildBlocked: boolean,
  updateAvailable: boolean,
): { label: string; tone: ManualUpdateCenterAssessment['compatibilityTone'] } {
  if (currentBuildBlocked || reason === 'blocked_release') {
    return { label: 'Сборка заблокирована, нужен rollback', tone: 'danger' };
  }
  if (reason === 'android_signing_key_migration') {
    return { label: 'Нужна миграция на новую Android-сборку', tone: 'danger' };
  }
  if (reason === 'unsupported_config_schema') {
    return { label: 'Несовместимая схема конфигурации', tone: 'danger' };
  }
  if (reason === 'core_version_unsupported') {
    return { label: 'Ядро клиента устарело', tone: 'danger' };
  }
  if (reason === 'api_client_version_unsupported') {
    return { label: 'API-клиент устарел', tone: 'danger' };
  }
  if (required) {
    return { label: 'Текущая версия не поддерживается', tone: 'danger' };
  }
  if (updateAvailable) {
    return { label: 'Совместимо, доступна новая версия', tone: 'warning' };
  }
  return { label: 'Совместимо', tone: 'ok' };
}

function signatureStatusLabel(
  update: ManualUpdateCenterInput['update'],
  preflight: ManualUpdatePreflightResult,
): string {
  if (!update?.updateAvailable) {
    return 'Не требуется';
  }
  if (preflight.ok) {
    return 'Checksum и подпись настроены';
  }
  return preflight.error || 'Метаданные подписи неполные';
}

function isTrustedUpdateUrl(value: string, trustedBaseUrl: string): boolean {
  try {
    const candidate = new URL(value);
    const trustedBase = new URL(trustedBaseUrl);
    return candidate.protocol === 'https:' && candidate.host === trustedBase.host;
  } catch {
    return false;
  }
}

function updateReason(update: ManualUpdateCenterInput['update']): string {
  const explicitReason = update?.reason || '';
  const changelog = update?.changelog?.toLowerCase() || '';
  if (changelog.includes('android-signing-key-migration')) {
    return 'android_signing_key_migration';
  }
  return explicitReason;
}
