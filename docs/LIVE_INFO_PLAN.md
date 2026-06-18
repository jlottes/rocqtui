# Live info pane — plan

A new always-present message tab (pinned **second**, right after Rocq
feedback) that anticipates the `About`/`Print` queries: it shows the
`About` result for the identifier under the cursor, updating live as you
navigate, with a collapsible affordance that expands to the `Print`
(definition) result.

## Decisions (settled with user)

- **Live scope:** `About` fires live (per cursor settle). `Print` fires
  only when the user expands the collapsible, and is then cached.
- **Display:** No "smart merge" in the first pass. Collapsed shows the
  `About` output; expanding fires `Print` and the `Print` output **fully
  replaces** the body (it largely subsumes `About`). A cosmetic merge is
  a possible later refinement.
- **State is global** (per `feedback_prefer_global_state`): the pane and
  its subject live in one module, survive tab switches, and remember
  which session/tip a result came from.

## What already exists (no new plumbing needed)

- **Query path:** `Session.query ?extra_opts ?on_done t phrase`
  (`lib/session.ml:1043`). With `on_done` it uses the `Qr_external`
  reply mode: the callback receives `Pp.t list` and the editor's own
  `t.msgs` are restored afterward — so a live query never clobbers the
  Rocq feedback tab. The query runs only when the session is idle
  (pull-style via `pending_query`); **second calls while a query is
  pending are silently dropped** — so live queries and user `^A`/`^D`
  can't stomp each other, but a dropped live query must be retried.
- **Idle gate:** `Session.is_busy : t -> bool` (`lib/session.mli:59`).
- **Identifier under cursor:** `Highlight.qualid_at_cursor`
  (dotted names) → `Buffer.word_at_cursor` fallback, already composed in
  `Modals.query_subject` (`lib/editor/modals.ml:3`).
- **Pp → text:** `Session.string_of_pp ?width : Pp.t -> string`
  (`lib/session.mli:55`).
- **Syntax highlighting of a snippet:** `Highlight.highlight_buffer :
  Buffer.t -> span list array` (`lib/highlight.mli`) — build a throwaway
  `Buffer.t` from the result text, highlight, map spans into
  `Styled.line`s.
- **Message tabs:** `lib/msg_pane.ml` — ordered `kind` list, `Rocq` is
  "first" only because it's `ensure`d every frame. Content model is
  `Styled.line list` (rich spans). Adding an always-second tab = new
  `kind` + `ensure` after `Rocq` in `view.ml` + a render case.
- **Collapse glyphs:** `▾` / `▸` (`lib/file_tree.ml:646`), reuse verbatim.
- **Print options:** `Printopts.entries` / `toggle` / `to_vernac_sentences`
  / `to_set_options`. Live queries pass current options via
  `~extra_opts`, exactly as `^A`/`^D` do.

---

## Status

- **Phase 1: implemented.** New `lib/live_info.ml` (global state),
  `Msg_pane.Info` (toggleable, pinned just after Rocq when open), live
  cursor-following About, collapse glyph, Enter/Space expand → Print
  (replaces body), syntax-highlighted signature with dimmed prose lines,
  width re-render, keep-last-non-error.
- **Toggle:** `^A` shows/activates the Info pane (inserted right after
  Rocq via `Msg_pane.ensure_after`) without stealing focus, and hides it
  when it's already the active sub-tab. `^W` also closes it, but only
  when it's the focused pane. The manual `About → Rocq pane` query is
  unchanged and still reachable from the `Alt+Q` menu.
- **Re-query key** is `(subject, tip, options)` — re-fires when a symbol
  becomes defined (tip advances) or print options change. Collapse state
  is preserved across same-subject re-queries.
- Error detection: **content-based**, confirmed by probe — `About
  <unknown>.` returns `Good` with `"… not a defined object."` as a
  feedback message (no `Fail`, no bridge `error`), so threading a
  protocol status was dropped in favour of `looks_like_error` text
  matching. `on_done : Pp.t list -> unit` left unchanged.
- Tick is gated on the Info tab being the **visible** sub-tab, so we
  don't churn the STM with queries while it's hidden.
- Phases 2 (pin) and 3 (pinned list) remain TODO.

## Phase 1 — live About pane (MVP)

### New module `lib/live_info.ml` (global state)

Store the **raw `Pp.t list`**, not rendered lines — so we can re-format
at the live pane width every frame, exactly as the goals/messages panes
do (they call `Session.string_of_pp ~width` fresh each render against the
session's stored `Pp.t list`; see `lib/view.ml:256-258,410`).

```
type result = {
  subject   : string;             (* identifier queried *)
  about_pp  : Pp.t list;          (* raw; About output *)
  print_pp  : Pp.t list option;   (* raw; lazy, None until expanded *)
}

(* width-keyed render cache, recomputed only when width or source pp
   changes (highlighting runs the Rocq lexer, so don't redo per frame) *)
mutable rendered  : { width : int; lines : Styled.line list } option

mutable current   : result option (* last NON-ERROR result, kept up *)
mutable expanded  : bool          (* collapsed = About, expanded = Print *)
mutable wanted    : string option (* subject we want shown but haven't
                                     successfully queried yet (retry) *)
mutable src_session : Session.t option (* which session produced current *)
```

Key functions:
- `set_subject : Session.t -> string -> unit` — record desired subject;
  no-op if equal to `current.subject` (dedupe). Resets `expanded`.
- `tick : Session.t option -> unit` — called each frame from the editor
  update loop. If not pinned, recompute the qualid at the focused script
  cursor and `set_subject`. If `wanted <> None` and `not (is_busy)` and
  no `pending_query`, issue the About query (below).
- `request_print : unit -> unit` — on expand, if `print_lines = None`
  and idle, fire `Print`.

### Issuing a live query

```
Session.query session
  ~extra_opts:(Printopts.to_set_options ())
  ~on_done:(fun pp_list ->
     let text = format pp_list in        (* string_of_pp per line *)
     Live_info.deliver `About text)
  ("About " ^ subject ^ ".")
```

`deliver` stores the raw `about_pp` into `current` and clears `wanted` —
**only if the query succeeded**. Highlighting/classification happens
lazily at render time (see below), since it depends on width.

### Keep the last non-error result (settled with user)

Navigating off an identifier, onto Vernacular keywords (`Ltac`, …), or
into a proof body where most tokens aren't global references → `About`
yields an error or nothing. **Never show that.** Policy: only a
successful `About` ever replaces `current`; an error/empty result is
discarded and the previous good result stays on screen. (Cursor on a
non-identifier produces no `wanted` at all, via `qualid_at_cursor =
None`, so that case is already covered.)

**Getting the error signal.** Today `Qp_query` matches the response as
`Some _`, so both `Good` and `Fail` reach `deliver_query_result` → the
`on_done` callback as a plain `Pp.t list` — no success flag. Two ways to
get one:

1. **Thread Good/Fail status to the callback (preferred, clean).**
   Split the `Some _` match in `Qp_query` into `Good`/`Fail`, carry an
   `ok:bool` into `deliver_query_result`, and extend the `Qr_external`
   callback to `ok:bool -> Pp.t list -> unit`. One other caller
   (`lib/mcp_server.ml`, the MCP path) updates trivially — and it likely
   *wants* the flag too (cf. the recent "explicit error field on query
   timeout" work).
2. **Heuristic fallback** if About-on-unknown actually returns `Good`
   with the error as feedback text: match known patterns
   (`was not found`, `Syntax error`, `Unbound`, `^Error:`).

**Verify first** (per `feedback_log_dont_guess`): log whether
`About <unknown>.` comes back `Good` or `Fail` before committing to (1)
vs (2).

### Line classification (cheap heuristic, no real parsing)

- **Signature block:** the leading lines up to the first blank line →
  run through `highlight_buffer`.
- **`Arguments …` lines:** highlight the part after `Arguments`.
- **Info lines** (dimmed, plain): lines matching known prose patterns —
  `^<subject> is `, `^Expands to:`, `^Declared in `,
  `is (not )?universe polymorphic`, `is (transparent|opaque)`.

Keep the patterns in one list, easy to tune once we see real output.

### Rendering (`lib/view.ml`)

- Add `Info` to `Msg_pane.kind`; `ensure` it right after `Rocq` in the
  tab-update pass; add a render case that draws:
  - **header line:** `▸`/`▾` collapse glyph + pin glyph + subject.
  - **body:** the rendered `current` (About, or Print when `expanded`).
  - Reuse the existing `render_text_pane` with the tab's
    `scroll`/`sel`/`lines_cache`.
- **Width re-render (settled with user):** compute
  `width = pp_width_for_pane r PMessages` (same call the messages pane
  uses). If `rendered = None`, width differs from `rendered.width`, or
  the source `Pp.t list` changed, then: `Session.string_of_pp ~width`
  each line → classify → `Highlight.highlight_buffer` the signature
  lines → cache as `rendered`. Otherwise reuse the cache. This mirrors
  how goals/messages reflow on pane resize, while skipping the lexer on
  unchanged frames.

### Interaction

- When focus = `FMessages` and active tab = `Info`: **Enter/Space
  toggles** `expanded` (and triggers `request_print` on first expand).
- A live query is issued from `tick`; user `^A`/`^D` still go to the Rocq
  tab unchanged.

### Wiring the tick

Call `Live_info.tick (Tab.current_session ())` from the per-frame editor
update (same place `view.ml` ensures/updates the other msg tabs). Dedupe
ensures at most one query per identifier change, and the idle gate +
retry-on-`wanted` handles the "dropped while pending" case.

**Phase 1 deliverable:** cursor-follow About pane, syntax-highlighted
signature, collapse glyph, expand-to-Print that replaces the body.

---

## Phase 2 — pinning

- `mutable pinned : pin option` where
  `pin = { subject; session; tip; opts_gen; result }`.
- A key (when Info tab focused) toggles pin. Visual marker (settled):
  - **Not pinned:** `◌` (U+25CC dotted circle), faint — reads as an
    empty slot / "click to pin".
  - **Pinned:** `📌` (U+1F4CC pushpin) — deliberately loud, signals the
    live update is frozen.
  - `📌` is double-width; **pad `◌` to two columns** so the header
    doesn't shift by a column on toggle.
  - Shape difference (hollow vs filled) carries the meaning, not just
    color — avoids the "is this the button or the state?" ambiguity.
- While pinned, `tick` does **not** follow the cursor.
- **Global:** switching tabs leaves the pinned item visible (state is
  already global).
- **Tip-attached re-query:** remember the originating session + tip.
  - On **print-option change**, re-issue the query at the pinned tip
    (add a generation counter to `Printopts`; invalidate caches when it
    bumps).
  - On **rewind below the pinned tip** (tip invalidated), keep showing
    the last cached result, marked faintly "stale" — satisfies "leave
    the pinned item visible after rewind".

---

## Phase 3 — stretch: pinned list

- A list of `result`s below the main item.
- `+` appends the current top item; `x` removes a list entry.
- Per-item collapse level cycling: **type only → +definition →
  +info lines**.
- Each entry carries its own pin context (session/tip/opts) so the
  list survives navigation and re-queries on option change like Phase 2.

---

## Open implementation questions (resolve during Phase 1)

1. **Debounce:** dedupe-by-subject may be enough; if navigation thrashes
   the STM, add a small settle delay before issuing.

Resolved:
- *Non-identifier / error results* → keep the last non-error result on
  screen (see "Keep the last non-error result").
- *Width* → re-render at the live pane width like goals/messages (see
  "Width re-render"); store raw `Pp.t list`.
