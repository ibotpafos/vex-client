export const managedProfileAWGVersion = 3;

export function withManagedProfileAWGCapability(query: URLSearchParams): URLSearchParams {
  const next = new URLSearchParams(query);
  next.set('awg_version', String(managedProfileAWGVersion));
  return next;
}
