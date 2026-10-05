import type { AppStateStatus } from "react-native";
import type { VpnStatus } from "@/native/vexVpn";

export type OtaPresentationStatus =
  | "idle"
  | "checking"
  | "downloading"
  | "ready"
  | "restarting"
  | "updated"
  | "rolled_back"
  | "error";

export function shouldShowOtaOverlay(status: OtaPresentationStatus): boolean {
  return (
    status === "downloading" ||
    status === "restarting" ||
    status === "updated" ||
    status === "rolled_back" ||
    status === "error"
  );
}

export function shouldShowOtaHeaderAction(
  status: OtaPresentationStatus,
): boolean {
  return (
    status === "downloading" ||
    status === "ready" ||
    status === "restarting" ||
    status === "error"
  );
}

export function canRunOtaCheck({
  dismissed,
  force,
  running,
  nativeBusy,
  status,
}: {
  dismissed: boolean;
  force: boolean;
  running: boolean;
  nativeBusy: boolean;
  status: OtaPresentationStatus;
}): boolean {
  return (
    (!dismissed || force) &&
    !running &&
    !nativeBusy &&
    status !== "ready" &&
    status !== "restarting" &&
    status !== "updated" &&
    status !== "rolled_back"
  );
}

type ReloadLock = { current: boolean };

type ReloadOtaSafelyInput = {
  getAppState: () => AppStateStatus;
  canApply: (
    appState: AppStateStatus,
    vpnStatus: Pick<VpnStatus, "state" | "leakProtection">,
  ) => boolean;
  getVpnStatus: () => Promise<VpnStatus>;
  isReady: () => boolean;
  lock: ReloadLock;
  onBlocked: (message: string) => void;
  performReload: () => Promise<boolean>;
};

export async function reloadOtaSafely(
  input: ReloadOtaSafelyInput,
): Promise<boolean> {
  if (!input.isReady() || input.lock.current) return false;
  input.lock.current = true;
  try {
    const vpnStatus = await input.getVpnStatus().catch(() => null);
    const appState = input.getAppState();
    if (!vpnStatus || !input.canApply(appState, vpnStatus)) {
      input.onBlocked(
        !vpnStatus
          ? "Не удалось проверить VPN. Обновление подождёт."
          : appState !== "active"
            ? "Применим обновление, когда VEX снова будет открыт."
            : vpnStatus.leakProtection === "blocking"
              ? "Обновление ждёт снятия блокировки трафика."
              : "Обновление ждёт отключения VPN, чтобы не прервать соединение.",
      );
      return false;
    }
    // The app can move to background while the native VPN query is in flight.
    if (!input.isReady() || input.getAppState() !== "active") return false;
    return await input.performReload();
  } finally {
    input.lock.current = false;
  }
}
