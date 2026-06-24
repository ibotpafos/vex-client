export type AppWebAuthUrlInput = {
  baseUrl: string;
  challenge: string;
  deviceId: string;
  deviceName: string;
  platform: string;
  state: string;
};

export function buildAppWebAuthUrl(input: AppWebAuthUrlInput): string {
  return `${trimTrailingSlash(input.baseUrl)}/auth/app?${new URLSearchParams({
    client_id: 'vex_app',
    code_challenge: input.challenge,
    state: input.state,
    device_id: input.deviceId,
    device_name: input.deviceName,
    platform: input.platform,
  }).toString()}`;
}

function trimTrailingSlash(value: string): string {
  return value.replace(/\/+$/, '');
}
