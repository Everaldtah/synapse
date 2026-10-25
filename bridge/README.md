# Synapse Bridge

Synapse Bridge lets the Synapse iOS app use **your own Claude subscription** (and, optionally, **your ChatGPT
subscription**) for complex AI tasks. It runs the official Claude Code CLI, or the official Codex CLI, on your
computer, signed in with your own account, and streams the replies to your phone. Everyday AI in Synapse runs
on the iPhone itself, so the bridge only sees the heavy requests.

- You sign in with Anthropic's own flow (`claude auth login`). The bridge never reads, stores or sends your
  Claude credentials.
- Claude Code runs unmodified, in print mode (`claude -p`), with **all tools turned off**. It only writes text and
  can't touch your files or run commands.
- Codex runs unmodified (`codex exec`) in a **read-only sandbox** in an empty folder (`~/.synapse-bridge/work`),
  without your Codex config, MCP servers or rules, and saves no session. Both CLIs run in that empty folder.
- Usage counts against the Claude plan signed in on that computer, the same as typing into Claude Code yourself.
  Each person who uses Synapse this way runs their own bridge with their own account.

## Setup

```sh
# 1. Claude Code (https://claude.com/claude-code), then sign in:
claude auth login

# 2. The bridge (Node 20+):
cd bridge
npm install          # optional, only to draw the QR code in the terminal
node synapse-bridge.mjs
```

It prints the Claude account it's using and a **pairing QR code**. In Synapse, open
**Settings › Claude › Scan pairing QR code**. You can also open the printed `synapse://pair?...` link on the
iPhone, or type the address and token under *Pair manually*.

### Away from home

Install [Tailscale](https://tailscale.com) on the computer and the iPhone. The bridge prefers its Tailscale
address (`100.x.y.z`) for the pairing code, so pairing works anywhere. To use HTTPS:

```sh
tailscale serve --bg 7799
node synapse-bridge.mjs --url https://<your-computer>.<tailnet>.ts.net
```

### Options

| Flag | Meaning |
|---|---|
| `--port 7799` | Port to listen on |
| `--host 0.0.0.0` | Interface to bind (`127.0.0.1` to allow only `tailscale serve`) |
| `--url <url>` | Address written into the pairing code |
| `--claude <path>` | Path to the `claude` binary |
| `--codex <path>` | Path to the `codex` binary (optional; for ChatGPT via Codex) |
| `--max 2` | Concurrent Claude runs |
| `--new-token` | Make a new pairing token (unpairs phones) |
| `--login` | Run `claude auth login` first |
| `--show-token` | Print the full pairing link |

The token is stored in `~/.synapse-bridge/config.json`. Every request needs it as a `Bearer` token.

### API

- `GET /v1/health` returns the bridge name and version, the signed-in Claude account (email and plan, never
  tokens), and Codex's status: installed, signed in, the default model from `~/.codex/config.toml`, and the model
  list from Codex's own cache.
- `POST /v1/chat` takes `{ system, messages: [{role, content}], engine?: "claude" | "codex", model?, effort? }` and
  returns server-sent events: `{"type":"meta","engine":…,"model":…}` (the exact model answering),
  `{"type":"delta","text":…}` … `{"type":"done"}`.
