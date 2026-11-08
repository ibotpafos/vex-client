import { useMemo, useSyncExternalStore } from 'react';
import { AppState, Platform } from 'react-native';
import { appRemoteConfig } from '@/api/vexApi';
import { useSession } from '@/auth/session-context';
import { getAppInfo } from '@/native/appInfo';
import { createRemoteConfigStore } from './remote-config-store';
import { createIndependentStatusStore, readIndependentServiceStatus } from './independent-service-status';
import { projectServiceNotice } from './service-notice-state';

// This anonymous observer is deliberately shared across accounts and screens.
const independentStore = createIndependentStatusStore(() => readIndependentServiceStatus(), {
  foreground(callback) {
    const subscription = AppState.addEventListener('change', (state) => {
      if (state === 'active') callback();
    });
    return () => subscription.remove();
  },
  schedule(callback, delay) {
    const timer = setTimeout(() => { if (AppState.currentState === 'active') callback(); }, delay);
    return () => clearTimeout(timer);
  },
});

type Store = ReturnType<typeof createRemoteConfigStore>;
let current: { token: string | undefined; revision: number; store: Store } | undefined;

function getStore(token: string | undefined, revision: number): Store {
  if (current && current.token === token && current.revision === revision) return current.store;
  const store = createRemoteConfigStore(async () => {
    const info = await getAppInfo();
    return appRemoteConfig({
      accessToken: token,
      platform: info.platform,
      appVersion: info.version,
      buildNumber: Number.parseInt(info.build || '0', 10) || 0,
      channel: info.channel,
      coreVersion: info.coreVersion,
      osVersion: `${info.platform} ${String(Platform.Version ?? '')}`,
      apiClientVersion: info.apiClientVersion,
      configSchemaVersion: info.configSchemaVersion,
    });
  }, {
    foreground(callback) {
      const subscription = AppState.addEventListener('change', (state) => {
        if (state === 'active') callback();
      });
      return () => subscription.remove();
    },
    schedule(callback, delay) {
      const timer = setTimeout(() => { if (AppState.currentState === 'active') callback(); }, delay);
      return () => clearTimeout(timer);
    },
  });
  current = { token, revision, store };
  return store;
}

export function useServiceNotice() {
  const { session, sessionRevision } = useSession();
  const token = session?.accessToken;
  // Session-scoped stores keep an old account response out of a new session.
  const store = useMemo(() => getStore(token, sessionRevision), [token, sessionRevision]);
  const api = useSyncExternalStore(store.subscribe, store.getSnapshot, store.getSnapshot);
  const external = useSyncExternalStore(independentStore.subscribe, independentStore.getSnapshot, independentStore.getSnapshot);
  return useMemo(() => ({ ...api, notice: projectServiceNotice(api, external) }), [api, external]);
}
