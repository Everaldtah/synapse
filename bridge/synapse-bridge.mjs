#!/usr/bin/env node
// Synapse Bridge — lets the Synapse iOS app use your own subscriptions for complex AI work: Claude through the
// official Claude Code CLI, and ChatGPT through the official Codex CLI, both on this computer.
//
// You sign in to each CLI yourself with its own login (`claude auth login`, `codex login`). The bridge never reads,
// stores or forwards those credentials: it only runs the unmodified binaries with no tools, and streams the text back
// to the app. Usage counts against the plan signed in here.
//
//   node synapse-bridge.mjs [--port 7799] [--host 0.0.0.0] [--url https://pc.tailnet.ts.net] [--new-token] [--login]
//
// Endpoints (all need `Authorization: Bearer <pairing token>`):
//   GET  /v1/health  → { ok, name, version,
//                        claude: { loggedIn, email, subscriptionType, authMethod, version },
//                        codex:  { installed, loggedIn, version, defaultModel, models: [{ id, name, description, contextWindow }] } }
//   POST /v1/chat    { system, messages: [{ role, content }], engine?: "claude" | "codex", model?, effort? } →
//                    text/event-stream of data: {"type":"meta","engine":…,"model":…} {"type":"delta","text":"…"} …
//                    data: {"type":"done"}  (or {"type":"error","message":"…"})

import http from 'node:http';
import { spawn, execFile } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const VERSION = '0.2.0';
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
  --codex <path>      Path to the codex binary (default: found on PATH; optional)
  --max <n>           Concurrent runs (default 2)
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
// Both CLIs run in an empty folder, so they see nothing of yours (not even which project folder the bridge is in).
const WORK_DIR = path.join(CONFIG_DIR, 'work');
fs.mkdirSync(WORK_DIR, { recursive: true });
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

// ── finding and running the CLIs ───────────────────────────────────────────────────────────────────────────────
const isWindows = process.platform === 'win32';

function findBin(name, explicit, extraDirs = []) {
  if (explicit) return explicit;
  const names = isWindows ? [`${name}.exe`, `${name}.cmd`, name] : [name];
  const dirs = (process.env.PATH || '').split(path.delimiter).concat(extraDirs);
  for (const d of dirs) {
    for (const n of names) {
      const p = path.join(d, n);
      try { if (fs.statSync(p).isFile()) return p; } catch { /* keep looking */ }
    }
  }
  return null;
}

const CLAUDE = findBin('claude', opt('claude', process.env.CLAUDE_BIN),
  [path.join(os.homedir(), '.local', 'bin'), path.join(os.homedir(), '.claude', 'local')]);
const CODEX = findBin('codex', opt('codex', process.env.CODEX_BIN),
  isWindows ? [path.join(process.env.APPDATA || '', 'npm')] : [path.join(os.homedir(), '.local', 'bin')]);

// npm shims on Windows (.cmd) need a shell, and then every argument needs cmd.exe quoting.
const needsShell = (bin) => isWindows && /\.(cmd|bat)$/i.test(bin || '');
const quoterFor = (bin) => (a) => (needsShell(bin) ? (a === '' ? '""' : /[\s"&|<>^]/.test(a) ? `"${a.replace(/"/g, '""')}"` : a) : a);

function runProc(bin, args, { input, onStdout, onExit }) {
  const quote = quoterFor(bin);
  const child = spawn(needsShell(bin) ? quote(bin) : bin, args.map(quote), {
    shell: needsShell(bin),
    windowsHide: true,
    env: process.env,
    cwd: WORK_DIR,
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

function runText(bin, args) {
  const quote = quoterFor(bin);
  return new Promise((resolve) => {
    execFile(needsShell(bin) ? quote(bin) : bin, args.map(quote), { shell: needsShell(bin), windowsHide: true, timeout: 20000 }, (err, stdout, stderr) => {
      resolve({ ok: !err, out: String(stdout || '').trim(), err: String(stderr || '').trim() });
    });
  });
}

async function runJSON(bin, args) {
  const r = await runText(bin, args);
  if (!r.ok) return null;
  try { return JSON.parse(r.out); } catch { return { raw: r.out }; }
}

let claudeVersion = null;
async function claudeStatus() {
  if (!CLAUDE) return { loggedIn: false, error: 'Claude Code not found' };
  if (!claudeVersion) {
    const v = await runJSON(CLAUDE, ['--version']);
    claudeVersion = v?.raw || null;
  }
  const s = (await runJSON(CLAUDE, ['auth', 'status', '--json'])) || {};
  // Only identity facts — never tokens.
  return {
    loggedIn: Boolean(s.loggedIn),
    email: s.email || null,
    subscriptionType: s.subscriptionType || null,
    authMethod: s.authMethod || null,
    version: claudeVersion,
  };
}

// Codex settings live in ~/.codex (or $CODEX_HOME). The bridge only reads the chosen model and the model list.
const CODEX_HOME = process.env.CODEX_HOME || path.join(os.homedir(), '.codex');

function codexDefaultModel() {
  try {
    const toml = fs.readFileSync(path.join(CODEX_HOME, 'config.toml'), 'utf8');
    // Top-level `model = "…"` only (before the first [table]).
    const top = toml.split(/^\s*\[/m)[0];
    return top.match(/^\s*model\s*=\s*"([^"]+)"/m)?.[1] || null;
  } catch {
    return null;
  }
}

function codexModels() {
  try {
    const j = JSON.parse(fs.readFileSync(path.join(CODEX_HOME, 'models_cache.json'), 'utf8'));
    return (j.models || [])
      .filter((m) => m && m.slug && m.visibility !== 'hide')
      .map((m) => ({ id: m.slug, name: m.display_name || m.slug, description: m.description || '', contextWindow: m.context_window || null }));
  } catch {
    return [];
  }
}

let codexVersion = null;
async function codexStatus() {
  if (!CODEX) return { installed: false, loggedIn: false };
  if (!codexVersion) codexVersion = (await runText(CODEX, ['--version'])).out || null;
  const s = await runText(CODEX, ['login', 'status']);
  const text = `${s.out}\n${s.err}`;
  return {
    installed: true,
    loggedIn: s.ok && /logged in/i.test(text),
    method: /chatgpt/i.test(text) ? 'chatgpt' : /api key/i.test(text) ? 'apiKey' : null,
    version: codexVersion,
    defaultModel: codexDefaultModel(),
    models: codexModels(),
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

// Turns one engine's stdout lines into bridge events. Each returns { args, input, onLine, model }.
function claudeJob(payload, sysFile, send, finish) {
  const args = ['-p', '--output-format', 'stream-json', '--verbose', '--include-partial-messages',
    '--tools', '', '--system-prompt-file', sysFile, '--no-session-persistence', '--strict-mcp-config', '--setting-sources', ''];
  if (typeof payload.model === 'string' && MODEL_RE.test(payload.model)) args.push('--model', payload.model);
  if (typeof payload.effort === 'string' && EFFORTS.has(payload.effort)) args.push('--effort', payload.effort);
  let streamed = false;
  let fallbackText = '';
  return {
    bin: CLAUDE,
    args,
    input: buildPrompt(payload.messages),
    onLine(line) {
      let ev;
      try { ev = JSON.parse(line); } catch { return; }
      if (ev.type === 'system' && ev.subtype === 'init' && ev.model) {
        send({ type: 'meta', engine: 'claude', model: ev.model });
      } else if (ev.type === 'stream_event' && ev.event?.type === 'content_block_delta' && ev.event.delta?.type === 'text_delta') {
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
    onExit(code, stderr) {
      if (!streamed && fallbackText) send({ type: 'delta', text: fallbackText });
      const hint = /not logged in|login|authenticat/i.test(stderr) ? ' Claude Code is not signed in — run "claude auth login" on the bridge computer.' : '';
      finish(code === 0 ? { type: 'done' } : { type: 'error', message: `Claude Code exited (${code}).${hint} ${stderr.split('\n').slice(-3).join(' ').trim()}`.trim() });
    },
  };
}

function codexJob(payload, send, finish) {
  const model = typeof payload.model === 'string' && MODEL_RE.test(payload.model) && payload.model !== 'default'
    ? payload.model : codexDefaultModel();
  const effort = payload.effort === 'max' ? 'xhigh' : EFFORTS.has(payload.effort) ? payload.effort : 'medium';
  // No user config (so no MCP servers or project rules), read-only sandbox, an empty working folder, nothing saved.
  const args = ['exec', '--json', '--skip-git-repo-check', '--ephemeral', '--ignore-user-config', '--ignore-rules',
    '-s', 'read-only', '-C', WORK_DIR, '-c', `model_reasoning_effort=${effort}`];
  if (model) args.push('-m', model);
  args.push('-');
  const system = typeof payload.system === 'string' && payload.system.trim() ? payload.system : 'You are a helpful writing assistant.';
  const input = `<instructions>\n${system}\n\nAnswer directly in text. Do not run commands, read files or use any tools.\n</instructions>\n\n${buildPrompt(payload.messages)}`;
  send({ type: 'meta', engine: 'codex', model: model || 'Codex default' });
  const sent = new Map(); // agent_message item id → characters already streamed
  let usage = null;
  return {
    bin: CODEX,
    args,
    input,
    onLine(line) {
      let ev;
      try { ev = JSON.parse(line); } catch { return; }
      const item = ev.item;
      if ((ev.type === 'item.updated' || ev.type === 'item.completed') && item?.type === 'agent_message' && typeof item.text === 'string') {
        const id = item.id || 'msg';
        const already = sent.get(id) || 0;
        // A new message after an earlier one starts on a new paragraph.
        if (already === 0 && sent.size > 0) send({ type: 'delta', text: '\n\n' });
        if (item.text.length > already) send({ type: 'delta', text: item.text.slice(already) });
        sent.set(id, Math.max(already, item.text.length));
      } else if (ev.type === 'turn.completed') {
        usage = ev.usage || null;
        finish({ type: 'done', usage });
      } else if (ev.type === 'turn.failed' || ev.type === 'error') {
        const msg = String(ev.error?.message || ev.message || 'Codex reported an error.');
        finish({ type: 'error', message: /401|unauthori|sign(ed)? in|refresh token/i.test(msg) ? `Codex isn't signed in on the bridge computer — run "codex login" there. (${msg.slice(0, 200)})` : msg });
      }
    },
    onExit(code, stderr) {
      const auth = /401 Unauthorized|refresh token|sign in again/i.test(stderr);
      if (code === 0 && !auth) return finish({ type: 'done', usage });
      finish({ type: 'error', message: auth ? 'Codex isn\'t signed in on the bridge computer — run "codex login" there.' :
        `Codex exited (${code}). ${stderr.split('\n').filter((l) => !/^\s*$/.test(l)).slice(-2).join(' ').slice(0, 400)}`.trim() });
    },
  };
}

function handleChat(req, res, body) {
  let payload;
  try { payload = JSON.parse(body || '{}'); } catch { return sendJSON(res, 400, { error: 'Body must be JSON.' }); }
  const engine = payload.engine === 'codex' ? 'codex' : 'claude';
  if (engine === 'claude' && !CLAUDE) return sendJSON(res, 503, { error: 'Claude Code is not installed on this computer.' });
  if (engine === 'codex' && !CODEX) return sendJSON(res, 503, { error: 'Codex is not installed on this computer (npm i -g @openai/codex, then codex login).' });
  if (running >= MAX_CONCURRENT) return sendJSON(res, 429, { error: 'The bridge is busy. Try again in a moment.' });
  payload.messages = Array.isArray(payload.messages) ? payload.messages : [];
  if (!buildPrompt(payload.messages).trim()) return sendJSON(res, 400, { error: 'No user message.' });

  res.writeHead(200, {
    'Content-Type': 'text/event-stream; charset=utf-8',
    'Cache-Control': 'no-cache, no-transform',
    Connection: 'keep-alive',
    'X-Accel-Buffering': 'no',
  });
  const send = (obj) => { if (!res.writableEnded) res.write(`data: ${JSON.stringify(obj)}\n\n`); };
  const heartbeat = setInterval(() => { if (!res.writableEnded) res.write(': ping\n\n'); }, 15000);

  let sysFile = null;
  if (engine === 'claude') {
    sysFile = path.join(os.tmpdir(), `synapse-sys-${crypto.randomBytes(6).toString('hex')}.txt`);
    fs.writeFileSync(sysFile, typeof payload.system === 'string' && payload.system.trim() ? payload.system : 'You are a helpful writing assistant.');
  }

  running++;
  const started = Date.now();
  let finished = false;
  let timer = null;
  const finish = (obj) => {
    if (finished) return;
    finished = true;
    clearInterval(heartbeat);
    clearTimeout(timer);
    running--;
    if (sysFile) fs.rm(sysFile, { force: true }, () => {});
    send(obj);
    res.end();
    log(`${engine} ${obj.type} in ${((Date.now() - started) / 1000).toFixed(1)}s`);
  };

  const job = engine === 'codex' ? codexJob(payload, send, finish) : claudeJob(payload, sysFile, send, finish);
  const child = runProc(job.bin, job.args, {
    input: job.input,
    onStdout: (line) => { if (!finished) job.onLine(line); },
    onExit: (code, stderr) => { if (!finished) job.onExit(code, stderr); },
  });
  timer = setTimeout(() => { child.kill(); finish({ type: 'error', message: 'Timed out.' }); }, REQUEST_TIMEOUT_MS);
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
    Promise.all([claudeStatus(), codexStatus()]).then(([claude, codex]) =>
      sendJSON(res, 200, { ok: true, name: os.hostname(), version: VERSION, claude, codex }));
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
  if (!CLAUDE && !CODEX) {
    console.log('\n✗ Neither Claude Code nor Codex was found. Install Claude Code (https://claude.com/claude-code), then run:  claude auth login\n');
    process.exit(1);
  }
  if (CLAUDE) console.log(`  Claude Code: ${CLAUDE}`);
  if (flag('login') && CLAUDE) {
    await new Promise((resolve) => {
      const c = spawn(needsShell(CLAUDE) ? quoterFor(CLAUDE)(CLAUDE) : CLAUDE, ['auth', 'login'], { stdio: 'inherit', shell: needsShell(CLAUDE) });
      c.on('close', resolve);
    });
  }
  if (CLAUDE) {
    const status = await claudeStatus();
    if (status.loggedIn) {
      console.log(`  Signed in:   ${status.email || 'yes'}${status.subscriptionType ? ` (${status.subscriptionType})` : ''} via ${status.authMethod || 'Claude Code'}`);
    } else {
      console.log('\n  ! Claude Code is not signed in. Run this, then restart the bridge:\n\n      claude auth login\n');
    }
  }
  if (CODEX) {
    const cs = await codexStatus();
    console.log(`  Codex:       ${CODEX}${cs.loggedIn ? ` (${cs.method || 'signed in'}, model ${cs.defaultModel || 'default'})` : ' — not signed in: run "codex login"'}`);
  }

  server.listen(PORT, HOST, async () => {
    const a = addresses();
    const base = opt('url', null) || `http://${a.tailscale[0] || a.lan[0] || '127.0.0.1'}:${PORT}`;
    const link = `synapse://pair?url=${encodeURIComponent(base)}&token=${TOKEN}&name=${encodeURIComponent(os.hostname())}`;
    console.log(`  Listening:   ${HOST}:${PORT}`);
    for (const ip of a.tailscale) console.log(`  Tailscale:   http://${ip}:${PORT}   (works away from home)`);
    for (const ip of a.lan) console.log(`  Wi-Fi/LAN:   http://${ip}:${PORT}`);
    console.log('\n  Pair: in Synapse open Settings › AI models › Scan pairing QR code');
    const shown = await printQR(link);
    if (!shown) console.log('  (Run "npm install" in the bridge folder to show a QR code here.)');
    console.log(`\n  Or open this link on the iPhone:\n  ${flag('show-token') || !shown ? link : link.replace(TOKEN, TOKEN.slice(0, 6) + '…')}\n`);
    if (!flag('show-token') && shown) console.log('  (Use --show-token to print the full link.)\n');
    log('ready');
  });
}

main();
