export type EntitlementRevocationState = {
  clearDevices: () => void;
  clearEntitlement: () => void;
  clearLocations: () => void;
};

type QueryCacheRemover = {
  removeQueries: (filters: { queryKey: readonly unknown[] }) => unknown;
};

export function clearDefinitiveEntitlementFailure(
  queryClient: QueryCacheRemover,
  accessToken: string,
  state: EntitlementRevocationState,
): void {
  state.clearEntitlement();
  state.clearLocations();
  state.clearDevices();
  queryClient.removeQueries({ queryKey: ['entitlement', accessToken] });
  queryClient.removeQueries({ queryKey: ['vpn-locations', accessToken] });
  queryClient.removeQueries({ queryKey: ['vpn-devices', accessToken] });
  queryClient.removeQueries({ queryKey: ['vpn-profile', accessToken] });
}
