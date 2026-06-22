import { jsonRequest } from './client';
import {
  type AuthSession,
  type User,
  type ServerAuthResult,
  type ServerUser,
} from './types';

export async function login(email: string, password: string): Promise<AuthSession> {
  return parseAuth(await jsonRequest<ServerAuthResult>('/v1/auth/login', {
    method: 'POST',
    body: { email, password, remember_me: true, device_session: true },
  }));
}

export async function exchangeAppAuthCode(code: string, codeVerifier: string): Promise<AuthSession> {
  return parseAuth(await jsonRequest<ServerAuthResult>('/v1/auth/token', {
    method: 'POST',
    body: {
      code,
      code_verifier: codeVerifier,
    },
  }));
}

export async function me(accessToken: string): Promise<User> {
  const user = await jsonRequest<ServerUser>('/v1/auth/me', { accessToken });
  return parseUser(user);
}

export async function refreshSession(accessToken: string): Promise<AuthSession> {
  return parseAuth(await jsonRequest<ServerAuthResult>('/v1/auth/refresh', {
    method: 'POST',
    accessToken,
    suppressErrorLog: true,
  }));
}

export function parseAuth(item: ServerAuthResult): AuthSession {
  return {
    user: parseUser(item.user),
    accessToken: item.session.access_token,
    expiresAt: item.session.expires_at || undefined,
  };
}

export function parseUser(item: ServerUser): User {
  return {
    id: item.id,
    email: item.email,
    status: item.status ?? '',
  };
}
