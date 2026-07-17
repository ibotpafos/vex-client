export const devicePushTokenPath = '/v1/vpn/push-token';

export type FcmPushRegistration = {
  provider: 'fcm';
  token: string;
};

export function fcmPushRegistration(token: string): FcmPushRegistration | null {
  const normalizedToken = token.trim();
  return normalizedToken ? { provider: 'fcm', token: normalizedToken } : null;
}
