export async function listenTauriEvent<T>(_eventName: string, _handler: (payload: T) => void): Promise<() => void> {
  return () => undefined;
}
