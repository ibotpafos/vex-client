// Keep SDK-default/global instrumentation. The explicit legacy RN opt-out lacks
// manual redirects and streaming, so select the installed Expo API only there.
export async function apiFetch(url: string, init: RequestInit): Promise<Response> {
  const options = { ...init, redirect: 'manual' as const };
  if (process.env.EXPO_PUBLIC_USE_RN_FETCH === '1' || process.env.EXPO_PUBLIC_USE_RN_FETCH === 'true') {
    const { Platform } = await import('react-native');
    if (Platform.OS !== 'web') {
      const { fetch: expoFetch } = await import('expo/fetch');
      return expoFetch(url, options);
    }
  }
  return fetch(url, options);
}
