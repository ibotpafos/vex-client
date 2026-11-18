import realSourceLoader from './real-source-loader.cjs';
export function client(fetch, options = {}) {
  const load = realSourceLoader({ fetch, ...options });
  return { ...load('@/api/client'), ...load('@/api/config') };
}
export const settle = async () => { for (let i = 0; i < 60; i++) await Promise.resolve(); };
export const ok = (text = 'ok') => ({ ok: true, status: 200, text: async () => text });
export const failure = (status, code) => ({ ok: false, status, headers: {get: () => null}, text: async () => JSON.stringify({ code }) });
export const primary = 'https://api.vexguard.app';
export const fallback = 'https://api2.vexguard.app';
