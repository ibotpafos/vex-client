export type NetworkObservation = { networkClass: 'wifi' | 'cellular' | 'ethernet' | 'unknown'; generation: string };
export type CapturedNetworkObservation = NetworkObservation & { id: string; deviceId: string; capturedAt: number };

// Keep no SSID, IP, SIM identifier, or persistent network history.
export function matchingNetworkObservation(captured: CapturedNetworkObservation | null, current: NetworkObservation, deviceId: string | undefined, now: number): string | undefined {
  if (!captured || !deviceId || captured.deviceId !== deviceId || !current.generation ||
    captured.generation !== current.generation || captured.networkClass !== current.networkClass ||
    now < captured.capturedAt || now - captured.capturedAt > 6 * 60 * 60 * 1000) return undefined;
  return captured.id;
}
