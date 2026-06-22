import type { VpnDiagnosticsSnapshot } from '@/diagnostics/clientDiagnostics';

export function sessionLoadFailureDiagnosticsSnapshot(sessionLoadError: string): VpnDiagnosticsSnapshot {
  return {
    reason: 'auth_session_load_failed_before_sign_in',
    status: 'failed',
    vpnStatus: { state: 'disconnected', rxBytes: 0, txBytes: 0 },
    samples: {
      session_load_error: sessionLoadError,
    },
  };
}
