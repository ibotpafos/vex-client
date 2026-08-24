import type { ClientDiagnosticsReportInput } from './types';

export function clientDiagnosticsRequestBody(report: ClientDiagnosticsReportInput) {
  return {
    device_id: report.deviceId,
    platform: report.platform,
    app_version: report.appVersion,
    reason: report.reason,
    status: report.status,
    vpn_state: report.vpnState,
    connection_event: report.connectionEvent,
    connect_duration_ms: report.connectDurationMs,
    transport_from: report.transportFrom,
    transport_to: report.transportTo,
    session_uptime_seconds: report.sessionUptimeSeconds,
    endpoint: report.endpoint,
    observed_public_ip: report.observedPublicIp,
    dns_ok: report.dnsOk,
    https_ok: report.httpsOk,
    packet_loss_percent: report.packetLossPercent,
    latency_avg_ms: report.latencyAverageMs,
    latency_max_ms: report.latencyMaxMs,
    rx_bytes: report.rxBytes,
    tx_bytes: report.txBytes,
    samples: report.samples,
    samples_json: report.samplesJson,
  };
}
