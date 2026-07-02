import { isTauriRuntime } from './tauriPlatform';

export async function listenTauriEvent<T>(eventName: string, handler: (payload: T) => void): Promise<() => void> {
  if (!isTauriRuntime()) {
    return () => undefined;
  }

  try {
    const { listen } = await import('@tauri-apps/api/event');
    return listen<T>(eventName, (event) => {
      handler(event.payload);
    });
  } catch {
    return () => undefined;
  }
}
