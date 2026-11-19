import { parseIndependentServiceStatus, type IndependentStatusState } from './independent-service-status';
import type { RemoteConfigSnapshot } from './remote-config-store';

export type ServiceNoticePresentation = { title: string; message?: string; unavailable: boolean };

// A fresh read from one source cannot remove a warning owned by another source.
export function projectServiceNotice(api: RemoteConfigSnapshot, external: IndependentStatusState, now = Date.now()): ServiceNoticePresentation | null {
  const manual = api.config?.incidentBanner?.trim();
  if (manual) return { title: 'Технические работы и неполадки VPN', message: manual, unavailable: api.unavailable };
  const fresh = !external.unavailable && !!parseIndependentServiceStatus(external.report, now);
  if (external.report?.status === 'maintenance') {
    return { title: external.report.title, message: external.report.message, unavailable: !fresh };
  }
  if (api.unavailable && !(fresh && external.report?.status === 'operational')) {
    return { title: 'Статус VPN уточняется', unavailable: true };
  }
  return null;
}
