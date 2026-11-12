#!/usr/bin/env node
// dashboard-server.mjs — the live dashboard: serves the page on 127.0.0.1 and keeps the run
// index fresh, so the page updates itself while runs are going.
//
//   node dashboard-server.mjs        env: ROSALBITO_PORT (7777), ROSALBITO_REFRESH (seconds, 15)
//
// Every REFRESH seconds it runs collect.sh, which only re-parses runs whose files changed;
// every 10 minutes a --full pass recomputes everything (stale flags, new repos under $HOME).
// The page polls /api/runs and re-renders when the data's version changes. No dependencies,
// binds 127.0.0.1 only and answers only to localhost Host headers.
import http from 'node:http';
import os from 'node:os';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SKILL = path.resolve(HERE, '..');
const HOME_DIR = process.env.ROSALBITO_HOME || path.join(os.homedir(), '.rosalbito');
const PORT = Number(process.env.ROSALBITO_PORT || 7777);
const REFRESH = Number(process.env.ROSALBITO_REFRESH || 15);
const FULL_EVERY_MS = 10 * 60 * 1000;
const INDEX = path.join(HOME_DIR, 'runs.jsonl');
const TEMPLATE = path.join(SKILL, 'templates', 'dashboard.html');
const PRICING_AS_OF = JSON.parse(fs.readFileSync(path.join(SKILL, 'config', 'pricing.json'), 'utf8')).as_of;

let collecting = false, lastFull = 0, lastCollect = null, lastError = null;

function collect() {
  if (collecting) return;
  collecting = true;
  const full = Date.now() - lastFull > FULL_EVERY_MS;
  const child = spawn('bash', [path.join(HERE, 'collect.sh'), ...(full ? ['--full'] : [])], { stdio: ['ignore', 'ignore', 'pipe'] });
  let err = '';
  child.stderr.on('data', d => { err += d; });
  child.on('error', e => { collecting = false; lastError = String(e); });
  child.on('close', code => {
    collecting = false;
    lastCollect = new Date().toISOString().replace(/\.\d+Z$/, 'Z');
    if (code === 0) { lastError = null; if (full) lastFull = Date.now(); }
    else lastError = err.trim().split('\n').pop() || `collect.sh exited ${code}`;
  });
}

function payload() {
  let text = '', mtime = null;
  try { text = fs.readFileSync(INDEX, 'utf8'); mtime = fs.statSync(INDEX).mtime.toISOString().replace(/\.\d+Z$/, 'Z'); } catch { /* no index yet */ }
  const runs = text.split('\n').filter(Boolean).flatMap(l => { try { return [JSON.parse(l)]; } catch { return []; } });
  return {
    version: crypto.createHash('sha1').update(text).digest('hex').slice(0, 12),
    generated_at: lastCollect || mtime, index: INDEX, pricing_as_of: PRICING_AS_OF,
    live: true, refresh_seconds: REFRESH, collecting, error: lastError, runs,
  };
}

const json = obj => JSON.stringify(obj).replace(/</g, '\\u003c');   // safe inside <script>
const LOCAL_HOST = /^(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$/;

const server = http.createServer((req, res) => {
  if (!LOCAL_HOST.test(req.headers.host || '')) { res.writeHead(403).end('localhost only'); return; }
  const url = new URL(req.url, 'http://localhost');
  if (req.method === 'GET' && url.pathname === '/api/runs') {
    res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' }).end(json(payload()));
  } else if (req.method === 'GET' && url.pathname === '/') {
    const page = fs.readFileSync(TEMPLATE, 'utf8').replace('__ROSALBITO_DATA__', () => json(payload()));
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' }).end(page);
  } else {
    res.writeHead(404).end('not found');
  }
});

server.on('error', e => {
  console.error(e.code === 'EADDRINUSE' ? `port ${PORT} is busy: is the dashboard already running? (ROSALBITO_PORT=… to change)` : String(e));
  process.exit(1);
});
server.listen(PORT, '127.0.0.1', () => {
  console.log(`rosalbito dashboard: http://localhost:${PORT}  (index ${INDEX}, refresh ${REFRESH}s)`);
  collect();
  setInterval(collect, REFRESH * 1000).unref();
});
