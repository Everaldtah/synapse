#!/usr/bin/env node
// Synapse Bridge — lets the Synapse iOS app use Claude through the official Claude Code CLI on this computer.
//
// You sign in to Claude Code yourself with Anthropic's own login (`claude auth login`). The bridge never reads,
// stores or forwards your Claude credentials: it only runs the unmodified `claude` binary in print mode with no
// tools, and streams the text back to the app. Usage counts against the Claude plan signed in here.
//
//   node synapse-bridge.mjs [--port 7799] [--host 0.0.0.0] [--url https://pc.tailnet.ts.net] [--new-token] [--login]
//
// Endpoints (all need `Authorization: Bearer <pairing token>`):
//   GET  /v1/health  → { ok, name, version, claude: { loggedIn, email, subscriptionType, authMethod, version } }
//   POST /v1/chat    { system, messages: [{ role, content }], model?, effort? } → text/event-stream of
//                    data: {"type":"delta","text":"…"} … data: {"type":"done"}  (or {"type":"error","message":"…"})

import http from 'node:http';
import { spawn, execFile } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const VERSION = '0.1.0';
const MAX_BODY = 4 * 1024 * 1024;
const REQUEST_TIMEOUT_MS = 10 * 60 * 1000;

// ── options ────────────────────────────────────────────────────────────────────────────────────────────────────
const argv = process.argv.slice(2);
const flag = (name) => argv.includes(`--${name}`);
const opt = (name, fallback) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 && argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[i + 1] : fallback;
};
if (flag('help') || flag('h')) {
  console.log(`Synapse Bridge ${VERSION}

  --port <n>          Port to listen on (default 7799)
  --host <addr>       Interface to bind (default 0.0.0.0 — reachable from your phone)
  --url <url>         Address to put in the pairing code (e.g. your Tailscale HTTPS name)
  --claude <path>     Path to the claude binary (default: found on PATH)
  --max <n>           Concurrent Claude runs (default 2)
  --new-token         Make a new pairing token (unpairs existing phones)
  --login             Run "claude auth login" first (Anthropic's own sign-in)
  --show-token        Print the token in plain text
`);
  process.exit(0);
}
const PORT = Number(opt('port', process.env.SYNAPSE_BRIDGE_PORT || 7799));
const HOST = opt('host', '0.0.0.0');
const MAX_CONCURRENT = Number(opt('max', 2));

// ── config & token ─────────────────────────────────────────────────────────────────────────────────────────────
const CONFIG_DIR = path.join(os.homedir(), '.synapse-bridge');
const CONFIG_FILE = path.join(CONFIG_DIR, 'config.json');
fs.mkdirSync(CONFIG_DIR, { recursive: true });
let config = {};
try { config = JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8')); } catch { /* first run */ }
if (!config.token || flag('new-token')) {
  config.token = crypto.randomBytes(24).toString('hex');
  config.createdAt = new Date().toISOString();
  fs.writeFileSync(CONFIG_FILE, JSON.stringify(config, null, 2), { mode: 0o600 });
}
const TOKEN = config.token;

function authorized(req) {
  const h = req.headers.authorization || '';
  const given = Buffer.from(h.startsWith('Bearer ') ? h.slice(7) : '');
  const want = Buffer.from(TOKEN);
  return given.length === want.length && crypto.timingSafeEqual(given, want);
}

// ── finding and running claude ─────────────────────────────────────────────────────────────────────────────────
const isWindows = process.platform === 'win32';

function findClaude() {
  const explicit = opt('claude', process.env.CLAUDE_BIN);
  if (explicit) return explicit;
  const names = isWindows ? ['claude.exe', 'claude.cmd', 'claude'] : ['claude'];
  const dirs = (process.env.PATH || '').split(path.delimiter);
  dirs.push(path.join(os.homedir(), '.local', 'bin'), path.join(os.homedir(), '.claude', 'local'));
  for (const d of dirs) {
    for (const n of names) {
      const p = path.join(d, n);
      try { if (fs.statSync(p).isFile()) return p; } catch { /* keep looking */ }
    }
  }
  return null;
}

const CLAUDE = findClaude();
const needsShell = isWindows && /\.(cmd|bat)$/i.test(CLAUDE || '');
const quote = (a) => (needsShell ? (a === '' ? '""' : /[\s"&|<>^]/.test(a) ? `"${a.replace(/"/g, '""')}"` : a) : a);

function runClaude(args, { input, onStdout, onExit }) {
  const child = spawn(needsShell ? quote(CLAUDE) : CLAUDE, args.map(quote), {
    shell: needsShell,
    windowsHide: true,
    env: process.env,
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  let stderr = '';
  let buffer = '';
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', (chunk) => {
    buffer += chunk;
    let nl;
    while ((nl = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, nl).trim();
      buffer = buffer.slice(nl + 1);
      if (line) onStdout?.(line);
    }
  });
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', (c) => { stderr = (stderr + c).slice(-4000); });
  child.on('error', (e) => onExit?.(-1, String(e)));
  child.on('close', (code) => {
    if (buffer.trim()) onStdout?.(buffer.trim());
    onExit?.(code, stderr);
  });
  if (input !== undefined) child.stdin.end(input);
  return child;
}

function claudeJSON(args) {
  return new Promise((resolve) => {
    execFile(needsShell ? quote(CLAUDE) : CLAUDE, args.map(quote), { shell: needsShell, windowsHide: true, timeout: 20000 }, (err, stdout) => {
      if (err) return resolve(null);
      try { resolve(JSON.parse(stdout)); } catch { resolve({ raw: String(stdout).trim() }); }
    });
  });
}

let claudeVersion = null;
async function claudeStatus() {
  if (!CLAUDE) return { loggedIn: false, error: 'Claude Code not found' };
  if (!claudeVersion) {
    const v = await claudeJSON(['--version']);
    claudeVersion = v?.raw || null;
  }
  const s = (await claudeJSON(['auth', 'status', '--json'])) || {};
  // Only identity facts — never tokens.
  return {
    loggedIn: Boolean(s.loggedIn),
    email: s.email || null,
    subscriptionType: s.subscriptionType || null,
    authMethod: s.authMethod || null,
    version: claudeVersion,
  };
}

// ── chat ───────────────────────────────────────────────────────────────────────────────────────────────────────
let running = 0;

function buildPrompt(messages) {
  const turns = messages.filter((m) => m && typeof m.content === 'string' && (m.role === 'user' || m.role === 'assistant'));
  if (turns.length === 0) return '';
  const last = turns[turns.length - 1];
  if (turns.length === 1) return last.content;
  const history = turns.slice(0, -1).map((m) => `<${m.role}>\n${m.content}\n</${m.role}>`).join('\n');
  return `<conversation_so_far>\n${history}\n</conversation_so_far>\n\n${last.content}`;
}

const MODEL_RE = /^[a-z0-9.\-]{2,64}$/i;
const EFFORTS = new Set(['low', 'medium', 'high', 'xhigh', 'max']);

function handleChat(req, res, body) {
  if (!CLAUDE) return sendJSON(res, 503, { error: 'Claude Code is not installed on this computer.' });
  if (running >= MAX_CONCURRENT) return sendJSON(res, 429, { error: 'The bridge is busy. Try again in a moment.' });
  let payload;
  try { payload = JSON.parse(body || '{}'); } catch { return sendJSON(res, 400, { error: 'Body must be JSON.' }); }
  const prompt = buildPrompt(Array.isArray(payload.messages) ? payload.messages : []);
  if (!prompt.trim()) return sendJSON(res, 400, { error: 'No user message.' });

  const sysFile = path.join(os.tmpdir(), `synapse-sys-${crypto.randomBytes(6).toString('hex')}.txt`);
  fs.writeFileSync(sysFile, typeof payload.system === 'string' && payload.system.trim() ? payload.system : 'You are a helpful writing assistant.');
  const args = ['-p', '--output-format', 'stream-json', '--verbose', '--include-partial-messages',
    '--tools', '', '--system-prompt-file', sysFile, '--no-session-persistence', '--strict-mcp-config', '--setting-sources', ''];
  if (typeof payload.model === 'string' && MODEL_RE.test(payload.model)) args.push('--model', payload.model);
  if (typeof payload.effort === 'string' && EFFORTS.has(payload.effort)) args.push('--effort', payload.effort);

  res.writeHead(200, {
    'Content-Type': 'text/event-stream; charset=utf-8',
    'Cache-Control': 'no-cache, no-transform',
    Connection: 'keep-alive',
    'X-Accel-Buffering': 'no',
  });
  const send = (obj) => { if (!res.writableEnded) res.write(`data: ${JSON.stringify(obj)}\n\n`); };
  const heartbeat = setInterval(() => { if (!res.writableEnded) res.write(': ping\n\n'); }, 15000);

  running++;
  const started = Date.now();
  let streamed = false;
  let finished = false;
  let fallbackText = '';
  const finish = (obj) => {
    if (finished) return;
    finished = true;
    clearInterval(heartbeat);
    clearTimeout(timer);
    running--;
    fs.rm(sysFile, { force: true }, () => {});
    send(obj);
    res.end();
    log(`chat ${obj.type} in ${((Date.now() - started) / 1000).toFixed(1)}s`);
  };

  const child = runClaude(args, {
    input: prompt,
    onStdout: (line) => {
      let ev;
      try { ev = JSON.parse(line); } catch { return; }
      if (ev.type === 'stream_event' && ev.event?.type === 'content_block_delta' && ev.event.delta?.type === 'text_delta') {
        streamed = true;
        send({ type: 'delta', text: ev.event.delta.text });
      } else if (ev.type === 'assistant' && Array.isArray(ev.message?.content)) {
        fallbackText = ev.message.content.filter((b) => b.type === 'text').map((b) => b.text).join('');
      } else if (ev.type === 'result') {
        if (ev.is_error) return finish({ type: 'error', message: String(ev.result || 'Claude Code reported an error.') });
        if (!streamed) {
          const text = typeof ev.result === 'string' ? ev.result : fallbackText;
          if (text) send({ type: 'delta', text });
        }
        finish({ type: 'done', usage: ev.usage || null, durationMs: ev.duration_ms || null });
      }
    },
    onExit: (code, stderr) => {
      if (finished) return;
      if (!streamed && fallbackText) send({ type: 'delta', text: fallbackText });
      const hint = /not logged in|login|authenticat/i.test(stderr) ? ' Claude Code is not signed in — run "claude auth login" on the bridge computer.' : '';
      finish(code === 0 ? { type: 'done' } : { type: 'error', message: `Claude Code exited (${code}).${hint} ${stderr.split('\n').slice(-3).join(' ').trim()}`.trim() });
    },
  });
  const timer = setTimeout(() => { child.kill(); finish({ type: 'error', message: 'Timed out.' }); }, REQUEST_TIMEOUT_MS);
  res.on('close', () => { if (!finished) { child.kill(); finish({ type: 'error', message: 'Cancelled.' }); } });
}

// ── server ─────────────────────────────────────────────────────────────────────────────────────────────────────
function sendJSON(res, status, obj) {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(obj));
}

function log(msg) {
  console.log(`[${new Date().toLocaleTimeString()}] ${msg}`);
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://bridge');
  if (url.pathname === '/' && req.method === 'GET') {
    return sendJSON(res, 200, { name: 'synapse-bridge', version: VERSION });
  }
  if (!authorized(req)) {
    log(`401 ${req.method} ${url.pathname} from ${req.socket.remoteAddress}`);
    return sendJSON(res, 401, { error: 'Missing or wrong pairing token.' });
  }
  if (url.pathname === '/v1/health' && req.method === 'GET') {
    claudeStatus().then((claude) => sendJSON(res, 200, { ok: true, name: os.hostname(), version: VERSION, claude }));
    return;
  }
  if (url.pathname === '/v1/chat' && req.method === 'POST') {
    let body = '';
    let size = 0;
    req.setEncoding('utf8');
    req.on('data', (c) => {
      size += Buffer.byteLength(c);
      if (size > MAX_BODY) { sendJSON(res, 413, { error: 'Request too large.' }); req.destroy(); return; }
      body += c;
    });
    req.on('end', () => { if (!res.headersSent) handleChat(req, res, body); });
    return;
  }
  sendJSON(res, 404, { error: 'Not found.' });
});

// ── start ──────────────────────────────────────────────────────────────────────────────────────────────────────
function addresses() {
  const out = { tailscale: [], lan: [] };
  for (const [name, list] of Object.entries(os.networkInterfaces())) {
    for (const a of list || []) {
      if (a.family !== 'IPv4' || a.internal) continue;
      const [x, y] = a.address.split('.').map(Number);
      if (x === 100 && y >= 64 && y <= 127) out.tailscale.push(a.address);
      else if (!/vEthernet|docker|vmnet|virtualbox|wsl/i.test(name)) out.lan.push(a.address);
    }
  }
  return out;
}

async function printQR(text) {
  try {
    const mod = await import('qrcode-terminal');
    const qr = mod.default || mod;
    await new Promise((resolve) => qr.generate(text, { small: true }, (s) => { console.log(s); resolve(); }));
    return true;
  } catch {
    return false;
  }
}

async function main() {
  console.log(`\nSynapse Bridge ${VERSION}`);
  if (!CLAUDE) {
    console.log('\n✗ Claude Code was not found. Install it (https://claude.com/claude-code), then run:  claude auth login\n');
    process.exit(1);
  }
  console.log(`  Claude Code: ${CLAUDE}`);
  if (flag('login')) {
    await new Promise((resolve) => {
      const c = spawn(needsShell ? quote(CLAUDE) : CLAUDE, ['auth', 'login'], { stdio: 'inherit', shell: needsShell });
      c.on('close', resolve);
    });
  }
  const status = await claudeStatus();
  if (status.loggedIn) {
    console.log(`  Signed in:   ${status.email || 'yes'}${status.subscriptionType ? ` (${status.subscriptionType})` : ''} via ${status.authMethod || 'Claude Code'}`);
  } else {
    console.log('\n  ! Claude Code is not signed in. Run this, then restart the bridge:\n\n      claude auth login\n');
  }

  server.listen(PORT, HOST, async () => {
    const a = addresses();
    const base = opt('url', null) || `http://${a.tailscale[0] || a.lan[0] || '127.0.0.1'}:${PORT}`;
    const link = `synapse://pair?url=${encodeURIComponent(base)}&token=${TOKEN}&name=${encodeURIComponent(os.hostname())}`;
    console.log(`  Listening:   ${HOST}:${PORT}`);
    for (const ip of a.tailscale) console.log(`  Tailscale:   http://${ip}:${PORT}   (works away from home)`);
    for (const ip of a.lan) console.log(`  Wi-Fi/LAN:   http://${ip}:${PORT}`);
    console.log('\n  Pair: in Synapse open Settings › Claude › Scan pairing QR code');
    const shown = await printQR(link);
    if (!shown) console.log('  (Run "npm install" in the bridge folder to show a QR code here.)');
    console.log(`\n  Or open this link on the iPhone:\n  ${flag('show-token') || !shown ? link : link.replace(TOKEN, TOKEN.slice(0, 6) + '…')}\n`);
    if (!flag('show-token') && shown) console.log('  (Use --show-token to print the full link.)\n');
    log('ready');
  });
}

main();
