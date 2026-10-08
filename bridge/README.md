# Synapse Bridge

Synapse Bridge lets the Synapse iOS app use **your own Claude subscription**. It runs the official Claude Code
CLI on your computer, signed in with your Claude account, and streams the replies to your phone.

- You sign in with Anthropic's own flow (`claude auth login`). The bridge never reads, stores or sends your
  Claude credentials.
- Claude Code runs unmodified, in print mode (`claude -p`), with **all tools turned off**. It only writes text and
  can't touch your files or run commands.
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
| `--max 2` | Concurrent Claude runs |
| `--new-token` | Make a new pairing token (unpairs phones) |
| `--login` | Run `claude auth login` first |
| `--show-token` | Print the full pairing link |

The token is stored in `~/.synapse-bridge/config.json`. Every request needs it as a `Bearer` token.

### API

- `GET /v1/health` returns the bridge name and version, plus the signed-in Claude account (email and plan, never
  tokens).
- `POST /v1/chat` takes `{ system, messages: [{role, content}], model?, effort? }` and returns server-sent
  events: `{"type":"delta","text":…}` … `{"type":"done"}`.
