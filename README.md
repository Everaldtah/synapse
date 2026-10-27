# Synapse

**Notes, docs and databases with linked thinking, for iPhone and iPad.**

Synapse brings the Notion model (pages made of blocks, nested pages, and databases with table, board,
calendar and gallery views) together with an Obsidian-style layer: `[[wiki links]]`, backlinks, `#tags`, and
a live **Neural Graph** of how your notes connect. Everyday AI (transcripts, meeting notes, summaries, rewrites)
runs **on the iPhone** with Apple Intelligence; complex tasks go to **your own Claude or ChatGPT subscription**
through Synapse Bridge, an Anthropic API key, or a **free API provider** (NVIDIA NIM, Groq, Gemini, OpenRouter…).
**Agents** do multi-step work for you inside the app: research, writing, databases, the graph, files and code.

> Status: v0.4, early TestFlight. See [docs/PLAN.md](docs/PLAN.md) for the feature map and roadmap.

## Agents (v0.4)

The **Agents** tab is a set of AI agents you chat with. Each works in steps with tools and shows every step:

- **Synapse Agent** (does anything in the app), **Researcher**, **Graph Architect**, **Analyst**, **Presenter**,
  **Coder** and **Browser** ship built in; make your own with a name, emoji, instructions, a model and the tools it
  may use.
- **Browser (Computer)**: the Browser agent uses the app's own web browser (WebKit — the same engine as Chrome and
  Safari on iPhone) like a person: opens sites, reads a numbered map of what's on the page, taps, types, scrolls. You
  watch it live in the chat and full-size under Agents › **Computer**, with every tap ringed and every keystroke
  shown; you can take over the page yourself at any time. Vision models also get a screenshot after each action;
  text-only models work from the page map. Everything runs on the iPhone.
- **Controls the app**: lists, searches and reads pages; creates, edits, renames, moves and trashes them; links
  pages with `[[links]]` and `#tags`; builds databases (typed columns) and adds or updates rows; writes to the daily
  note; opens pages and tabs.
- **Shapes the graph**: an overview of hubs, orphans, tags and unlinked mentions; Obsidian-style graph settings it
  (and you, in the graph's new settings sheet) can change — filters, colour groups (`tag:`, `path:`, `kind:`,
  `title:`, `line:` queries), node size, link thickness, text fade, arrows, and the forces.
- **Makes files**: Excel spreadsheets (several sheets, live formulas), PowerPoint decks (six themes, speaker notes),
  Word documents and PDFs, all generated on the iPhone; any page can be exported the same way from its ••• menu.
  Files open in Quick Look, share anywhere, and live in Files › Synapse › Agent Files.
- **Web and terminal**: web search and page reading from the iPhone; a Linux shell on the iPhone (Alpine, via iSH;
  downloaded once, 107 MB, the first time an agent or you run a command) or in the bridge computer's sandbox, plus
  Claude Code there for hard tasks. Files the shell makes come back into the app. The **Terminal** screen is an
  interactive bash on the iPhone's Linux (and a command runner for the computer's sandbox).
- **Attachments of any type**: documents (PDF, Word, PowerPoint, Excel, text, code, archives), photos (OCR, and
  sent as images to vision models), scans, voice recordings and audio/video (transcribed).
- **Any model, per chat**: on-device (Apple's model or a downloaded MLX model), Claude or ChatGPT subscriptions,
  the Claude API, or any API provider; small models get a shorter tool list automatically.
- **Agents ask agents** (`ask_agent`), optional **ask before changes**, and **Undo changes** on any reply that
  edited your workspace.

### Free API providers

Settings › API providers lists OpenAI-compatible providers with free tiers, checked on 26 October 2026: NVIDIA NIM,
Groq, Google Gemini, OpenRouter (`:free` models), Mistral, Cloudflare Workers AI, Z.ai GLM Flash, Cohere (trial),
OVHcloud AI Endpoints (no key), LLM7, Kilo Gateway, Requesty, Vercel AI Gateway, SambaNova, Ollama Cloud and
Pollinations; plus bring-your-own-key providers (xAI Grok, DeepSeek, Moonshot Kimi, Cerebras, Together, Fireworks,
Hugging Face, Alibaba Qwen, OpenAI) and any server of your own (LM Studio, Ollama, vLLM). Paste a key, test it,
star models: starred models appear in every model picker. Free tiers change often, so Synapse also loads each
provider's live model list. (xAI's Grok API has no free tier; Groq, with a q, does.)

## Features (v0.1)

- **Block editor**: text, headings, to-dos, bullets, numbers, toggles, quotes, callouts, dividers, code, equations,
  images, bookmarks, tables, page links, sub-pages, inline databases, table of contents, breadcrumbs.
  Includes the `/` menu, Markdown shortcuts as you type, a formatting bar, indent/outdent, drag to reorder, colours
  and block comments.
- **Pages**: nest them without limit, with icons, covers, favourites, full width, small text, fonts (default, serif
  or mono), page lock, version history, trash and restore, templates, daily notes, and Markdown export.
- **Databases**: every row is a page. Properties cover text, number, select, multi-select, status, date, person,
  files, checkbox, URL, email, phone, **formula**, **relation** (two-way), **rollup**, created/edited time and
  unique ID. There are table, board, list, gallery, calendar, timeline and chart views, plus filters, sorts,
  grouping and hidden properties.
- **Linked thinking**: `[[Page]]`, `[[Page|alias]]` and `[[Page#Heading]]` links with autocomplete, backlinks
  plus unlinked mentions, `#nested/tags`, aliases, and a local or global force-directed graph.
- **AI, local first**: improve, fix, shorten, lengthen, change tone, translate, summarize, explain, action
  items, continue writing, brainstorm and outline run on Apple's on-device model (≈3B parameters, 4K-token window).
  Ask Synapse (questions answered from your pages with `[[citations]]`), **suggested links**, long pages and
  deep-reasoning requests go to the cloud model you pick. A model chip on every AI screen (and `/model`) shows
  which model is answering and opens the switcher, with each model's size, context window and strengths.
- **Meeting notes**: record (keeps going with the screen locked) or import audio, transcribe on device with
  Apple's SpeechAnalyzer, and get a summary, key points, decisions and to-dos. Long recordings are noted in parts
  that fit the on-device model, then merged. `/meeting` in a page, or **Record** on Home.
- **Import and export**: Markdown files and Obsidian vaults (including Notion Markdown exports) in, and a zipped
  Markdown vault out.

## Where AI runs

| Mode | Everyday work | Complex work |
|---|---|---|
| On-device first (default) | Apple Foundation Model on the iPhone | Your cloud model (falls back to it if the device model can't) |
| On-device only | iPhone | iPhone, with trimmed context |
| Cloud only | Cloud | Cloud |

Cloud models: Claude through Claude Code (your Claude plan), GPT models through Codex (your ChatGPT plan), or the
Claude API with your key. Transcription always runs on the iPhone. Needs iOS 26 and Apple Intelligence (iPhone 15
Pro or newer; built for iPhone 16 Pro Max and up).

## How AI uses your Claude subscription

Anthropic doesn't allow third-party apps to offer a Claude.ai login or to use subscription tokens
([terms](https://code.claude.com/docs/en/legal-and-compliance)). It does let you use the **unmodified Claude Code
CLI** signed in with your own account. Synapse works within those terms:

```
Synapse (iPhone) ──pairing token──▶ Synapse Bridge (your computer) ──▶ claude -p  (signed in with YOUR Claude account)
```

1. On your Mac or PC, install [Claude Code](https://claude.com/claude-code) and run `claude auth login`.
2. Run the bridge: `cd bridge && npm install && node synapse-bridge.mjs`.
3. In Synapse, go to **Settings › Cloud connection › Scan pairing QR code**.

For ChatGPT, also install the [Codex CLI](https://github.com/openai/codex) (`npm i -g @openai/codex`), run
`codex login`, and pick **ChatGPT subscription (via Codex)** in the model switcher.

Synapse never sees your Claude password or tokens. Use [Tailscale](https://tailscale.com) to reach the bridge
when you're away from home. The other option is to paste an Anthropic API key in Settings (it's stored in the
Keychain).
See [bridge/README.md](bridge/README.md).

## Repository

| Path | What |
|---|---|
| `SynapseKit/` | Swift package with no UI: models, Markdown, links, graph layout, formulas, database queries, search, AI prompts, templates. Builds and tests on Linux. |
| `Synapse/` | SwiftUI iOS app (iOS 18+). |
| `bridge/` | Synapse Bridge (Node ≥ 20). |
| `project.yml` | XcodeGen spec. The Xcode project is generated, not committed. |
| `.github/workflows/` | `ci.yml` (tests + simulator build) and `testflight.yml` (archive → App Store Connect). |

### Build locally (Mac)

```sh
brew install xcodegen
xcodegen generate
open Synapse.xcodeproj
```

### Tests

```sh
swift test --package-path SynapseKit
```

### TestFlight

Run the **TestFlight** workflow (Actions tab), or push a `v*` tag. It needs the repo secrets `ASC_KEY_P8`,
`ASC_KEY_ID` and `ASC_ISSUER_ID` (an App Store Connect API key with the Admin role). The App Store Connect record is
**Synapse Notes** (`com.everaldtah.synapse`; "Synapse" was taken on the store, but the home-screen name is Synapse), and
builds go to the internal group **Synapse testers**. `tools/asc/asc.py` is a small App Store Connect API client.

## License

GPL-3.0 (since v0.3.1, because Linux on the iPhone uses iSH, which is GPL-3.0; earlier versions were MIT). Synapse isn't affiliated with Anthropic or Notion. Claude and Claude Code are trademarks of Anthropic.
