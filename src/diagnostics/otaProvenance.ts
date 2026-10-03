import * as Updates from 'expo-updates';

export type OtaProvenance = {
  ota_update_id?: string;
  ota_runtime_version?: string;
  ota_is_embedded_launch: boolean;
  ota_is_emergency_launch: boolean;
};

const updateIdPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
// VEX's configured default is a release semver. A SHA-256/1 fingerprint is
// also safe when Expo's fingerprint runtime-version policy is adopted.
const runtimeVersionPattern = /^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z.-]{1,64})?$|^[a-f0-9]{40}(?:[a-f0-9]{24})?$/;
const maxRuntimeVersionLength = 96;

/**
 * Small, non-identifying launch provenance for correlating an authenticated
 * diagnostic with an Expo OTA rollback. The native emergency reason is never
 * returned because it can contain sensitive operational detail.
 */
export function getOtaProvenance(): OtaProvenance {
  const isEmergencyLaunch = Updates.isEmergencyLaunch === true;
  const updateId = boundedUpdateId(Updates.updateId);
  const runtimeVersion = boundedRuntimeVersion(Updates.runtimeVersion);

  return {
    ...(updateId ? { ota_update_id: updateId } : {}),
    ...(runtimeVersion ? { ota_runtime_version: runtimeVersion } : {}),
    ota_is_embedded_launch: Updates.isEmbeddedLaunch === true,
    ota_is_emergency_launch: isEmergencyLaunch,
  };
}

function boundedUpdateId(value: string | null): string | undefined {
  return typeof value === 'string' && updateIdPattern.test(value) ? value : undefined;
}

function boundedRuntimeVersion(value: string | null): string | undefined {
  if (typeof value !== 'string') return undefined;
  const trimmed = value.trim();
  return trimmed.length <= maxRuntimeVersionLength && runtimeVersionPattern.test(trimmed) ? trimmed : undefined;
}
