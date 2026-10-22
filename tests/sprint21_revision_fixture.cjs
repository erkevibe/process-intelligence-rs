'use strict';
// Explicit test-event fixture. It serves the exact, read-only production island
// and vendor Datastar. It does not run conversions, authentication or recovery.
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');
const HOST = '127.0.0.1';
const PORT = 3134;
const MAX_REQUESTS = 1000;
const MAX_RUNTIME_MS = 25 * 60 * 1000;
if (process.argv.length !== 3) throw new Error('Exactly one workspace argument is required');
const workspace = fs.realpathSync(path.resolve(process.argv[2]));
if (!fs.statSync(workspace).isDirectory()) throw new Error('Workspace directory required');
const assetNames = ['/static/conversions.js', '/static/vendor/datastar-1.0.4.js'];
const assets = new Map(assetNames.map(name => {
  const resolved = fs.realpathSync(path.join(workspace, name.slice(1)));
  if (!resolved.startsWith(workspace + path.sep)) throw new Error('Asset must remain in the workspace');
  const metadata = fs.statSync(resolved);
  if (!metadata.isFile() || metadata.size > 1024 * 1024) throw new Error('Bounded production asset required');
  const bytes = fs.readFileSync(resolved);
  return [name, {bytes, sha256: crypto.createHash('sha256').update(bytes).digest('hex')}];
}));
const nonce = () => crypto.randomBytes(24).toString('base64');
const escape = value => String(value).replace(/[&<>"']/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[c]));
function page(token) {
  return `<!doctype html><html lang="ru" data-nonce="${token}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Проверка отображения ревизий</title><script type="module" src="/static/vendor/datastar-1.0.4.js"></script><script defer src="/static/conversions.js"></script></head><body><main><h1>Проверка отображения: тестовые события, без преобразования файлов</h1><p>Тестовая страница проверки Datastar и защиты от устаревших событий. Здесь нет импорта, входа в систему или восстановления после сбоя.</p><div id="revision-watcher" data-watcher-identity="stable"><article id="conversion-job-7" data-revision="9007199254740992"><h2>Тестовое преобразование job-7</h2><p role="status">В очереди</p></article></div><div hidden aria-hidden="true" id="conversion-transport-job-7"></div><p><button id="sequence" type="button" data-on:click="@get('/sequence', {retry: 'never'})">Последовательность: очередь → выполнение → готово</button></p><p><button id="reconnect" type="button" data-on:click="@get('/sequence', {retry: 'never'})">Повторить поток после переподключения</button></p><p><button id="stale" type="button" data-on:click="@get('/stale', {retry: 'never'})">Устаревшая ревизия</button> <button id="equal" type="button" data-on:click="@get('/equal', {retry: 'never'})">Повтор текущей ревизии</button> <button id="overflow" type="button" data-on:click="@get('/overflow', {retry: 'never'})">Ревизия за пределом u64</button> <button id="wrongjob" type="button" data-on:click="@get('/wrongjob', {retry: 'never'})">Событие другой задачи</button> <button id="max" type="button" data-on:click="@get('/max', {retry: 'never'})">Максимальная ревизия u64</button></p><p>После «Готово» устаревшие, повторные и некорректные события должны сохранить готовый результат. Максимальная допустимая ревизия должна отобразиться точно.</p></main></body></html>`;
}
function event(revision, status, jobId = 'job-7') {
  const article = `<article id="conversion-${escape(jobId)}" data-revision="${escape(revision)}"><h2>Тестовое преобразование ${escape(jobId)}</h2><p role="status">${escape(status)}</p></article>`;
  const envelope = `<div hidden aria-hidden="true" id="conversion-transport-job-7"><template data-conversion-update data-job-id="${escape(jobId)}">${article}</template></div>`;
  return `event: datastar-patch-elements\ndata: selector #conversion-transport-job-7\ndata: mode outer\ndata: elements ${envelope}\n\n`;
}
const sequences = new Map([
  ['/sequence', [['9007199254740992', 'В очереди'], ['9007199254740993', 'Преобразование'], ['9007199254740994', 'Готово']]],
  ['/stale', [['9007199254740992', 'НЕ ДОЛЖНО ПОЯВИТЬСЯ: устаревшее событие']]],
  ['/equal', [['9007199254740994', 'НЕ ДОЛЖНО ПОЯВИТЬСЯ: повтор ревизии']]],
  ['/overflow', [['18446744073709551616', 'НЕ ДОЛЖНО ПОЯВИТЬСЯ: переполнение u64']]],
  ['/wrongjob', [['9007199254740995', 'НЕ ДОЛЖНО ПОЯВИТЬСЯ: другая задача', 'job-8']]],
  ['/max', [['18446744073709551615', 'Максимальная ревизия u64: 18446744073709551615']]],
]);
let requests = 0;
let stopping = false;
const sockets = new Set();
const server = http.createServer({maxHeaderSize: 8192, requestTimeout: 5000, headersTimeout: 5000}, (req, res) => {
  requests++;
  const token = nonce();
  res.setHeader('Content-Security-Policy', `default-src 'self'; script-src 'self' 'nonce-${token}'; style-src 'self'; connect-src 'self'; img-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'`);
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('Cache-Control', 'no-store');
  if (requests > MAX_REQUESTS) {res.writeHead(503);res.end('Request limit');shutdown();return;}
  if (req.method !== 'GET' || req.url.length > 2048 || req.headers.host !== `${HOST}:${PORT}` || (req.headers.origin && req.headers.origin !== `http://${HOST}:${PORT}`)) {res.writeHead(403);res.end('Refused');return;}
  let route;
  try {route = new URL(req.url, `http://${HOST}:${PORT}`).pathname;} catch {res.writeHead(400);res.end('Invalid request');return;}
  if (route === '/') {res.writeHead(200, {'Content-Type': 'text/html; charset=utf-8'});res.end(page(token));return;}
  const asset = assets.get(route);
  if (asset) {res.writeHead(200, {'Content-Type': 'text/javascript; charset=utf-8'});res.end(asset.bytes);return;}
  const sequence = sequences.get(route);
  if (!sequence) {res.writeHead(404);res.end('Not found');return;}
  res.writeHead(200, {'Content-Type': 'text/event-stream; charset=utf-8', 'Connection': 'keep-alive'});
  res.flushHeaders();
  const timers = sequence.map((item, index) => setTimeout(() => {if (!res.destroyed) res.write(event(...item));}, index * 250));
  timers.push(setTimeout(() => {if (!res.destroyed) res.end();}, sequence.length * 250));
  res.on('close', () => timers.forEach(clearTimeout));
});
server.on('connection', socket => {sockets.add(socket);socket.on('close', () => sockets.delete(socket));});
function shutdown() {
  if (stopping) return;
  stopping = true;
  clearTimeout(expiry);
  server.close(() => process.exit(process.exitCode || 0));
  for (const socket of sockets) socket.destroy();
  setTimeout(() => process.exit(process.exitCode || 0), 2000).unref();
}
const expiry = setTimeout(shutdown, MAX_RUNTIME_MS);
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
const stopNonce = process.env.S21_FIXTURE_STOP_NONCE;
if (stopNonce) {
  if (!/^[a-f0-9]{32}$/.test(stopNonce)) throw new Error('Invalid owned fixture nonce');
  let pending = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', chunk => {
    pending += chunk;
    if (pending.length > 4096) {process.exitCode = 1; shutdown(); return;}
    if (pending.includes('\n')) {
      if (pending.trim() !== `STOP ${stopNonce}`) process.exitCode = 1;
      shutdown();
    }
  });
}
server.on('error', error => {process.stderr.write(JSON.stringify({status: 'error', code: error.code || 'server_error'}) + '\n');process.exitCode = 1;clearTimeout(expiry);});
server.listen(PORT, HOST, () => process.stdout.write(JSON.stringify({status: 'ready', port: PORT, max_requests: MAX_REQUESTS, max_runtime_ms: MAX_RUNTIME_MS, assets: Object.fromEntries([...assets].map(([name, item]) => [name, item.sha256])), scope: 'synthetic display events; no conversion/authentication/recovery claim'}) + '\n'));
