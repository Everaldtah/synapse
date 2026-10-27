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
//   GET  /v1/health     → { ok, name, version, claude, codex,
//                           whisper: { available, model, device },
//                           sandbox: { available, distro, tools: [...] },
//                           harness: { available, loggedIn, email?, subscriptionType?, claudeVersion } }
//   POST /v1/chat       { system, messages: [{ role, content }], engine?: "claude" | "codex", model?, effort? } →
//                        SSE: {"type":"meta",…} {"type":"delta","text":…} … {"type":"done"} | {"type":"error",…}
//   POST /v1/transcribe raw audio/video bytes; X-Filename, X-Language? → SSE: {"type":"info",…}
//                        {"type":"segment","start","end","text"} … {"type":"done"} | {"type":"error"}   (Whisper on the GPU)
//   POST /v1/harness    { prompt, system?, model?, maxTurns?, timeout? } → SSE: {"type":"meta",…} {"type":"text",…}
//                        {"type":"tool",…} {"type":"tool_result",…} … {"type":"done",…} | {"type":"error"}  (Claude Code in the sandbox)
//   POST /v1/shell      { command, timeout?, cwd? } → { stdout, stderr, exitCode, timedOut, durationMs }   (sandbox)
//   POST /v1/files      raw bytes; X-Filename → { path, bytes }                                            (sandbox upload)
//   GET  /v1/files?path=<relative to the workspace> → the file's bytes, X-Filename                         (sandbox download)
//   POST /v1/extract    raw bytes; X-Filename → { text, method, mime, truncated }                          (any file → text)
//
// The last five all run inside the "synapse-sandbox" WSL distro (see bridge/sandbox/setup-wsl-sandbox.ps1),
// which has no access to Windows, your drives or your Claude login on Windows.

import http from 'node:http';
import { spawn, execFile } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const VERSION = '0.4.0';
const MAX_BODY = 4 * 1024 * 1024;
const MAX_UPLOAD = 1024 * 1024 * 1024; // 1 GB — audio/video and file uploads stream to disk, never into memory
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
  --python <path>     Path to Python with openai-whisper (default: python on PATH, then the Windows Python 3.13)
  --sandbox <name>    WSL distro for shell/files/extract/harness (default: synapse-sandbox)
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
const SANDBOX = opt('sandbox', 'synapse-sandbox');
// Where the sandbox keeps the shared workspace; uploads land in <WORK>/files. Must match setup-wsl-sandbox.ps1.
const SANDBOX_WORK = '/home/agent/work';
const SANDBOX_USER = 'agent';   // every bridge-issued command runs as this unprivileged user
const HARNESS_USER = 'claude';  // Claude Code runs as this user (holds its own login; shells out to agent)

// ── config & token ─────────────────────────────────────────────────────────────────────────────────────────────
const CONFIG_DIR = path.join(os.homedir(), '.synapse-bridge');
const CONFIG_FILE = path.join(CONFIG_DIR, 'config.json');
// Both CLIs run in an empty folder, so they see nothing of yours (not even which project folder the bridge is in).
const WORK_DIR = path.join(CONFIG_DIR, 'work');
const UPLOAD_DIR = path.join(CONFIG_DIR, 'uploads'); // temp landing for /v1/transcribe bytes (deleted after use)
fs.mkdirSync(WORK_DIR, { recursive: true });
fs.mkdirSync(UPLOAD_DIR, { recursive: true });
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

// Python for Whisper. Prefer an explicit --python / $PYTHON_BIN, then "python" on PATH; on Windows fall back to the
// per-user Python 3.13 the installer puts under %LOCALAPPDATA% (where openai-whisper + CUDA torch are installed).
const PYTHON = opt('python', process.env.PYTHON_BIN)
  || findBin(isWindows ? 'python' : 'python3', null,
    isWindows ? [path.join(process.env.LOCALAPPDATA || '', 'Programs', 'Python', 'Python313')] : [])
  || 'python3';
const WHISPER_SCRIPT = path.join(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')), 'whisper_transcribe.py');

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

// ── the WSL sandbox ────────────────────────────────────────────────────────────────────────────────────────────
// Everything below runs inside the "synapse-sandbox" distro as the unprivileged user `agent` (see
// bridge/sandbox/setup-wsl-sandbox.ps1). The distro has no Windows drives and no interop, so a command there can't
// touch your files or run Windows programs. We never build a shell string from caller input: the command travels as
// one argv element to `bash -s` on stdin, or (bigger scripts) as a base64 blob a fixed wrapper decodes, so quoting,
// `$vars`, `;`, backticks and newlines can't break out.
// Resolve wsl.exe to an absolute path: when the bridge is launched by a service or a wrapper with a trimmed PATH,
// a bare "wsl.exe" fails to spawn, which would make the whole sandbox look "not set up".
const WSL = isWindows
  ? (findBin('wsl', null, [path.join(process.env.SystemRoot || 'C:\\Windows', 'System32')]) || 'wsl.exe')
  : null;
const wslEnv = { ...process.env, WSL_UTF8: '1', WSLENV: '' };

// Spawn a program inside the sandbox as `user`, cwd `cwd`. argv elements pass through verbatim (wsl.exe -e, no shell).
function spawnInSandbox(user, cwd, argv, opts = {}) {
  const base = ['-d', SANDBOX, '-u', user];
  if (cwd) base.push('--cd', cwd);
  base.push('-e', ...argv);
  return spawn(WSL, base, { windowsHide: true, env: wslEnv, stdio: ['pipe', 'pipe', 'pipe'], ...opts });
}

// Run a bash script (given as a string) in the sandbox, feeding `stdinData` to the script's own stdin via fd 3→0.
// The script itself arrives on fd 0 of `bash -s`, so to also give the script a stdin we smuggle data on fd 3.
// Simpler and robust: pass the script base64 on the command line to a fixed `bash -c` that decodes and runs it,
// with `stdinData` on stdin. Nothing in the script text reaches the shell un-decoded.
function runSandboxScript(user, cwd, script, { stdinData, timeoutMs, onChild } = {}) {
  return new Promise((resolve) => {
    const b64 = Buffer.from(script, 'utf8').toString('base64');
    const argv = ['bash', '-c', `echo ${b64} | base64 -d | bash -s`];
    const child = spawnInSandbox(user, cwd, argv);
    onChild?.(child);
    let out = '', err = '', timedOut = false;
    const cap = (s, c) => (s.length < 2 * 1024 * 1024 ? s + c : s); // guard runaway output in memory
    child.stdout.setEncoding('utf8'); child.stdout.on('data', (c) => { out = cap(out, c); });
    child.stderr.setEncoding('utf8'); child.stderr.on('data', (c) => { err = cap(err, c); });
    let timer = null;
    if (timeoutMs) timer = setTimeout(() => { timedOut = true; killTree(child); }, timeoutMs);
    child.on('error', (e) => { clearTimeout(timer); resolve({ code: -1, out, err: err + String(e), timedOut }); });
    child.on('close', (code) => { clearTimeout(timer); resolve({ code, out, err, timedOut }); });
    if (stdinData !== undefined) child.stdin.end(stdinData); else child.stdin.end();
  });
}

// Kill a wsl.exe child and, because killing wsl.exe doesn't always reap the Linux process, kill the tree inside the
// distro too (the probe in the scratchpad confirmed a bare child.kill() can leave `sleep` running).
function killTree(child, pid) {
  try { child.kill(); } catch { /* already gone */ }
  // Best-effort: stop anything the sandbox user is still running. These users only ever run bridge jobs.
  try { spawn(WSL, ['-d', SANDBOX, '-u', 'root', '-e', 'bash', '-c',
    `pkill -9 -u ${SANDBOX_USER} 2>/dev/null; pkill -9 -u ${HARNESS_USER} 2>/dev/null; true`],
    { windowsHide: true, env: wslEnv }).on('error', () => {}); } catch { /* ignore */ }
}

let sandboxReady = null; // cached probe: null = unknown, true/false after first check
async function sandboxProbe() {
  if (!isWindows) return { available: false, distro: SANDBOX, tools: [], error: 'Sandbox needs Windows + WSL.' };
  // List the tools, then print a sentinel. Availability = the sentinel came back, which proves bash actually ran
  // inside the distro (a missing distro makes wsl.exe error before any of this). We must NOT judge by the loop's
  // exit code: it reflects whether the *last* tool happens to be installed, not whether the sandbox works.
  const script = 'for t in pandoc pdftotext pdftoppm tesseract soffice ffmpeg python3 unzip jq file strings; do ' +
    'command -v "$t" >/dev/null 2>&1 && printf "%s\\n" "$t"; done; printf "__SANDBOX_OK__\\n"';
  const r = await runSandboxScript(SANDBOX_USER, SANDBOX_WORK, script, { timeoutMs: 20000 });
  const available = r.out.includes('__SANDBOX_OK__');
  if (!available) log(`sandbox probe FAIL code=${r.code} timedOut=${r.timedOut} WSL=${WSL} err=${JSON.stringify((r.err || '').slice(-300))}`);
  sandboxReady = available;
  return available
    ? { available: true, distro: SANDBOX, tools: r.out.split('\n').map((s) => s.trim()).filter((s) => s && s !== '__SANDBOX_OK__') }
    : { available: false, distro: SANDBOX, tools: [],
        error: `The "${SANDBOX}" sandbox isn't set up. Run: powershell -ExecutionPolicy Bypass -File bridge/sandbox/setup-wsl-sandbox.ps1 -WithHarness` };
}

// Resolve whether the sandbox is usable right now. Trusts a cached success; otherwise probes afresh (so a one-off
// failure, e.g. during first-time package install, doesn't wedge the endpoints as "not set up" forever).
async function ensureSandbox() {
  if (sandboxReady === true) return { ok: true };
  const p = await sandboxProbe();
  return p.available ? { ok: true } : { ok: false, error: p.error };
}

// POSIX-shell single-quote a string so it can be embedded in a sandbox script (close-quote, escaped quote, re-open).
const shq = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`;

// A safe relative sub-path of the workspace (no absolute, no "..", no NUL). Returns the sandbox path or null.
function resolveCwd(rel) {
  if (rel === undefined || rel === null || rel === '') return SANDBOX_WORK;
  const s = String(rel);
  if (/\0/.test(s) || s.startsWith('/') || s.split(/[\\/]+/).includes('..')) return null;
  return `${SANDBOX_WORK}/${s.replace(/\\/g, '/').replace(/^\.?\/+/, '')}`;
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

// ── shared SSE + upload helpers ────────────────────────────────────────────────────────────────────────────────
// Open a Server-Sent Events stream with the same framing and 15 s heartbeat as /v1/chat, and return { send, close }.
function openSSE(res) {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream; charset=utf-8',
    'Cache-Control': 'no-cache, no-transform',
    Connection: 'keep-alive',
    'X-Accel-Buffering': 'no',
  });
  const send = (obj) => { if (!res.writableEnded) res.write(`data: ${JSON.stringify(obj)}\n\n`); };
  const heartbeat = setInterval(() => { if (!res.writableEnded) res.write(': ping\n\n'); }, 15000);
  return { send, stop: () => clearInterval(heartbeat) };
}

// Stream a request body straight to a temp file (never into memory). Calls back (err, { file, bytes }).
// Rejects with a 413 marker once more than `cap` bytes arrive.
function streamBodyToFile(req, filePath, cap, cb) {
  const out = fs.createWriteStream(filePath);
  let bytes = 0, tooBig = false, done = false;
  const fail = (err) => { if (done) return; done = true; out.destroy(); fs.rm(filePath, { force: true }, () => {}); cb(err); };
  req.on('data', (c) => {
    bytes += c.length;
    if (bytes > cap) { tooBig = true; req.destroy(); return; }
    out.write(c);
  });
  req.on('aborted', () => fail(Object.assign(new Error('aborted'), { aborted: true })));
  req.on('error', fail);
  req.on('end', () => { if (tooBig || done) return; out.end(() => { done = true; cb(null, { file: filePath, bytes }); }); });
  out.on('error', fail);
  // req.destroy() on overflow fires 'close' on req; translate to a 413.
  req.on('close', () => { if (tooBig) fail(Object.assign(new Error('too large'), { tooBig: true })); });
}

const safeName = (name, fallback) => {
  const base = path.basename(String(name || '')).replace(/[^A-Za-z0-9._-]/g, '_').replace(/^\.+/, '');
  return base || fallback;
};

// Probe once (lazily): does this Python have whisper + torch, and would it use CUDA or CPU? Caches the result,
// because importing torch takes several seconds.
let whisperProbeCache = null;
function whisperProbe() {
  if (whisperProbeCache) return whisperProbeCache;
  whisperProbeCache = new Promise((resolve) => {
    const code = 'import json,sys\n' +
      'try:\n' +
      ' import torch, whisper\n' +
      ' d="cuda" if torch.cuda.is_available() else "cpu"\n' +
      ' print(json.dumps({"available":True,"model":"large-v3-turbo","device":d}))\n' +
      'except Exception as e:\n' +
      ' print(json.dumps({"available":False,"model":"large-v3-turbo","device":None,"error":str(e)[:200]}))';
    const child = spawn(needsShell(PYTHON) ? quoterFor(PYTHON)(PYTHON) : PYTHON, ['-I', '-c', code].map(quoterFor(PYTHON)),
      { shell: needsShell(PYTHON), windowsHide: true, env: { ...process.env, PYTHONIOENCODING: 'utf-8' } });
    let out = '';
    child.stdout.on('data', (c) => { out += c; });
    child.on('error', (e) => resolve({ available: false, model: 'large-v3-turbo', device: null, error: `python: ${e.message}` }));
    child.on('close', () => { try { resolve(JSON.parse(out.trim().split('\n').pop())); } catch { resolve({ available: false, model: 'large-v3-turbo', device: null, error: out.slice(0, 200) }); } });
  });
  return whisperProbeCache;
}

// ── /v1/transcribe — Whisper on the GPU ────────────────────────────────────────────────────────────────────────
let transcribing = false; // one at a time (the GPU holds one model)
function handleTranscribe(req, res) {
  if (transcribing) return sendJSON(res, 429, { error: 'A transcription is already running. Try again when it finishes.' });
  const ext = path.extname(safeName(req.headers['x-filename'], 'audio')).slice(0, 12) || '';
  const lang = (req.headers['x-language'] || '').toString().trim().slice(0, 2); // 2-letter code, or '' to auto-detect
  const tmp = path.join(UPLOAD_DIR, `rec-${crypto.randomBytes(6).toString('hex')}${ext}`);
  transcribing = true;
  const release = () => { transcribing = false; fs.rm(tmp, { force: true }, () => {}); };

  streamBodyToFile(req, tmp, MAX_UPLOAD, (err) => {
    if (err) {
      release();
      if (err.tooBig) return res.headersSent || sendJSON(res, 413, { error: 'Audio larger than 1 GB.' });
      return res.headersSent || sendJSON(res, 400, { error: `Upload failed: ${err.message}` });
    }
    const args = ['-I', WHISPER_SCRIPT, tmp, '--model', 'large-v3-turbo'];
    if (lang) args.push('--language', lang);
    const { send, stop } = openSSE(res);
    const started = Date.now();
    let finished = false, model = 'large-v3-turbo', device = '?';
    const child = spawn(needsShell(PYTHON) ? quoterFor(PYTHON)(PYTHON) : PYTHON, args.map(quoterFor(PYTHON)),
      { shell: needsShell(PYTHON), windowsHide: true, env: { ...process.env, PYTHONIOENCODING: 'utf-8', PYTHONUTF8: '1' } });
    const finish = (obj) => {
      if (finished) return; finished = true;
      stop(); clearTimeout(timer); release();
      send(obj); res.end();
      log(`transcribe ${obj.type} (${device}) in ${((Date.now() - started) / 1000).toFixed(1)}s`);
    };
    let buf = '', errBuf = '';
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      buf += chunk; let nl;
      while ((nl = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, nl).trim(); buf = buf.slice(nl + 1);
        if (!line) continue;
        let ev; try { ev = JSON.parse(line); } catch { continue; }
        if (ev.type === 'info') { model = ev.model || model; device = ev.device || device; }
        if (ev.type === 'done') return finish({ type: 'done' });
        if (ev.type === 'error') return finish({ type: 'error', message: ev.message || 'Transcription failed.' });
        send(ev); // info / segment pass straight through
      }
    });
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (c) => { errBuf = (errBuf + c).slice(-4000); });
    child.on('error', (e) => finish({ type: 'error', message: `Could not start Python (${PYTHON}): ${e.message}` }));
    child.on('close', (code) => {
      if (finished) return;
      finish(code === 0 ? { type: 'done' } : { type: 'error', message: `Whisper exited (${code}). ${errBuf.split('\n').slice(-3).join(' ').trim()}`.trim() });
    });
    const timer = setTimeout(() => { killChildTree(child); finish({ type: 'error', message: 'Transcription timed out.' }); }, REQUEST_TIMEOUT_MS);
    res.on('close', () => { if (!finished) { killChildTree(child); finish({ type: 'error', message: 'Cancelled.' }); } });
  });
}

// Kill a Windows child process and its descendants (Python can spawn ffmpeg; taskkill /T gets the tree).
function killChildTree(child) {
  try {
    if (isWindows && child.pid) spawn('taskkill', ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true }).on('error', () => {});
    else child.kill('SIGKILL');
  } catch { /* already gone */ }
}

// ── /v1/shell — run a command in the sandbox ───────────────────────────────────────────────────────────────────
let shellsRunning = 0;
const MAX_SHELLS = 2;
function handleShell(req, res, body) {
  if (!isWindows) return sendJSON(res, 503, { error: 'The sandbox needs Windows + WSL.' });
  let p; try { p = JSON.parse(body || '{}'); } catch { return sendJSON(res, 400, { error: 'Body must be JSON.' }); }
  const command = typeof p.command === 'string' ? p.command : '';
  if (!command.trim()) return sendJSON(res, 400, { error: 'No command.' });
  const timeoutSec = Math.min(Math.max(Number(p.timeout) || 60, 1), 600);
  const cwd = resolveCwd(p.cwd);
  if (cwd === null) return sendJSON(res, 400, { error: 'cwd must be a relative path inside the workspace (no "..", no leading /).' });
  if (shellsRunning >= MAX_SHELLS) return sendJSON(res, 429, { error: 'Too many shells running. Try again in a moment.' });

  ensureSandbox().then((s) => {
    if (!s.ok) return sendJSON(res, 503, { error: s.error });
    runShell();
  });
  function runShell() {
  shellsRunning++;
  const started = Date.now();
  // The command runs as `bash -lc "$command"` with the caller's text passed as a positional arg ($0-safe): the
  // wrapper reads the command from the environment of the decode step, never interpolated into the script source.
  const script = 'cd ' + shq(cwd) + ' 2>/dev/null || { echo "no such cwd" >&2; exit 2; }\n' +
    'exec bash -lc "$SYNAPSE_CMD"';
  // Put the caller's command in an env var the wrapper reads, so no quoting of it happens at all.
  const wrapped = `export SYNAPSE_CMD=${shq(command)}\n` + script;
  let child = null;
  runSandboxScript(SANDBOX_USER, null, wrapped, {
    timeoutMs: timeoutSec * 1000,
    onChild: (c) => { child = c; },
  }).then((r) => {
    shellsRunning--;
    const cap = (s) => {
      const b = Buffer.from(s, 'utf8');
      if (b.length <= 100 * 1024) return s;
      return b.subarray(0, 100 * 1024).toString('utf8') + `\n…[truncated ${b.length - 100 * 1024} bytes]`;
    };
    sendJSON(res, 200, {
      stdout: cap(r.out), stderr: cap(r.err),
      exitCode: r.timedOut ? null : r.code, timedOut: r.timedOut,
      durationMs: Date.now() - started,
    });
    log(`shell exit=${r.code}${r.timedOut ? ' (timed out)' : ''} in ${Date.now() - started}ms`);
  });
  res.on('close', () => { if (child && !res.writableEnded) killTree(child); });
  }
}

// ── /v1/files — upload a file into the sandbox workspace ───────────────────────────────────────────────────────
async function handleFiles(req, res) {
  if (!isWindows) return sendJSON(res, 503, { error: 'The sandbox needs Windows + WSL.' });
  const s = await ensureSandbox();
  if (!s.ok) return sendJSON(res, 503, { error: s.error });
  const name = safeName(req.headers['x-filename'], `upload-${Date.now()}`);
  // Stage on the Windows side first, then stream into the sandbox as `agent` (so ownership/permissions are right).
  const stage = path.join(UPLOAD_DIR, `up-${crypto.randomBytes(6).toString('hex')}`);
  streamBodyToFile(req, stage, MAX_UPLOAD, async (err, info) => {
    if (err) {
      if (err.tooBig) return res.headersSent || sendJSON(res, 413, { error: 'File larger than 1 GB.' });
      return res.headersSent || sendJSON(res, 400, { error: `Upload failed: ${err.message}` });
    }
    try {
      const dest = await copyIntoSandbox(stage, name);
      fs.rm(stage, { force: true }, () => {});
      sendJSON(res, 200, { path: dest, bytes: info.bytes });
      log(`files: ${dest} (${info.bytes} bytes)`);
    } catch (e) {
      fs.rm(stage, { force: true }, () => {});
      sendJSON(res, 500, { error: `Could not write into the sandbox: ${e.message}` });
    }
  });
}

// ── GET /v1/files?path=… — download a file from the sandbox workspace (files the agent made) ────────────────────
const MAX_DOWNLOAD = 200 * 1024 * 1024;
async function handleDownload(req, res, url) {
  if (!isWindows) return sendJSON(res, 503, { error: 'The sandbox needs Windows + WSL.' });
  const s = await ensureSandbox();
  if (!s.ok) return sendJSON(res, 503, { error: s.error });
  const want = String(url.searchParams.get('path') || '').trim();
  if (!want || want.includes('\0')) return sendJSON(res, 400, { error: 'Give ?path= (relative to the sandbox workspace).' });
  // Resolve inside the sandbox (symlinks included) and refuse anything outside the workspace.
  const probe = [
    `work=${shq(SANDBOX_WORK)}; want=${shq(want)}`,
    'case "$want" in /*) p="$want" ;; *) p="$work/$want" ;; esac',
    'p=$(realpath -e -- "$p" 2>/dev/null) || { echo "No such file in the sandbox."; exit 2; }',
    'case "$p" in "$work"/*) ;; *) echo "Only files inside the sandbox workspace can be downloaded."; exit 3 ;; esac',
    '[ -f "$p" ] || { echo "That is a folder, not a file."; exit 4; }',
    'printf "%s\\n%s\\n" "$(stat -c %s -- "$p")" "$p"',
  ].join('\n');
  const r = await runSandboxScript(SANDBOX_USER, null, probe, { timeoutMs: 15000 });
  if (r.code !== 0) return sendJSON(res, r.code === 2 ? 404 : 400, { error: (r.out || r.err).trim() || 'Download failed.' });
  const [sizeText, full] = r.out.split('\n');
  const size = Number(sizeText);
  if (!(size >= 0) || !full) return sendJSON(res, 500, { error: 'Could not read the file.' });
  if (size > MAX_DOWNLOAD) return sendJSON(res, 413, { error: 'File larger than 200 MB.' });
  res.writeHead(200, {
    'Content-Type': 'application/octet-stream',
    'Content-Length': String(size),
    'X-Filename': encodeURIComponent(path.posix.basename(full)),
  });
  const child = spawnInSandbox(SANDBOX_USER, null, ['cat', '--', full]);
  child.stdout.pipe(res);
  child.on('error', () => res.destroy());
  req.on('close', () => { if (!child.killed) child.kill(); });
  log(`download: ${full} (${size} bytes)`);
}

// Copy a staged Windows file into a sandbox dir as `agent`, suffixing the name to avoid clobbering. Returns the
// sandbox path. The file bytes are piped to the command's stdin, so (unlike runSandboxScript) the copy script is
// passed inline as a bash -lc argument — stdin must stay free for the data, not carry the script.
function copyIntoSandbox(winFile, name, destDir = `${SANDBOX_WORK}/files`) {
  return new Promise((resolve, reject) => {
    const script =
      'set -e\n' +
      `dir=${shq(destDir)}; mkdir -p "$dir"\n` +
      `base=${shq(name)}; dest="$dir/$base"; n=1\n` +
      'while [ -e "$dest" ]; do dest="$dir/${base%.*}-$n.${base##*.}"; ' +
      '[ "${base##*.}" = "$base" ] && dest="$dir/$base-$n"; n=$((n+1)); done\n' +
      'cat > "$dest"\n' +            // reads the file bytes from this process's stdin
      'printf "%s" "$dest"';
    // Pass the (multi-line) script as a single-line argv via eval of its base64, so stdin stays free for the file
    // bytes and no newline ever rides inside an argv element.
    const b64 = Buffer.from(script, 'utf8').toString('base64');
    const child = spawnInSandbox(SANDBOX_USER, null, ['bash', '-lc', `eval "$(echo ${b64} | base64 -d)"`]);
    let out = '', err = '';
    child.stdout.setEncoding('utf8'); child.stdout.on('data', (c) => { out += c; });
    child.stderr.setEncoding('utf8'); child.stderr.on('data', (c) => { err += c; });
    child.on('error', reject);
    child.on('close', (code) => code === 0 && out ? resolve(out.trim()) : reject(new Error(err.trim() || `exit ${code}`)));
    fs.createReadStream(winFile).pipe(child.stdin);
  });
}

// ── /v1/extract — any file → text, in the sandbox ──────────────────────────────────────────────────────────────
let extracting = 0;
async function handleExtract(req, res) {
  if (!isWindows) return sendJSON(res, 503, { error: 'The sandbox needs Windows + WSL.' });
  const s = await ensureSandbox();
  if (!s.ok) return sendJSON(res, 503, { error: s.error });
  if (extracting >= 2) return sendJSON(res, 429, { error: 'Too many extractions running. Try again in a moment.' });
  const name = safeName(req.headers['x-filename'], 'file.bin');
  const stage = path.join(UPLOAD_DIR, `ex-${crypto.randomBytes(6).toString('hex')}`);
  streamBodyToFile(req, stage, MAX_UPLOAD, async (err) => {
    if (err) {
      if (err.tooBig) return res.headersSent || sendJSON(res, 413, { error: 'File larger than 1 GB.' });
      return res.headersSent || sendJSON(res, 400, { error: `Upload failed: ${err.message}` });
    }
    extracting++;
    const started = Date.now();
    try {
      // Copy into a throwaway temp dir in the sandbox, extract there, then delete it.
      const tmpDir = `/tmp/synapse-extract-${crypto.randomBytes(6).toString('hex')}`;
      await runSandboxScript(SANDBOX_USER, null, `mkdir -p ${tmpDir}`, { timeoutMs: 10000 });
      const inPath = await copyIntoSandbox(stage, name, tmpDir);
      fs.rm(stage, { force: true }, () => {});
      const r = await runSandboxScript(SANDBOX_USER, null, extractScript(inPath), { timeoutMs: 180000 });
      await runSandboxScript(SANDBOX_USER, null, `rm -rf ${tmpDir}`, { timeoutMs: 10000 });
      extracting--;
      let parsed; try { parsed = JSON.parse(r.out); } catch { parsed = null; }
      if (!parsed) return sendJSON(res, 500, { error: `Extraction failed. ${r.err.split('\n').slice(-3).join(' ').trim() || r.out.slice(0, 300)}`.trim() });
      sendJSON(res, 200, parsed);
      log(`extract ${parsed.method} (${parsed.mime}) ${parsed.text ? parsed.text.length : 0} chars in ${Date.now() - started}ms`);
    } catch (e) {
      extracting--; fs.rm(stage, { force: true }, () => {});
      sendJSON(res, 500, { error: `Extraction failed: ${e.message}` });
    }
  });
}

// The bash the sandbox runs for /v1/extract: hand the file to a Python extractor that picks the best tool and
// prints one JSON object. The Python itself travels base64-encoded and is decoded to a temp file, not a heredoc:
// the bridge runs every script through `bash -s` on a pipe, and a heredoc body read from that same pipe is
// fragile, so we never put one in a bridge script.
function extractScript(inPath) {
  const pyB64 = Buffer.from(EXTRACT_PY, 'utf8').toString('base64');
  return 'IN=' + shq(inPath) + '\n' +
    'export HOME=/tmp/synapse-lohome-$$; mkdir -p "$HOME"\n' +
    'PY=/tmp/synapse-extract-$$.py\n' +
    `echo ${pyB64} | base64 -d > "$PY"\n` +
    'python3 "$PY" "$IN"; rc=$?\n' +
    'rm -f "$PY"\n' +
    'exit $rc\n';
}

const EXTRACT_PY = String.raw`
import json, os, re, subprocess, sys, zipfile
CAP = 2 * 1024 * 1024  # 2 MB of text
path = sys.argv[1]
ext = os.path.splitext(path)[1].lower().lstrip('.')

def run(cmd, **kw):
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=160, **kw)
        return p.returncode, p.stdout, p.stderr
    except Exception as e:
        return 1, b'', str(e).encode()

def mime_of(p):
    rc, out, _ = run(['file', '--mime-type', '-b', p])
    return out.decode('utf-8', 'replace').strip() if rc == 0 else 'application/octet-stream'

def cap(text):
    b = text.encode('utf-8', 'replace')
    if len(b) <= CAP:
        return text, False
    return b[:CAP].decode('utf-8', 'ignore'), True

def emit(text, method, mime):
    text, trunc = cap(text if text is not None else '')
    sys.stdout.write(json.dumps({'text': text, 'method': method, 'mime': mime, 'truncated': trunc}, ensure_ascii=False))

mime = mime_of(path)

def pandoc(fmt=None):
    cmd = ['pandoc', '-t', 'plain', '--wrap=none', path]
    if fmt: cmd[1:1] = ['-f', fmt]
    rc, out, err = run(cmd)
    return out.decode('utf-8', 'replace') if rc == 0 else None

def soffice_to(target, suffix):
    outdir = '/tmp/synapse-lo-%d' % os.getpid()
    os.makedirs(outdir, exist_ok=True)
    rc, out, err = run(['soffice', '--headless', '--nologo', '--nofirststartwizard',
                        '-env:UserInstallation=file:///tmp/synapse-loprofile-%d' % os.getpid(),
                        '--convert-to', target, '--outdir', outdir, path])
    base = os.path.splitext(os.path.basename(path))[0]
    cand = os.path.join(outdir, base + suffix)
    if os.path.exists(cand):
        return open(cand, 'r', encoding='utf-8', errors='replace').read()
    return None

def ocr_image(p):
    rc, out, err = run(['tesseract', p, 'stdout', '-l', 'eng'])
    return out.decode('utf-8', 'replace') if rc == 0 else None

def spreadsheet():
    # All sheets, each under a "## <sheet>" header, via pandas (xlsx/xls/ods). Falls back to libreoffice CSV.
    try:
        import pandas as pd
        sheets = pd.read_excel(path, sheet_name=None, header=None, dtype=str)
        parts = []
        for name, df in sheets.items():
            parts.append('## ' + str(name))
            parts.append(df.fillna('').to_csv(index=False, header=False))
        return '\n'.join(parts), 'pandas'
    except Exception:
        t = soffice_to('csv', '.csv')
        if t is not None:
            return t, 'libreoffice'
    return None, None

def zip_text():
    parts = []
    try:
        with zipfile.ZipFile(path) as z:
            names = z.namelist()
            parts.append('# Archive contents (%d entries)' % len(names))
            for n in names:
                parts.append('  ' + n)
            parts.append('')
            budget = CAP
            for n in names:
                if n.endswith('/'):
                    continue
                low = n.lower()
                if os.path.splitext(low)[1].lstrip('.') in (
                        'txt','md','csv','json','xml','html','htm','log','py','js','ts','c','h','cpp',
                        'java','go','rs','rb','sh','yml','yaml','ini','cfg','toml','tex','rst','srt','vtt'):
                    try:
                        data = z.read(n)[:budget]
                        parts.append('\n===== %s =====' % n)
                        parts.append(data.decode('utf-8', 'replace'))
                        budget -= len(data)
                        if budget <= 0:
                            parts.append('\n…[archive truncated]')
                            break
                    except Exception:
                        pass
        return '\n'.join(parts)
    except Exception as e:
        return None

text, method = None, None
PANDOC_EXT = {'docx','odt','epub','rtf','html','htm','md','markdown','rst','org','tex','latex','ipynb'}
SHEET_EXT = {'xlsx','xls','ods','xlsm','xlsb'}
OFFICE_EXT = {'doc','ppt','pptx','odp','pages','numbers','key'}

if mime.startswith('image/') or ext in ('png','jpg','jpeg','tif','tiff','bmp','gif','webp'):
    text, method = ocr_image(path), 'tesseract'
elif mime == 'application/pdf' or ext == 'pdf':
    rc, out, err = run(['pdftotext', '-layout', path, '-'])
    text = out.decode('utf-8', 'replace') if rc == 0 else ''
    method = 'pdftotext'
    if len((text or '').strip()) < 40:  # scanned PDF → OCR the rendered pages
        pre = '/tmp/synapse-pdf-%d' % os.getpid()
        run(['pdftoppm', '-r', '200', '-png', path, pre])
        pages = sorted(p for p in os.listdir('/tmp') if p.startswith(os.path.basename(pre)) and p.endswith('.png'))
        chunks = []
        for pg in pages[:50]:
            t = ocr_image(os.path.join('/tmp', pg))
            if t: chunks.append(t)
        if chunks:
            text, method = '\n'.join(chunks), 'pdftotext+ocr'
elif ext == 'csv' or mime in ('text/csv',):
    text = open(path, 'r', encoding='utf-8', errors='replace').read(); method = 'utf-8'
elif ext in SHEET_EXT or 'spreadsheet' in mime or 'ms-excel' in mime:
    text, method = spreadsheet()
elif ext in PANDOC_EXT or mime in ('application/epub+zip',):
    text = pandoc('ipynb' if ext == 'ipynb' else None); method = 'pandoc'
    if text is None and ext in OFFICE_EXT.union(PANDOC_EXT):
        text = soffice_to('txt:Text', '.txt'); method = 'libreoffice'
elif ext in OFFICE_EXT or 'presentation' in mime or mime == 'application/msword':
    text = soffice_to('txt:Text', '.txt'); method = 'libreoffice'
elif mime in ('application/zip',) or ext in ('zip',):
    text = zip_text(); method = 'unzip'

if text is None:
    # Try pandoc blindly, then plain decode, then strings.
    text = pandoc()
    method = 'pandoc'
if text is None:
    try:
        raw = open(path, 'rb').read()
        if b'\x00' not in raw[:4096]:
            text, method = raw.decode('utf-8', 'strict'), 'utf-8'
    except Exception:
        text = None
if text is None:
    rc, out, err = run(['strings', '-n', '6', path])
    text, method = out.decode('utf-8', 'replace'), 'strings'

emit(text, method or 'unknown', mime)
`;

// ── /v1/harness — Claude Code running inside the sandbox on your Claude subscription ───────────────────────────
let harnessRunning = false;
let harnessStatusCache = null; // { available, loggedIn, email, subscriptionType, claudeVersion } | error-shaped
async function harnessStatus() {
  if (harnessStatusCache) return harnessStatusCache;
  if (!isWindows) { harnessStatusCache = { available: false, loggedIn: false, claudeVersion: null }; return harnessStatusCache; }
  // Version + auth status run as the `claude` user (the one that holds the login). Identity fields only, no tokens.
  const script =
    'v=$(claude --version 2>/dev/null | head -1)\n' +
    's=$(claude auth status --json 2>/dev/null || claude auth status 2>/dev/null)\n' +
    'printf "%s\\n--SPLIT--\\n%s" "$v" "$s"';
  const r = await runSandboxScript(HARNESS_USER, `${SANDBOX_WORK}`, script, { timeoutMs: 25000 });
  const [ver = '', rest = ''] = r.out.split('--SPLIT--\n');
  let info = {};
  try { info = JSON.parse(rest.trim()); } catch { info = {}; }
  const loggedIn = Boolean(info.loggedIn) || /logged in|subscriptionType|authMethod/i.test(rest);
  harnessStatusCache = {
    available: r.code === 0 && Boolean(ver.trim()),
    loggedIn,
    email: info.email || null,
    subscriptionType: info.subscriptionType || null,
    claudeVersion: ver.trim() || null,
  };
  return harnessStatusCache;
}

const HARNESS_MODELS = { opus: 'opus', sonnet: 'sonnet', haiku: 'haiku', default: null };

function handleHarness(req, res, body) {
  if (!isWindows) return sendJSON(res, 503, { error: 'The sandbox needs Windows + WSL.' });
  let p; try { p = JSON.parse(body || '{}'); } catch { return sendJSON(res, 400, { error: 'Body must be JSON.' }); }
  const prompt = typeof p.prompt === 'string' ? p.prompt : '';
  if (!prompt.trim()) return sendJSON(res, 400, { error: 'No prompt.' });
  const modelAlias = Object.prototype.hasOwnProperty.call(HARNESS_MODELS, p.model) ? p.model : 'default';
  const model = HARNESS_MODELS[modelAlias];
  const maxTurns = Math.min(Math.max(Number(p.maxTurns) || 12, 1), 50);
  const timeoutSec = Math.min(Math.max(Number(p.timeout) || 600, 1), 1800);
  if (harnessRunning) return sendJSON(res, 429, { error: 'A harness run is already in progress. Try again when it finishes.' });

  harnessStatus().then((st) => {
    if (!st.available) {
      return sendJSON(res, 503, { error: `Claude Code isn't installed in the "${SANDBOX}" sandbox. Run: powershell -ExecutionPolicy Bypass -File bridge/sandbox/setup-wsl-sandbox.ps1 -WithHarness` });
    }
    if (!st.loggedIn) {
      return sendJSON(res, 503, { error: `Claude Code in the sandbox isn't signed in. Run once on the bridge computer:  wsl -d ${SANDBOX} -u ${HARNESS_USER} -- claude auth login` });
    }
    runHarness();
  });

  function runHarness() {
    harnessRunning = true;
    const { send, stop } = openSSE(res);
    const started = Date.now();
    let finished = false, turns = 0, finalText = '', metaSent = false;

    // claude -p, streaming JSON, built-in tools on, non-interactive, bypassing prompts. Managed settings in the
    // sandbox (root-owned /etc/claude-code/managed-settings.json) still deny reads of the login and force the
    // shell prefix, and bypassPermissions can't turn a deny rule off, so the deny rules hold in this mode.
    const argv = ['claude', '-p', '--output-format', 'stream-json', '--verbose',
      '--max-turns', String(maxTurns), '--permission-mode', 'bypassPermissions'];
    if (model) argv.push('--model', model);
    if (typeof p.system === 'string' && p.system.trim()) argv.push('--append-system-prompt', p.system);

    const child = spawnInSandbox(HARNESS_USER, SANDBOX_WORK, argv);
    const finish = (obj) => {
      if (finished) return; finished = true;
      stop(); clearTimeout(timer); harnessRunning = false;
      send(obj); res.end();
      log(`harness ${obj.type} (${modelAlias}, ${turns} turns) in ${((Date.now() - started) / 1000).toFixed(1)}s`);
    };

    let buf = '', errBuf = '';
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      buf += chunk; let nl;
      while ((nl = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, nl).trim(); buf = buf.slice(nl + 1);
        if (!line) continue;
        let ev; try { ev = JSON.parse(line); } catch { continue; }
        onEvent(ev);
      }
    });
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (c) => { errBuf = (errBuf + c).slice(-4000); });
    child.on('error', (e) => finish({ type: 'error', message: `Could not start Claude Code in the sandbox: ${e.message}` }));
    child.on('close', (code) => {
      if (finished) return;
      if (code === 0) return finish({ type: 'done', result: finalText, turns, durationMs: Date.now() - started });
      const hint = /not logged in|auth|login/i.test(errBuf) ? ` Sign in with: wsl -d ${SANDBOX} -u ${HARNESS_USER} -- claude auth login.` : '';
      finish({ type: 'error', message: `Claude Code exited (${code}).${hint} ${errBuf.split('\n').slice(-3).join(' ').trim()}`.trim() });
    });

    const trunc = (s, n) => { s = typeof s === 'string' ? s : JSON.stringify(s); return s.length > n ? s.slice(0, n) + '…' : s; };
    function onEvent(ev) {
      if (ev.type === 'system' && ev.subtype === 'init') {
        if (!metaSent) { metaSent = true; send({ type: 'meta', engine: 'harness', model: ev.model || model || 'default' }); }
      } else if (ev.type === 'assistant' && Array.isArray(ev.message?.content)) {
        turns++;
        for (const b of ev.message.content) {
          if (b.type === 'text' && b.text) { finalText = b.text; send({ type: 'text', text: b.text }); }
          else if (b.type === 'tool_use') {
            const input = b.input?.command ?? b.input?.url ?? b.input?.file_path ?? b.input?.pattern ?? JSON.stringify(b.input || {});
            send({ type: 'tool', name: b.name || 'tool', input: trunc(input, 500) });
          }
        }
      } else if (ev.type === 'user' && Array.isArray(ev.message?.content)) {
        for (const b of ev.message.content) {
          if (b.type === 'tool_result') {
            const out = Array.isArray(b.content) ? b.content.map((x) => x.text || '').join('') : (b.content || '');
            send({ type: 'tool_result', name: b.name || 'tool', output: trunc(out, 2048), isError: Boolean(b.is_error) });
          }
        }
      } else if (ev.type === 'result') {
        if (typeof ev.result === 'string' && ev.result) finalText = ev.result;
        finish({ type: 'done', result: finalText, turns, durationMs: Date.now() - started });
      }
    }

    const timer = setTimeout(() => { killTree(child); finish({ type: 'error', message: 'Harness run timed out.' }); }, timeoutSec * 1000);
    res.on('close', () => { if (!finished) { killTree(child); finish({ type: 'error', message: 'Cancelled.' }); } });

    child.stdin.end(prompt); // the prompt goes in on stdin
  }
}

// ── server ─────────────────────────────────────────────────────────────────────────────────────────────────────
function sendJSON(res, status, obj) {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(obj));
}

function log(msg) {
  console.log(`[${new Date().toLocaleTimeString()}] ${msg}`);
}

// Read a POST body up to MAX_BODY, as UTF-8, then call cb(body). 413s if it overflows.
function readBody(req, res, cb) {
  let body = '', size = 0;
  req.setEncoding('utf8');
  req.on('data', (c) => {
    size += Buffer.byteLength(c);
    if (size > MAX_BODY) { sendJSON(res, 413, { error: 'Request too large.' }); req.destroy(); return; }
    body += c;
  });
  req.on('end', () => { if (!res.headersSent) cb(body); });
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
    // Run every probe in parallel, each with its own timeout, so one slow one (torch import, WSL cold start)
    // never blocks the others or the whole response.
    const withTimeout = (p, ms, fallback) => Promise.race([p, new Promise((r) => setTimeout(() => r(fallback), ms))]);
    Promise.all([
      withTimeout(claudeStatus(), 8000, { loggedIn: false, error: 'timeout' }),
      withTimeout(codexStatus(), 8000, { installed: false, loggedIn: false }),
      withTimeout(whisperProbe(), 25000, { available: false, model: 'large-v3-turbo', device: null, error: 'probe timed out' }),
      withTimeout(sandboxProbe(), 25000, { available: false, distro: SANDBOX, tools: [], error: 'probe timed out' }),
      withTimeout(harnessStatus(), 25000, { available: false, loggedIn: false, claudeVersion: null, error: 'probe timed out' }),
    ]).then(([claude, codex, whisper, sandbox, harness]) =>
      sendJSON(res, 200, { ok: true, name: os.hostname(), version: VERSION, claude, codex, whisper, sandbox, harness }));
    return;
  }
  if (url.pathname === '/v1/chat' && req.method === 'POST') {
    readBody(req, res, (body) => handleChat(req, res, body));
    return;
  }
  if (url.pathname === '/v1/transcribe' && req.method === 'POST') { handleTranscribe(req, res); return; }
  if (url.pathname === '/v1/files' && req.method === 'POST') { handleFiles(req, res); return; }
  if (url.pathname === '/v1/files' && req.method === 'GET') { handleDownload(req, res, url); return; }
  if (url.pathname === '/v1/extract' && req.method === 'POST') { handleExtract(req, res); return; }
  if (url.pathname === '/v1/shell' && req.method === 'POST') { readBody(req, res, (body) => handleShell(req, res, body)); return; }
  if (url.pathname === '/v1/harness' && req.method === 'POST') { readBody(req, res, (body) => handleHarness(req, res, body)); return; }
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
