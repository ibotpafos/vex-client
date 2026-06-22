export async function listenTauriEvent<T>(eventName: string, handler: (payload: T) => void): Promise<() => void> {
  const { listen } = await import('@tauri-apps/api/event');
  return listen<T>(eventName, (event) => {
    handler(event.payload);
  });
}
