#!/usr/bin/env node
import http from 'node:http';
import net from 'node:net';
import tls from 'node:tls';
import { URL } from 'node:url';

const port = Number.parseInt(process.env.VEX_DEV_PROXY_PORT || '3011', 10);
const targetBase = new URL(process.env.VEX_DEV_PROXY_TARGET || 'https://vexguard.app');
const allowedOriginPattern = /^https?:\/\/(?:localhost|127\.0\.0\.1|\[::1\])(?::\d+)?$/;
const hopByHopHeaders = new Set([
  'connection',
  'content-length',
  'host',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
]);

const server = http.createServer(async (request, response) => {
  const origin = request.headers.origin;
  applyCors(response, origin);

  if (request.method === 'OPTIONS') {
    response.writeHead(204);
    response.end();
    return;
  }

  if (!request.url?.startsWith('/v1/')) {
    response.writeHead(404, { 'Content-Type': 'application/json' });
    response.end(JSON.stringify({ message: 'Unsupported dev proxy path' }));
    return;
  }

  try {
    const upstreamUrl = new URL(request.url, targetBase);
    const headers = forwardedHeaders(request.headers);
    const body = request.method === 'GET' || request.method === 'HEAD'
      ? undefined
      : await readRequestBody(request);
    const upstreamResponse = await fetch(upstreamUrl, {
      body,
      headers,
      method: request.method,
      redirect: 'manual',
    });

    const responseHeaders = responseHeadersFor(upstreamResponse.headers, origin);
    response.writeHead(upstreamResponse.status, responseHeaders);
    if (request.method === 'HEAD') {
      response.end();
      return;
    }
    const buffer = Buffer.from(await upstreamResponse.arrayBuffer());
    response.end(buffer);
    logRequest(request.method, request.url, upstreamResponse.status);
  } catch (error) {
    response.writeHead(502, { 'Content-Type': 'application/json' });
    response.end(JSON.stringify({ message: 'Production API proxy failed' }));
    const message = error instanceof Error ? error.message : String(error);
    console.error(`[dev-prod-api-proxy] ${request.method} ${request.url} failed: ${message}`);
  }
});

server.listen(port, '127.0.0.1', () => {
  console.log(`[dev-prod-api-proxy] http://127.0.0.1:${port} -> ${targetBase.origin}`);
});

server.on('upgrade', (request, socket, head) => {
  if (!request.url?.startsWith('/v1/')) {
    socket.destroy();
    return;
  }
  const upstreamUrl = new URL(request.url, targetBase);
  const upstreamPort = targetBase.port || (targetBase.protocol === 'https:' ? '443' : '80');
  const upstreamSocket = targetBase.protocol === 'https:'
    ? tls.connect(Number(upstreamPort), targetBase.hostname, { servername: targetBase.hostname })
    : net.connect(Number(upstreamPort), targetBase.hostname);

  upstreamSocket.once('connect', () => {
    upstreamSocket.write(`${request.method} ${upstreamUrl.pathname}${upstreamUrl.search} HTTP/${request.httpVersion}\r\n`);
    for (const [key, value] of Object.entries(request.headers)) {
      if (!value || key.toLowerCase() === 'host') {
        continue;
      }
      upstreamSocket.write(`${key}: ${Array.isArray(value) ? value.join(', ') : value}\r\n`);
    }
    upstreamSocket.write(`Host: ${targetBase.host}\r\n`);
    upstreamSocket.write(`X-Forwarded-Host: localhost:${port}\r\n`);
    upstreamSocket.write('X-Forwarded-Proto: http\r\n');
    upstreamSocket.write('\r\n');
    if (head.length) {
      upstreamSocket.write(head);
    }
    upstreamSocket.pipe(socket);
    socket.pipe(upstreamSocket);
    logRequest('WS', request.url, 101);
  });

  upstreamSocket.on('error', (error) => {
    socket.destroy();
    const message = error instanceof Error ? error.message : String(error);
    console.error(`[dev-prod-api-proxy] WS ${request.url} failed: ${message}`);
  });
  socket.on('error', () => upstreamSocket.destroy());
});

function applyCors(response, origin) {
  if (typeof origin === 'string' && allowedOriginPattern.test(origin)) {
    response.setHeader('Access-Control-Allow-Origin', origin);
    response.setHeader('Vary', 'Origin');
  }
  response.setHeader('Access-Control-Allow-Methods', 'GET,POST,PUT,PATCH,DELETE,OPTIONS');
  response.setHeader('Access-Control-Allow-Headers', 'Authorization,Content-Type,Accept,Idempotency-Key,X-Vex-Platform,X-Vex-App-Version,X-Vex-Build-Number,X-Vex-Core-Version,X-Vex-Channel,X-Vex-Device-ID,X-Vex-OS-Version,X-Vex-API-Client-Version,X-Vex-Config-Schema-Version');
}

function forwardedHeaders(headers) {
  const next = new Headers();
  for (const [key, value] of Object.entries(headers)) {
    if (!value || hopByHopHeaders.has(key.toLowerCase())) {
      continue;
    }
    if (Array.isArray(value)) {
      next.set(key, value.join(', '));
    } else {
      next.set(key, value);
    }
  }
  next.set('Host', targetBase.host);
  next.set('X-Forwarded-Host', `localhost:${port}`);
  next.set('X-Forwarded-Proto', 'http');
  return next;
}

function responseHeadersFor(headers, origin) {
  const next = {};
  headers.forEach((value, key) => {
    if (!hopByHopHeaders.has(key.toLowerCase()) && key.toLowerCase() !== 'access-control-allow-origin') {
      next[key] = value;
    }
  });
  if (typeof origin === 'string' && allowedOriginPattern.test(origin)) {
    next['Access-Control-Allow-Origin'] = origin;
    next.Vary = 'Origin';
  }
  return next;
}

function readRequestBody(request) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    request.on('data', (chunk) => chunks.push(chunk));
    request.on('error', reject);
    request.on('end', () => resolve(Buffer.concat(chunks)));
  });
}

function logRequest(method, url, status) {
  if (process.env.VEX_DEV_PROXY_QUIET === '1') {
    return;
  }
  console.log(`[dev-prod-api-proxy] ${method} ${url} -> ${status}`);
}
