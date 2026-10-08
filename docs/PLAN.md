# Synapse — product & build plan

Synapse is an original iOS workspace for notes, docs and databases (the Notion model) with an
Obsidian-style linked-thinking layer on top: `[[wiki links]]`, backlinks, tags and a live graph of
how your notes connect. Its AI runs on **your own Claude subscription** through Claude Code, or on an
Anthropic API key.

---

## 1. How "powered by your Claude subscription" works

Anthropic's terms ([Claude Code legal & compliance](https://code.claude.com/docs/en/legal-and-compliance))
say third-party apps may **not** offer a Claude.ai login inside their own app, may not route requests
through Free/Pro/Max credentials on a user's behalf, and may not collect or store Claude.ai tokens.
They explicitly **do** allow a user to sign in to the *unmodified Claude Code binary* with their own
subscription. Apps that copy Claude Code's OAuth client have been blocked since January 2026.

So Synapse never sees a Claude password or token:

```
 iPhone: Synapse app ──HTTPS/HTTP + pairing token──▶ Synapse Bridge (your PC/Mac/server)
                                                      └─ spawns the official `claude` CLI
                                                         (signed in with YOUR Claude account
                                                          via Anthropic's own `claude auth login`)
```

* **Synapse Bridge** (`bridge/`): a small Node server you run on your own computer. It checks
  `claude auth status`, shows which Claude account it is signed in as, prints a pairing QR code, and
  serves streamed AI requests by running `claude -p` with no tools. Usage is billed to your
  subscription, the same as typing into Claude Code yourself.
* **"Connect Claude"** in the app scans that QR (or takes a `synapse://pair?...` link). Over Tailscale
  it works away from home too.
* **Anthropic API key** is the second provider. The key is stored in the iOS Keychain and requests
  go straight to `api.anthropic.com`. Use it when the bridge is unreachable or for other testers.
* Default model: Claude Opus 5.5 (`claude-opus-5-5`), selectable per provider.

## 2. Notion, studied: features and where they land

Status legend: ✅ in v0.1 (this build) · 🟡 partial in v0.1 · 🔜 planned (phase noted)

### Workspace & navigation
| Notion feature | Synapse | Status |
|---|---|---|
| Sidebar page tree, unlimited nesting, expand/collapse | Home ▸ Pages tree | ✅ |
| Favorites | Star a page; Favorites section | ✅ |
| Add sub-page / move page / duplicate / delete from the tree | Context menus + "Move to" sheet | ✅ |
| Drag pages to reorder / re-parent | Drag & drop on tree rows | 🟡 re-parent by drop; reorder P2 |
| Home: recents ("Jump back in"), upcoming dates, my tasks | Home dashboard | ✅ |
| Quick Find / search (⌘K) with recents | Search tab: titles + full text, snippets, filters | ✅ |
| Trash with restore / delete forever | Trash | ✅ |
| Page history / version restore | Snapshots every 10 min of editing, restore | ✅ |
| Templates gallery | Built-in templates (meeting notes, journal, tasks DB, reading list, project tracker, habit tracker, CRM, wiki) | ✅ |
| Teamspaces, sharing, permissions, guests, real-time co-editing | iCloud/CloudKit shared workspaces | 🔜 P4 |
| Inbox & notifications | Reminders on date mentions + comment activity | 🔜 P3 |
| Sidebar tabs, dashboards (Notion 3.4, 2026) | Home widgets; dashboard view | 🔜 P3 |
| Offline mode | Local-first: everything works offline | ✅ |
| Import (Markdown, Notion export, Obsidian vault) | Markdown files / folders | ✅ |
| Export (Markdown, PDF, HTML) | Markdown vault (.zip) ✅, PDF/HTML 🔜 P2 | 🟡 |
| Publish to web (Notion Sites) | Share as HTML page | 🔜 P3 |

### Pages
| Notion feature | Synapse | Status |
|---|---|---|
| Page icon (emoji) & cover (colour/gradient/image) | Emoji picker, gradient covers, photo covers | ✅ |
| Full width, small text, font (Default / Serif / Mono) | Page ▸ ••• menu | ✅ |
| Lock page | Read-only lock | ✅ |
| Breadcrumbs | Path header + breadcrumb block | ✅ |
| Backlinks | Linked + unlinked mentions panel | ✅ |
| Comments & discussions (page and block level) | Comments sheet with block anchors, resolve | ✅ |
| Copy link to page | `synapse://page/<id>` deep links | ✅ |
| Page tabs (2026) | 🔜 P3 |

### Block editor
| Notion feature | Synapse | Status |
|---|---|---|
| Text, H1–H3, bulleted, numbered, to-do, toggle, quote, callout, divider | All | ✅ |
| Toggle headings | Collapse any heading | ✅ |
| Code block with language | Monospace block with language picker | ✅ (syntax colours P2) |
| Image (photo library / camera / URL) with caption | ✅ |
| Web bookmark, embed, file | Link cards; files via Files app | 🟡 rich previews P2 |
| Simple table (header row, add/remove rows & columns) | ✅ (merged cells P3) |
| Equation block & inline `$math$` | Rendered as formatted TeX source | 🟡 typeset P2 |
| Link to page / sub-page / inline database blocks | ✅ |
| Table of contents, breadcrumb blocks | ✅ |
| Slash commands with filtering | `/` menu above the keyboard | ✅ |
| Markdown shortcuts (`#`, `-`, `1.`, `[]`, `>`, `---`, ```` ``` ````) | ✅ |
| Turn into, duplicate, delete, move up/down, drag reorder | Block menu + drag handle | ✅ |
| Indent / outdent (nesting) | Tab-style indent buttons | ✅ |
| Text & background colours | Block-level colours | ✅ (inline colour P2) |
| Inline bold / italic / underline / strike / code / highlight / link | Formatting bar + live markdown | ✅ |
| @-mentions: pages, dates | `[[page]]` links and `@2026-10-08` dates | ✅ (reminders P3) |
| Synced blocks, buttons, columns, tabs block, HTML block, mermaid | 🔜 P2–P3 |

### Databases
| Notion feature | Synapse | Status |
|---|---|---|
| Full-page and inline databases; every row is a page | ✅ |
| Properties: title, text, number (formats), select, multi-select, status, date (ranges, time), person, files, checkbox, URL, email, phone, formula, relation, rollup, created/edited time, unique ID | ✅ |
| Views: table, board, list, gallery, calendar, timeline, chart | ✅ table/board/list/gallery/calendar/chart · 🔜 timeline P2, map/feed P3 |
| Filters (all/any), sorts (multi), group by, hide properties, view-level settings | ✅ (nested filter groups P2) |
| Formulas (Notion 2.0 syntax incl. `prop()`, `if`, dates, lists, method calls) | Own formula engine | ✅ |
| Relations (two-way) & rollups (count, sum, average, min, max, show original…) | ✅ (two-way sync P2) |
| Database templates / row templates | 🔜 P2 |
| Forms, automations, AI autofill | 🔜 P3 (autofill P2) |
| Linked database views | Inline block pointing at any database | ✅ |

### AI (Notion AI → Synapse AI on Claude)
| Notion feature | Synapse | Status |
|---|---|---|
| Ask AI over your workspace (Q&A with sources) | "Ask Synapse": retrieves relevant pages, cites `[[pages]]` | ✅ |
| Writing actions: improve, fix spelling, shorter, longer, tone, simplify, translate, summarize, explain, action items, continue writing, brainstorm, outline | On any block or the whole page; replace / insert below | ✅ |
| AI blocks / page summaries | Summarize page into a callout | ✅ |
| Database AI autofill | 🔜 P2 |
| Agents that act on pages | Claude proposes edits, you apply | 🔜 P3 |
| AI meeting notes (transcribe + summarize) | On-device speech → Claude summary | 🔜 P3 |

## 3. The Obsidian layer (original to Synapse)
* `[[Page]]`, `[[Page|alias]]`, `[[Page#Heading]]` links typed inline, with autocomplete on `[[`.
  Links to pages that don't exist yet are shown as "unresolved" and created on tap.
* `#tags` and nested tags (`#project/alpha`), tag browser.
* Backlinks: linked mentions with context, unlinked mentions with one-tap "link it".
* **Neural Graph**: a force-directed graph of every page, link, tag and database relation. Pan,
  pinch-zoom, tap to focus a node and its neighbours, double-tap to open. Global or local graph
  (depth 1–3), filters (tags, orphans, unresolved, rows), colour by type or tag, node size by degree.
* Daily notes (one tap "Today"), aliases, Markdown vault export/import compatible with Obsidian
  (frontmatter properties, callouts `> [!note]`, foldable toggles `> [!toggle]-`, `$$` math).
* **Synaptic suggestions** (AI): Claude reads a page and proposes `[[links]]` to related notes.

## 4. Architecture
```
synapse/
├─ SynapseKit/        Swift package, Foundation only (also builds & tests on Linux)
│   models (Page, Block, Database, PropertyValue), Workspace operations, inline-Markdown
│   tokenizer, Markdown import/export, wiki-link index & backlinks, graph builder + force layout,
│   formula engine, database query engine (filter/sort/group/rollup), search, AI prompts, templates
├─ Synapse/           SwiftUI iOS app (iOS 18+, iPhone + iPad)
│   WorkspaceStore (JSON-per-page persistence, debounced saves, history snapshots),
│   block editor (UITextView per block with live Markdown styling), database views,
│   graph canvas, AI providers (bridge / API key), settings, import/export
├─ bridge/            Synapse Bridge — Node ≥ 20, runs the official Claude Code CLI
├─ project.yml        XcodeGen spec (the .xcodeproj is generated in CI, never committed)
└─ .github/workflows  ci.yml (SynapseKit tests on Linux + iOS simulator build), testflight.yml
```
* **Storage**: local-first. `Documents/Synapse/pages/<uuid>.json` per page plus `workspace.json`;
  page history in `Documents/Synapse/history/`; images in `Documents/Synapse/assets/`. The Documents
  folder is visible in the Files app. Markdown is an import/export format, not the source of truth,
  so nothing is lost on a round trip.
* **Editor model**: a flat list of blocks with an indent level (Notion's nesting, simpler editing);
  inline formatting is stored as Markdown in each block's text and styled live while you type.
* **Sync (P4)**: CloudKit private database + CKShare for shared pages.

## 5. Build & ship (Apple)
* Team `BXQW8UBNM2`, bundle id `com.everaldtah.synapse`, display name **Synapse**.
* GitHub Actions on a macOS runner: `xcodegen` → `xcodebuild archive` with automatic signing through
  the App Store Connect API key (repo secrets `ASC_KEY_P8`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, the same
  team key used for ZENITH UMBRA iOS) → `-exportArchive` with `destination=upload` → TestFlight.
* App Store Connect needs an app record for the bundle id before the first upload, then an internal
  TestFlight group with you in it.
* `ITSAppUsesNonExemptEncryption = NO` (HTTPS only), so builds skip the export-compliance question.

## 6. Phases
| Phase | Scope |
|---|---|
| **P0 (now)** | Plan, repo, SynapseKit core + tests, app shell, editor, databases, graph, AI (bridge + API), CI, first TestFlight build |
| **P1** | Polish from your TestFlight feedback: editor feel, keyboard, performance on big pages, iPad layout |
| **P2** | Timeline view, row templates, AI autofill, syntax-coloured code, typeset math, PDF/HTML export, synced blocks, columns, web previews, two-way relations |
| **P3** | Reminders/inbox, widgets, share extension (web clipper), Siri/App Intents, Spotlight, dashboards, page tabs, forms, automations, AI meeting notes, publish to web |
| **P4** | iCloud sync + shared workspaces (CloudKit), Mac Catalyst / visionOS |

## 7. Risks
* iOS UI code is only compiled on GitHub's Macs (this PC is Windows): SynapseKit is tested on Linux,
  and every push runs a simulator build before any TestFlight upload.
* Private-repo macOS minutes are metered (10× multiplier). A public repo would make them free.
* The bridge depends on Claude Code's `-p --output-format stream-json` interface; it falls back to
  the final `result` message if partial streaming changes.
