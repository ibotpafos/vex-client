export const managedProfileAWGVersion = 3;
// iOS and Android both embed AWG3-capable WireGuard bridges. Keep the
// capability explicit at the app boundary so managed profile requests stay on
// the AWG3 parser path for both clients.

export function withManagedProfileAWGCapability(query: URLSearchParams): URLSearchParams {
  const next = new URLSearchParams(query);
  next.set('awg_version', String(managedProfileAWGVersion));
  return next;
}
