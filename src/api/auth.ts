import { jsonRequest } from './client';
import {
  type AuthSession,
  type User,
} from './types';
import {
  type AuthResultDTO,
  type EmailOTPChallengeDTO,
  type UserDTO,
} from './dto';

export async function login(email: string, password: string): Promise<AuthSession> {
  return parseAuth(await jsonRequest<AuthResultDTO>('/v1/auth/login', {
    method: 'POST',
    body: { email, password, remember_me: true, device_session: true },
  }));
}

export type EmailOTPChallenge = {
  challengeId: string;
  expiresAt?: string;
};

export async function requestEmailOTP(email: string): Promise<EmailOTPChallenge> {
  const challenge = await jsonRequest<EmailOTPChallengeDTO>('/v1/auth/email-otp/request', {
    method: 'POST',
    body: { email },
  });
  return {
    challengeId: challenge.challenge_id,
    expiresAt: challenge.expires_at,
  };
}

export async function confirmEmailOTP(email: string, challengeId: string, code: string): Promise<AuthSession> {
  return parseAuth(await jsonRequest<AuthResultDTO>('/v1/auth/email-otp/confirm', {
    method: 'POST',
    body: {
      email,
      challenge_id: challengeId,
      code,
      remember_me: true,
      device_session: true,
    },
  }));
}

export async function exchangeAppAuthCode(code: string, codeVerifier: string): Promise<AuthSession> {
  return parseAuth(await jsonRequest<AuthResultDTO>('/v1/auth/token', {
    method: 'POST',
    body: {
      code,
      code_verifier: codeVerifier,
    },
  }));
}

export async function me(accessToken: string): Promise<User> {
  const user = await jsonRequest<UserDTO>('/v1/auth/me', { accessToken });
  return parseUser(user);
}

export async function refreshSession(accessToken: string): Promise<AuthSession> {
  return parseAuth(await jsonRequest<AuthResultDTO>('/v1/auth/refresh', {
    method: 'POST',
    accessToken,
    suppressErrorLog: true,
  }));
}

export function parseAuth(item: AuthResultDTO): AuthSession {
  return {
    user: parseUser(item.user),
    accessToken: item.session.access_token,
    expiresAt: item.session.expires_at || undefined,
  };
}

export function parseUser(item: UserDTO): User {
  return {
    id: item.id,
    email: item.email,
    status: item.status ?? '',
  };
}
