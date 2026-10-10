import fs from 'node:fs';
import assert from 'node:assert/strict';
import test from 'node:test';
const source=fs.readFileSync('scripts/dev_prod_api_proxy.mjs','utf8');
const responseFunction=source.slice(source.indexOf('function responseHeadersFor('),source.indexOf('\nfunction readRequestBody('));
const responseHeaders=new Function('hopByHopHeaders','allowedOriginPattern',responseFunction+';return responseHeadersFor;')(new Set(['connection']),/^http:\/\/localhost:\d+$/);

test('browser API proxy exposes server retry delay while preserving other exposed headers',()=>{
  const result=responseHeaders(new Headers({'Retry-After':'2','Access-Control-Expose-Headers':'X-Request-ID','Connection':'close'}),'http://localhost:8081');
  assert.equal(result['retry-after'],'2');
  assert.equal(result['access-control-expose-headers'],'X-Request-ID, Retry-After');
  assert.equal(result['Access-Control-Allow-Origin'],'http://localhost:8081');
  assert.equal(result.connection,undefined);
});

test('browser API proxy grants no CORS access to unrelated origins',()=>{
  const result=responseHeaders(new Headers({'Retry-After':'2'}),'https://unrelated.example');
  assert.equal(result['Access-Control-Allow-Origin'],undefined);
  assert.equal(result['access-control-expose-headers'],undefined);
});
