import fs from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
const read = path => stripTypeScriptTypes(fs.readFileSync(path, 'utf8'))
  .replace(/^import .*;$/gm, '').replace(/^export \{.*;$/gm, '').replace(/\bexport /g, '');
const source = read('src/api/origins.ts') + read('src/api/error.ts') + read('src/api/client.ts');
export function client(fetch, { env = {}, platform = 'web', native = {}, expoFetch = fetch, appInfo = async () => ({}) } = {}) {
  return new Function('expoFetch', 'fetch', 'process', 'Platform', 'NativeModules', 'getAppInfo', 'getOrCreateDeviceId',
    'androidExperimentalRoutingEnabled', 'androidProfilePlatform', source + '; return {rawRequest, withProfileRecoveryTransport, vexApiBaseUrl, realtimeApiBaseUrl, resolveApiOrigins, apiRequestUrl};')(
    expoFetch, fetch, { env }, { OS: platform }, { VexVpn: native }, appInfo, async () => 'fixture', () => false, () => platform);
}
export const settle = async () => { for (let i = 0; i < 60; i++) await Promise.resolve(); };
export const ok = (text = 'ok') => ({ ok: true, status: 200, text: async () => text });
export const failure = (status, code) => ({ ok: false, status, headers: {get: () => null}, text: async () => JSON.stringify({ code }) });
export const primary = 'https://api.vexguard.app';
export const fallback = 'https://api2.vexguard.app';
