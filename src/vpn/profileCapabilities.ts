export const managedProfileAWGVersion = 3;

export function withManagedProfileAWGCapability(query: URLSearchParams): URLSearchParams {
  const next = new URLSearchParams(query);
  next.set('awg_version', String(managedProfileAWGVersion));
  next.set('awg3_opt_in', 'true');
  return next;
}
