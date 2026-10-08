import fixture from './fixtures/client-diagnostic-failure-samples.json';
import { ApiRequestError, normalizeApiRequestError, technicalWorksMessage } from '../src/api/error';
import { diagnosticFailureSamples } from '../src/diagnostics/failureSamples';

function check(condition: unknown, detail: string): asserts condition {
  if (!condition) throw new Error(detail);
}
function expectSamples(actual: unknown, expected: unknown, detail: string) {
  check(JSON.stringify(actual) === JSON.stringify(expected), detail);
}
for (const row of fixture.cases) {
  let error: Error;
  switch (row.kind) {
    case 'http': error = new ApiRequestError('synthetic-private-material', { status: row.status, code: 'synthetic-private-material' }); break;
    case 'timeout': error = new ApiRequestError('Превышено время ожидания API.', { code: 'request_timeout' }); break;
    case 'network': error = new Error('Network request failed synthetic-private-material'); break;
    case 'cancelled': error = new Error('synthetic-private-material'); error.name = 'AbortError'; break;
    case 'response_parse': error = new SyntaxError('synthetic-private-material'); break;
    default: error = new Error('synthetic-private-material');
  }
  const samples = diagnosticFailureSamples(normalizeApiRequestError(error));
  expectSamples(samples, row.expected, row.kind);
  check(!/synthetic-private-material|error_message|url|token/.test(JSON.stringify(samples)), 'private material entered diagnostic samples');
}
for (const status of [502, 503, 504]) {
  const normalized = normalizeApiRequestError(new ApiRequestError('backend detail', { status, code: 'maintenance' }));
  check(normalized.message === technicalWorksMessage, 'maintenance UI message changed');
  check(normalized instanceof ApiRequestError, 'typed HTTP failure was lost');
  check(normalized.status === status && normalized.code === 'maintenance', 'HTTP metadata was lost');
  expectSamples(diagnosticFailureSamples(normalized), { diagnostic_error_class: 'http', diagnostic_http_status: status }, 'normalized HTTP cause');
}
for (const status of [399, 600, 503.1, NaN]) {
  expectSamples(diagnosticFailureSamples(new ApiRequestError('private', { status })), { diagnostic_error_class: 'unknown' }, 'invalid HTTP status');
}
expectSamples(diagnosticFailureSamples({ status: 503, message: 'private', code: 'request_timeout' }), { diagnostic_error_class: 'unknown' }, 'untyped error object');
