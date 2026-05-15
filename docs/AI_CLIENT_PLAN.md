# rocqtui ↔ ai-bridge wiring — plan

Status: design draft. No rocqtui-side code yet. Companion to
[`AI_SUGGESTIONS_PLAN.md`](AI_SUGGESTIONS_PLAN.md) (overall design,
Phase 0 measurements) and
[`AI_BRIDGE_PLAN.md`](AI_BRIDGE_PLAN.md) (the bridge subsystem).
Read those first.

## Goal: keep this feature isolated

The integration must not leak AI-specific code throughout the
codebase. Every existing module should remain ignorant of AI
suggestions except at well-defined seams. If AI is globally
disabled — or the bridge socket is unreachable — the rest of
rocqtui should behave exactly as it does today, with zero added
overhead beyond a cheap is-enabled check.

The shape of "well-isolated" we're aiming for:

- All new code in **one new namespace** `lib/ai/` (like `lib/editor/`,
  `lib/vterm/`).
- A **small, enumerable set of touch points** in existing modules,
  each justifiable.
- One small refactor of `Region_buffer` to expose generic edit
  history — useful beyond AI.
- Zero new dependencies between unrelated subsystems. The AI
  module reads from existing modules; existing modules don't import
  it.

## Touch-point inventory

This is the integration surface. Every line of AI code outside
`lib/ai/` should fall into one of these.

| # | Where | What | Lines |
|---|---|---|---|
| 1 | `lib/editor_context.ml{,.mli}` | Add `mutable ai : Ai.State.t option` and `mutable last_input_time : float` | ~2 fields |
| 2 | `lib/tab.ml{,.mli}` | Add `ai_tab : Ai.Tab.t`; initialize in `create_blank` / `create_from_file` | ~3 lines |
| 3 | `lib/region_buffer.ml{,.mli}` | Bounded recent-edits ring + getter. **Refactor — see below.** | ~30 lines |
| 4 | `lib/editor/editor.ml` | `handle_global`: one early short-circuit call to `Ai.Action.try_handle`; `handle_event`: one line setting `ctx.last_input_time` | ~2 lines |
| 5 | `lib/view.ml` | End of `render_all`: one call to `Ai.View.draw_overlay` | 1 line |
| 6 | `lib/keys.ml` | New key constants (accept-all, accept-word, accept-line, dismiss, toggle, force-trigger) | ~6 lines |
| 7 | `bin/main.ml` | Startup: open AI client, register fd watch. Per-frame: tick the AI trigger | ~10 lines |

Total non-AI-namespace footprint: **~50 lines of glue**, almost all
trivially reviewable. Everything else lives inside `lib/ai/`.

When AI is disabled globally (`^G`), the glue degrades to:

- (#3) ring keeps recording — cheap, generic, retained anyway as
  potential future-utility.
- (#4) `try_handle` returns `false` immediately.
- (#5) `draw_overlay` is a no-op when `ctx.ai = None` or
  `ai.enabled = false`.
- (#7) trigger tick checks `ai.enabled` first and bails.

## The one refactor: Region_buffer gets a recent-edits ring

`Region_buffer` is already the chokepoint for every text mutation —
keystrokes, MCP edits, paste, undo/redo, file-watch reload, all
route through `try_*`. That makes it the natural place to record
edit history.

Two options were considered:

- **A. Callback registration.** `Region_buffer.on_applied` lets
  consumers subscribe. Requires a callback-list field on the type,
  fan-out at each `try_*` apply site. Couples Region_buffer to a
  subscriber model.
- **B. Passive ring.** Region_buffer keeps a bounded ring of the
  last N applied edits as `(before : string; after : string)` pairs.
  Exposes a getter; nobody subscribes. AI module reads on demand
  when building a request. **Picked this.**

Why B:

- No subscriber infrastructure. Region_buffer stays simple.
- The ring is generic — not "the AI hook." Could be useful for
  audit/debugging/analytics later.
- Read-on-demand matches the bridge's request shape (the AI
  subsystem assembles `recent_edits` only when actually sending a
  request).
- One mutator (each `try_*` apply path appends to the ring), one
  reader. Easy to reason about.

API addition to `Region_buffer`:

```ocaml
(** Bounded ring of recently-applied edits. Most-recent last. *)
type edit_record = { before : string; after : string; at : float }

val recent_edits : t -> edit_record list
val recent_edits_ring_size : int  (* compile-time constant, e.g. 8 *)
```

Implementation: a `Queue` (or just a list with a length cap)
appended to inside each `try_*` apply branch. `before`/`after` are
the substring being replaced and the replacement, captured around
the actual mutation site. Cost: one substring copy per applied
edit. Negligible compared to the edit itself.

This is the **only** existing module that grows new structure.
Everything else is one-line glue.

## `lib/ai/` namespace

Mirroring the `lib/editor/` pattern (`(include_subdirs qualified)`),
so callers see `Ai.State`, `Ai.Client`, etc.:

```
lib/ai/
├── dune
├── state.ml          — global on/off, status, last_request, connection
├── tab.ml            — per-tab state: ghost, edit overlay, in-flight req
├── client.ml         — Unix socket client; speaks the NDJSON v0 protocol
├── trigger.ml        — idle-trigger logic; ticked from main loop
├── action.ml         — try_handle (accept/dismiss/toggle/force); the keystroke surface
├── view.ml           — draw_overlay (ghost text + diff highlights on Render.t)
├── apply.ml          — turn a bridge response into a Region_buffer.try_replace
└── dune
```

Internal module roles:

- **`Client`** owns the socket fd, sends requests, parses NDJSON
  response lines, dispatches into a per-`req_id` handler stored on
  the relevant `Tab`. Lifecycle: opens lazily on first request,
  reconnects on disconnect.
- **`Trigger`** checks `now - ctx.last_input_time > debounce_ms` per
  frame; if AI is enabled and no request is in flight globally and
  the cursor is in a tab-script position, sends a request via
  `Client`. Tab switches cancel any in-flight request from a
  previous tab.
- **`Action.try_handle`** is the *single* keystroke surface. It
  examines the input event, matches against the AI key bindings,
  and either acts (returns `true`) or doesn't (returns `false`).
  All accept-word / accept-line / accept-all / dismiss / toggle
  / force-trigger logic is inside this module. No fanout in
  `handle_global`.
- **`View.draw_overlay`** is the *single* render surface. Reads
  `tab.ai_tab.ghost` and `tab.ai_tab.overlay`, paints to the grid
  using existing `Geom` coordinate helpers. Returns immediately
  when AI is disabled or nothing to draw.
- **`Apply`** is the *single* buffer-mutation surface for AI. Every
  acceptance routes through `Apply.try_apply`, which calls
  `Region_buffer.try_replace` and handles rejection (e.g. edit
  would overlap verified region → drop suggestion, status message).

Each module is a single file, none expected to exceed ~200 lines.

## Data flow

### Cold start (rocqtui boots, AI bridge running)

1. `bin/main.ml` constructs `Editor_context`. AI is feature-detected
   from a config flag (`Config.ai_enabled : bool`, default true) and
   the socket path is read from env (`AI_BRIDGE_SOCKET`) or a
   default (`$XDG_RUNTIME_DIR/rocqtui-ai-bridge.sock`).
2. `ctx.ai <- Some (Ai.State.create ~socket_path)`.
3. AI client lazily connects on first request, registers fd watch
   via `Main_loop.add_watch` to receive streamed responses.
4. Status indicator in chrome reflects `Ai.State.status` —
   `[AI ●]`, `[AI ◐]`, `[AI ✦]`, `[AI ○]`, `[AI !]`.

### Idle trigger → suggestion arrives

1. User types in script pane. `Editor.handle_event` updates
   `ctx.last_input_time`. `Region_buffer.try_insert_char` runs
   normally; its ring appends an edit record.
2. User stops typing. Each frame, `Ai.Trigger.tick ctx` checks
   debounce. After 300 ms idle: it cancels any in-flight request
   (`Client.cancel`, which closes the socket connection — per the
   bridge protocol), then opens a new connection and writes a
   request built from `(buffer, cursor, recent_edits)`. The
   in-flight request id is held globally on `Ai.State`, along
   with the `tab_id` it targets so responses can be routed back.
3. The fd watch fires when the bridge writes its first response
   line. `Client.on_data` parses NDJSON lines into
   `(fim insertion | edit change | error | done)` events and
   routes them to the tab's handler.
4. For FIM: `tab.ai_tab.ghost <- Some { text; ... }`. For edits:
   `tab.ai_tab.overlay` accumulates changes as they stream.
5. Next render frame, `Ai.View.draw_overlay` paints them. The
   status indicator flips from ◐ to ✦.

### User accepts (Tab, Alt+→, etc.)

1. Keystroke arrives in `Editor.handle_event`. `Ai.Action.try_handle`
   matches the event. For "accept word": it computes the word
   prefix from `tab.ai_tab.ghost.text`, calls
   `Ai.Apply.try_apply ~range:(cursor, cursor) ~text:word`.
2. `Apply.try_apply` calls `Region_buffer.try_replace`. On
   `Applied`: ghost text shrinks by the accepted prefix, cursor
   advances, ring records the synthetic edit (this matters if the
   user keeps accepting incrementally — each acceptance becomes part
   of recent_edits for the next request).
3. On `Rejected` (e.g. cursor moved into the verified region while
   the request was in flight): drop the ghost, show a status
   message, return `true` from `try_handle` to consume the
   keystroke.

### User keeps typing (implicit dismiss)

1. Any keystroke that isn't an accept/dismiss/toggle key falls
   through `try_handle`. Before returning `false`, the AI module
   wipes `tab.ai_tab.ghost` and `tab.ai_tab.overlay` since they're
   stale.
2. The keystroke proceeds through normal handling. After a new
   idle period, a fresh request goes out.

### Bridge socket dies mid-stream

1. The fd watch's callback gets `read = 0` (EOF). `Client.on_eof`
   marks status `[AI !]` and clears any in-flight handlers.
2. Subsequent requests reconnect lazily. The first failure flips
   the indicator; subsequent failures don't spam log.
3. The rest of rocqtui notices nothing.

### User toggles AI off (^G)

1. `Ai.Action.try_handle` matches. Sets
   `state.enabled <- false`. Wipes ghost / overlay on every tab.
   Closes the in-flight connection if any.
2. Trigger tick bails on the disabled check. View draw is a no-op.

## Key bindings

Per `AI_SUGGESTIONS_PLAN.md`, with conflicts noted there resolved.
Defined in `lib/keys.ml` like any other binding, dispatched by
`Ai.Action.try_handle`:

| Key | Action | Notes |
|---|---|---|
| Tab (when ghost or overlay-site active) | Accept | Conditional on AI state |
| Alt+→ | Accept word | FIM only |
| Shift+→ | Accept line | FIM only (Alt+↓ conflicts with `Step forward`) |
| Esc | Dismiss ghost / overlay | Falls through to existing Esc handling if AI didn't have anything to dismiss |
| ^] / ^[ | Next / previous edit site | Overlay mode |
| ^G | Toggle AI globally | |
| ^G ^Space | Force a suggestion now | Manual trigger |

The Tab binding is the most delicate — it's currently inserted as a
literal tab in the script pane. `Ai.Action.try_handle` consumes Tab
only when there's an active ghost/overlay; otherwise it falls
through and Tab inserts normally.

## Lifecycle and async

- Main loop tick order: existing `select_with_watches` already
  multiplexes stdin, MCP, build, inotify. The AI client's socket fd
  joins this set via `Main_loop.add_watch`. Reads land in
  `Ai.Client.on_data` which dispatches NDJSON lines.
- `Ai.Trigger.tick ctx tab` runs as a single call from
  `bin/main.ml`'s per-frame loop, after handling input events and
  before the render. Bails immediately when AI is disabled, when a
  modal is open, when the script pane doesn't have focus, when a
  request for this tab is already in flight, or when the debounce
  hasn't elapsed.
- Acceptance never bypasses region invariants — every AI-driven
  edit goes through `Region_buffer.try_replace`. If rejected
  (overlap with verified region, etc.), the suggestion is dropped
  with a status message. We don't try to step back the verified
  region to accommodate an AI suggestion.
- The MCP buffer lock interacts naturally: while held, AI accept
  keys still call `try_replace`, which now sees the lock; we either
  defer (queue the accept) or simply drop. **Drop is fine for
  v0** — keeps the AI subsystem from interleaving with bridge
  requests from Claude Code.

## Phasing

### Phase 1 — connectivity + FIM ghost

- All 7 touch points wired up minimally.
- `lib/ai/` modules implemented to FIM-shape only (`edits` responses
  ignored).
- Tab accept-all, Esc dismiss, ^G toggle. Single-line ghost only.
- Status indicator in chrome.
- Region_buffer ring landed and tested.

### Phase 2 — granular accept + multi-line ghost

- Alt+→ accept word, Shift+→ accept line.
- Multi-line ghost rendering (phantom rows below cursor).
- Configurable trigger debounce in `Config`.

### Phase 3 — edits-shape overlay

- Render `edit` overlay (delete-strikethrough + phantom insert
  rows).
- Site navigation (^] / ^[) and per-site accept/reject.
- Streaming overlay — each `edit` response paints as it arrives,
  no batch wait.

### Phase 3.5 — Rocq-aware proof suggestions (optional)

- When cursor is in a proof block (after `Proof.`, before `Qed.`),
  the AI request body includes the current goal text from
  `Tab.session`. New request field `context: { goals: string }`.
- Same trigger / accept paths; the bridge's prompt selection
  changes.
- No new touch points in existing modules.

## Open questions

- **Idle debounce default**: 300 ms is the AI_SUGGESTIONS_PLAN's
  starting guess. Worth exposing in `Config` from day one so it can
  be tuned without rebuild — single config field.
- **Should accept-on-Tab consume Tab in the find/replace panel
  too?** No — the find/replace panel has its own Tab handler (toggle
  Find / Replace field). `Ai.Action.try_handle` should bail when
  `ctx.modal` has anything open or when the find prompt is active.
- **What if a fresh idle trigger fires while a previous response is
  still mid-stream?** Cancel the previous (socket close), start a
  new connection. The bridge handles its half via its own
  cancellation. Per-tab serialization keeps the rendering simple.
- **~~Per-tab vs. global in-flight tracking~~**: resolved —
  **global single-flight** on `Ai.State`. The flexibility of
  per-tab isn't worth the state-shape complexity; the project has
  been through multiple "should have been global, not per-tab"
  refactors (search-state being the most recent). When a tab
  switch happens while a request is in flight, just cancel and
  re-issue. Ghost / overlay are still per-tab (they're bound to a
  specific buffer position).
- **Recent-edits ring size**: 8 in the protocol (the bridge caps
  it too). `recent_edits_ring_size = 8` in `Region_buffer` matches.
- **Recording AI-driven edits in the ring**: keep them, so iterative
  acceptance over a multi-stage refactor accumulates context.
  But mark them with a flag so the bridge could later down-weight
  them in classification heuristics (post-v0).

## Why not a bigger refactor?

The user explicitly asked whether a refactor would help. We
considered three:

- **Generic "edit observer" registry on Region_buffer.** Rejected
  in favor of the simpler passive ring — same use case, no
  subscriber infrastructure.
- **View overlay registry.** Would let `Ai.View` register a draw
  callback alongside other overlays. **Not worth it for one
  consumer.** A single hook line at the end of `render_all` is
  fine.
- **Input pre-handler chain.** Same story — one `Ai.Action.try_handle`
  short-circuit at the top of `handle_global` is simpler than
  inventing a middleware abstraction.

The cost/benefit of those refactors is poor today. If a *second*
consumer of edit history / render overlays / input pre-handling
ever appears, the refactor becomes worth it on its own merits at
that point — not preemptively for AI alone.
