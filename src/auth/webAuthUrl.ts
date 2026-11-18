import { apiRequestUrl } from '../api/config';

export type AppWebAuthUrlInput = {
  baseUrl: string;
  challenge: string;
  deviceId: string;
  deviceName: string;
  platform: string;
  state: string;
  provider?: 'google';
};

export function buildAppWebAuthUrl(input: AppWebAuthUrlInput): string {
  return apiRequestUrl(`/auth/app?${new URLSearchParams({
    client_id: 'vex_app',
    code_challenge: input.challenge,
    state: input.state,
    device_id: input.deviceId,
    device_name: input.deviceName,
    platform: input.platform,
    ...(input.provider ? { provider: input.provider } : {}),
  }).toString()}`, input.baseUrl);
}
