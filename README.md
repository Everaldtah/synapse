# Synapse

**Notes, docs and databases with linked thinking, for iPhone and iPad.**

Synapse brings the Notion model (pages made of blocks, nested pages, and databases with table, board,
calendar and gallery views) together with an Obsidian-style layer: `[[wiki links]]`, backlinks, `#tags`, and
a live **Neural Graph** of how your notes connect. Its AI runs on Claude, either on **your own Claude
subscription through Claude Code** or on an Anthropic API key.

> Status: v0.1, early TestFlight. See [docs/PLAN.md](docs/PLAN.md) for the feature map and roadmap.

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
- **AI (Claude)**: Ask Synapse (questions answered from your pages with `[[citations]]`); improve, fix,
  shorten, lengthen, change tone, translate, summarize, explain, action items, continue writing, brainstorm and
  outline; plus **suggested links** between related notes.
- **Import and export**: Markdown files and Obsidian vaults (including Notion Markdown exports) in, and a zipped
  Markdown vault out.

## How AI uses your Claude subscription

Anthropic doesn't allow third-party apps to offer a Claude.ai login or to use subscription tokens
([terms](https://code.claude.com/docs/en/legal-and-compliance)). It does let you use the **unmodified Claude Code
CLI** signed in with your own account. Synapse works within those terms:

```
Synapse (iPhone) ──pairing token──▶ Synapse Bridge (your computer) ──▶ claude -p  (signed in with YOUR Claude account)
```

1. On your Mac or PC, install [Claude Code](https://claude.com/claude-code) and run `claude auth login`.
2. Run the bridge: `cd bridge && npm install && node synapse-bridge.mjs`.
3. In Synapse, go to **Settings › Claude › Scan pairing QR code**.

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
`ASC_KEY_ID` and `ASC_ISSUER_ID` (an App Store Connect API key with the Admin role), plus an App Store Connect app
record for `com.everaldtah.synapse`.

## License

MIT. Synapse isn't affiliated with Anthropic or Notion. Claude and Claude Code are trademarks of Anthropic.
