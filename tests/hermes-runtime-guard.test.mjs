import assert from 'node:assert/strict';
import test from 'node:test';
import vm from 'node:vm';
import { TARGET_APP_ID, selectInspectorPage, decoderProbe, metroBaseUrl } from '../scripts/test_android_hermes_runtime.mjs';

const base = 'http://127.0.0.1:8082';
const page = (appId = TARGET_APP_ID) => ({ appId, id:'fixture-1', webSocketDebuggerUrl:'ws://127.0.0.1:8082/inspector/debug?device=fixture&page=1' });
test('only the exact preview package can be attached', () => {
  assert.equal(selectInspectorPage([page('com.vexguard.app'),page('com.vexguard.app.sdk58qa'),page()],base).appId,TARGET_APP_ID);
  for(const appId of ['com.vexguard.app','com.vexguard.app.sdk58qa',`${TARGET_APP_ID}.other`,undefined]) {
    const wrong={...page(),appId,title:TARGET_APP_ID,description:TARGET_APP_ID};
    assert.throws(()=>selectInspectorPage([wrong],base),/PREVIEW_TARGET_REQUIRED/);
  }
  assert.throws(()=>selectInspectorPage([page(),page()],base),/AMBIGUOUS_PREVIEW_TARGET/);
});
test('inspector redirects, foreign sockets and non-dedicated Metro ports fail closed', () => {
  for(const url of ['https://remote.example:8082','http://127.0.0.1:8081','http://user@localhost:8082','http://127.0.0.1:8082/path','http://127.0.0.1:8082/?secret=x'])assert.throws(()=>metroBaseUrl(url),/DEDICATED_LOOPBACK_METRO_REQUIRED/);
  for(const url of ['ws://remote.example:8082/inspector/debug?device=x&page=1','ws://127.0.0.1:8081/inspector/debug?device=x&page=1','ws://127.0.0.1:8082/other?device=x&page=1'])assert.throws(()=>selectInspectorPage([{...page(),webSocketDebuggerUrl:url}],base),/UNSAFE_INSPECTOR_SOCKET/);
});
test('the probe cannot report host Node or Chrome as on-device Hermes', () => {
  assert.throws(()=>decoderProbe(),/HERMES_REQUIRED/);
});
test('synthetic guard realm tests decoder contract, NOT native acceptance', () => {
  const sandbox={HermesInternal:{getRuntimeProperties:()=>({'OSS Release Version':'synthetic-test-only'})},TextDecoder,Uint8Array};
  const result=vm.runInNewContext(`(${decoderProbe.toString()})()`,sandbox);
  assert.equal(result.status,'PASS');assert.ok(result.streamingCases>40);
  const BrokenDecoder=class {decode(){return '';}};
  assert.throws(()=>vm.runInNewContext(`(${decoderProbe.toString()})()`,{...sandbox,TextDecoder:BrokenDecoder}),/UTF8_STREAM_MISMATCH/);
});

test('serialized CDP probe avoids Hermes astral-source compilation errors', () => {
  assert.doesNotMatch(decoderProbe.toString(), /[^\x00-\x7f]/);
});
