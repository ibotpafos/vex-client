export const androidVpnDisconnectTimeoutMs = 12_000;

export class VpnDisconnectTimeoutError extends Error {
  constructor() {
    super('VEX не смог завершить VPN автоматически. Открыты настройки VPN Android — отключите VEX там один раз; перезагрузка и повторный вход не нужны.');
    this.name = 'VpnDisconnectTimeoutError';
  }
}

export function disconnectWithRecoveryTimeout<T>(
  operation: Promise<T>,
  openRecovery: () => Promise<unknown>,
  timeoutMs = androidVpnDisconnectTimeoutMs,
): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) {
        return;
      }
      settled = true;
      void openRecovery()
        .catch(() => undefined)
        .finally(() => reject(new VpnDisconnectTimeoutError()));
    }, timeoutMs);

    operation.then(
      (value) => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        resolve(value);
      },
      (error) => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        reject(error);
      },
    );
  });
}
