import { VEX_API_CLIENT_VERSION, VEX_CONFIG_SCHEMA_VERSION } from '@/native/appInfo';
import { jsonRequest, vexApiBaseUrl, absolutizeUrl } from './client';
import { normalizeUpdateCheckVersion, validateManualUpdatePayloadForBaseUrl } from './updatePreflight';
import {
  type AppUpdateCheckResult,
  type AppRemoteConfig,
  type ManualUpdatePreflightResult,
} from './types';
import {
  type AppRemoteConfigResponseDTO,
  type AppUpdateCheckResponseDTO,
} from './dto';

export async function appUpdateCheck(input: {
  accessToken?: string;
  platform: string;
  appVersion: string;
  buildNumber: number;
  channel?: string;
  coreVersion?: string;
  deviceId?: string;
  osVersion?: string;
  arch?: string;
  apiClientVersion?: string;
  configSchemaVersion?: number;
  timeoutMs?: number;
  signal?: AbortSignal;
}): Promise<AppUpdateCheckResult> {
  const { timeoutMs, accessToken, signal, ...requestBody } = input;
  const appVersion = normalizeUpdateCheckVersion(input.appVersion);
  const item = await jsonRequest<AppUpdateCheckResponseDTO>('/v1/app/update/check', {
    method: 'POST',
    accessToken,
    suppressErrorLog: true,
    timeout: timeoutMs,
    ...(signal ? { signal } : {}),
    headers: { 'X-Vex-App-Version': appVersion, 'X-Vex-Account-Updates': '1' },
    body: {
      ...requestBody,
      appVersion,
      apiClientVersion: input.apiClientVersion ?? VEX_API_CLIENT_VERSION,
      configSchemaVersion: input.configSchemaVersion ?? VEX_CONFIG_SCHEMA_VERSION,
    },
  });
  return {
    updateAvailable: Boolean(item.updateAvailable),
    delivery: item.delivery,
    required: Boolean(item.required),
    currentBuildBlocked: Boolean(item.currentBuildBlocked),
    latestVersion: item.latestVersion || '',
    latestBuild: item.latestBuild ?? 0,
    minSupportedBuild: item.minSupportedBuild ?? 0,
    minConfigSchemaVersion: item.minConfigSchemaVersion ?? undefined,
    downloadUrl: absolutizeUrl(item.downloadUrl || ''),
    changelog: item.changelog || undefined,
    checksumSha256: item.checksumSha256 || undefined,
    signatureUrl: absolutizeUrl(item.signatureUrl || ''),
    channel: item.channel || undefined,
    reason: item.reason || undefined,
    rolloutPercent: item.rolloutPercent ?? undefined,
    checkedAt: item.checkedAt || undefined,
  };
}

export async function appRemoteConfig(input: {
  accessToken?: string;
  platform: string;
  appVersion: string;
  buildNumber: number;
  channel?: string;
  coreVersion?: string;
  deviceId?: string;
  osVersion?: string;
  arch?: string;
  apiClientVersion?: string;
  configSchemaVersion?: number;
}): Promise<AppRemoteConfig> {
  const { accessToken, ...requestBody } = input;
  const item = await jsonRequest<AppRemoteConfigResponseDTO>('/v1/app/remote-config', {
    method: 'POST',
    accessToken,
    headers: { 'X-Vex-Account-Updates': '1' },
    body: {
      ...requestBody,
      apiClientVersion: input.apiClientVersion ?? VEX_API_CLIENT_VERSION,
      configSchemaVersion: input.configSchemaVersion ?? VEX_CONFIG_SCHEMA_VERSION,
    },
  });
  return {
    version: item.version || undefined,
    signature: item.signature || undefined,
    releasedAt: item.releasedAt || undefined,
    platform: item.platform || input.platform,
    channel: item.channel || input.channel || 'stable',
    minSupportedBuild: item.minSupportedBuild ?? 0,
    recommendedBuild: item.recommendedBuild ?? 0,
    recommendedVersion: item.recommendedVersion || undefined,
    coreVersion: item.coreVersion || undefined,
    configSchemaVersion: item.configSchemaVersion ?? 0,
    minConfigSchemaVersion: item.minConfigSchemaVersion ?? 0,
    routingPolicyVersion: item.routingPolicyVersion || undefined,
    featureFlags: item.featureFlags ?? {},
    accountFeatureFlags: item.accountFeatureFlags ?? {},
    incidentBanner: item.incidentBanner || undefined,
  };
}

export function validateManualUpdatePayload(input: {
  downloadUrl?: string | null;
  checksumSha256?: string | null;
  signatureUrl?: string | null;
}): ManualUpdatePreflightResult {
  return validateManualUpdatePayloadForBaseUrl(input, vexApiBaseUrl);
}
