import { VEX_API_CLIENT_VERSION, VEX_CONFIG_SCHEMA_VERSION } from '@/native/appInfo';
import { jsonRequest, vexApiBaseUrl, absolutizeUrl } from './client';
import { validateManualUpdatePayloadForBaseUrl } from './updatePreflight';
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
}): Promise<AppUpdateCheckResult> {
  const { timeoutMs, ...requestBody } = input;
  const item = await jsonRequest<AppUpdateCheckResponseDTO>('/v1/app/update/check', {
    method: 'POST',
    suppressErrorLog: true,
    timeout: timeoutMs,
    body: {
      ...requestBody,
      apiClientVersion: input.apiClientVersion ?? VEX_API_CLIENT_VERSION,
      configSchemaVersion: input.configSchemaVersion ?? VEX_CONFIG_SCHEMA_VERSION,
    },
  });
  return {
    updateAvailable: Boolean(item.updateAvailable),
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
  const item = await jsonRequest<AppRemoteConfigResponseDTO>('/v1/app/remote-config', {
    method: 'POST',
    body: {
      ...input,
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
