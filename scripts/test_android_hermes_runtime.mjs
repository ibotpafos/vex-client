#!/usr/bin/env node
import { dirname, resolve } from 'node:path';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';

export const TARGET_APP_ID = 'com.vexguard.app.sdk58preview';
const timeoutMs = 10_000;
export function metroBaseUrl(value) {
  const url = new URL(value);
  if (url.protocol !== 'http:' || !['127.0.0.1','localhost','[::1]'].includes(url.hostname)
      || Number(url.port) < 8082 || !url.port || url.username || url.password || url.pathname !== '/' || url.search || url.hash) {
    throw new Error('DEDICATED_LOOPBACK_METRO_REQUIRED');
  }
  return url;
}
export function selectInspectorPage(pages, base) {
  const metro = metroBaseUrl(base);
  if (!Array.isArray(pages)) throw new Error('INVALID_INSPECTOR_PAGE_LIST');
  const matches = pages.filter(page => page.appId === TARGET_APP_ID);
  if (!matches.length) throw new Error('PREVIEW_TARGET_REQUIRED');
  if (matches.length !== 1) throw new Error('AMBIGUOUS_PREVIEW_TARGET');
  const page = matches[0], socket = new URL(page.webSocketDebuggerUrl);
  if (socket.protocol !== 'ws:' || socket.host !== metro.host || socket.username || socket.password || socket.hash
      || socket.pathname !== '/inspector/debug' || !socket.searchParams.get('device') || !socket.searchParams.get('page')
      || [...socket.searchParams.keys()].length !== 2) throw new Error('UNSAFE_INSPECTOR_SOCKET');
  return page;
}

// Serialized verbatim into the selected device runtime; no imports/app APIs or global writes.
export function decoderProbe() {
  const hermes = globalThis.HermesInternal;
  if (typeof hermes !== 'object' || typeof hermes?.getRuntimeProperties !== 'function') throw new Error('HERMES_REQUIRED');
  const properties = hermes.getRuntimeProperties();
  if (!properties || typeof properties !== 'object') throw new Error('HERMES_PROPERTIES_REQUIRED');
  if (typeof TextDecoder !== 'function') throw new Error('TEXT_DECODER_REQUIRED');
  // Hermes CDP's compiler needs ASCII source for astral string literals.
  const expected = '\u041f\u0440\u0438\u0432\u0435\u0442, \u043c\u0438\u0440 \ud83d\udc4b\ud83d\ude42 \u0435\u0301!';
  const bytes = new Uint8Array([208,159,209,128,208,184,208,178,208,181,209,130,44,32,208,188,208,184,209,128,32,240,159,145,139,240,159,153,130,32,208,181,204,129,33]);
  let streamingCases = 0;
  const check = output => { if (output !== expected) throw new Error('UTF8_STREAM_MISMATCH');streamingCases++; };
  for (let split = 0; split <= bytes.length; split++) {
    const decoder = new TextDecoder('utf-8');
    check(decoder.decode(bytes.slice(0, split), {stream:true}) + decoder.decode(bytes.slice(split), {stream:true}) + decoder.decode());
    const finalChunk = new TextDecoder('utf-8');
    check(finalChunk.decode(bytes.slice(0, split), {stream:true}) + finalChunk.decode(bytes.slice(split)));
  }
  for (const width of [1,2,3,4,5,7,8,bytes.length]) {
    const decoder = new TextDecoder('utf-8');let output = '';
    for (let offset = 0; offset < bytes.length; offset += width) output += decoder.decode(bytes.slice(offset, offset + width), {stream:true});
    check(output + decoder.decode());
    check(decoder.decode(bytes)); // Flush must reset, not retain the prior stream.
  }
  const truncated = new TextDecoder('utf-8');
  if (truncated.decode(new Uint8Array([240,159]), {stream:true}) !== '' || truncated.decode() !== '\uFFFD') throw new Error('UTF8_FLUSH_MISMATCH');
  return {status:'PASS',engine:'Hermes',decoderEncoding:new TextDecoder('utf-8').encoding,
    hermesRelease:String(properties['OSS Release Version'] ?? 'not-advertised'),byteLength:bytes.length,streamingCases,truncatedFlush:'PASS'};
}

async function evaluateOnDevice(page, origin) {
  const require = createRequire(import.meta.url);
  let InspectorWebSocket;
  try { InspectorWebSocket = require(require.resolve('ws', {paths:[dirname(require.resolve('expo/package.json'))]})); }
  catch { throw new Error('EXPO_WS_TRANSPORT_REQUIRED'); }
  const socket = new InspectorWebSocket(page.webSocketDebuggerUrl, {origin}), pending = new Map();let sequence = 0;
  socket.addEventListener('message', event => {
    let message;try {message = JSON.parse(event.data);} catch {return;}
    pending.get(message.id)?.(message);
  });
  const command = (method, params = {}) => new Promise((resolveResult, reject) => {
    const id = ++sequence;
    const timer = setTimeout(() => {pending.delete(id);reject(new Error('CDP_COMMAND_TIMEOUT'));}, timeoutMs);
    pending.set(id, message => {
      clearTimeout(timer);pending.delete(id);
      if (message.error) reject(new Error(`CDP_COMMAND_FAILED_${message.error.code}`));else resolveResult(message.result);
    });
    socket.send(JSON.stringify({id,method,params}));
  });
  try {
    await new Promise((opened,reject) => {
      const timer = setTimeout(() => reject(new Error('INSPECTOR_SOCKET_TIMEOUT')),timeoutMs);
      socket.addEventListener('open',() => {clearTimeout(timer);opened();},{once:true});
      socket.addEventListener('error',() => {clearTimeout(timer);reject(new Error('INSPECTOR_SOCKET_ERROR'));},{once:true});
    });
    await command('Runtime.enable');
    const reply = await command('Runtime.evaluate',{expression:`(${decoderProbe.toString()})()`,returnByValue:true});
    if (reply.exceptionDetails) {
      const description = reply.exceptionDetails.exception?.description ?? reply.exceptionDetails.text ?? '';
      const code = description.match(/HERMES_REQUIRED|HERMES_PROPERTIES_REQUIRED|TEXT_DECODER_REQUIRED|UTF8_STREAM_MISMATCH|UTF8_FLUSH_MISMATCH/)?.[0];
      throw new Error(code ?? 'NATIVE_PROBE_EXCEPTION');
    }
    const result = reply.result?.value;
    if (result?.status !== 'PASS' || result.engine !== 'Hermes' || result.streamingCases < 40) throw new Error('NATIVE_PROBE_RESULT_INVALID');
    return result;
  } finally {socket.close();}
}
export async function runAcceptance(base = 'http://127.0.0.1:8082') {
  const metro = metroBaseUrl(base);
  let response;
  try {response = await fetch(new URL('/json',metro),{redirect:'error',signal:AbortSignal.timeout(timeoutMs)});}
  catch {throw new Error('INSPECTOR_FETCH_FAILED');}
  if (!response.ok) throw new Error(`INSPECTOR_HTTP_${response.status}`);
  const page = selectInspectorPage(await response.json(),metro.href);
  return {targetAppId:TARGET_APP_ID,...await evaluateOnDevice(page,metro.origin)};
}
if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
  try {
    if (process.argv.length > 3) throw new Error('USAGE_NODE_SCRIPT_OPTIONAL_METRO_URL');
    console.log(JSON.stringify(await runAcceptance(process.argv[2])));
  } catch (error) {
    const code = /^[A-Z_]+(?:_-?\d+)?$/.test(error.message) ? error.message : 'INSPECTOR_EXECUTION_ERROR';
    console.log(JSON.stringify({status:'FAIL',targetAppId:TARGET_APP_ID,code}));process.exitCode = 1;
  }
}
