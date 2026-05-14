# Search state model — refactor

Status: design draft. No code yet. Supersedes the state model that
landed with [`PROJECT_SEARCH_PLAN.md`](PROJECT_SEARCH_PLAN.md). Goal
is to fix several composition bugs that surfaced once project-wide
search shipped, by collapsing query and match state onto the correct
scopes instead of patching around the wrong seam.

## Motivation

The current model has [`Tab.search : Search.state option`], where
`Search.state` is one record carrying **both** the query (string,
flags, replacement, focus) and the matches (array, current pointer,
saved cursor). Project mode then layered a second source
(`Project_search.t`) on top, with a per-frame snapshot
(`Editor_context.search`) joining them. The seam between "query" and
"matches" doesn't exist in the type, so the project-mode code has to
work around it. Observed bugs after that landing:

- The prompt's "3/53" counter shows current-tab matches even in
  project mode — because the prompt reads from `Tab.search.matches`
  rather than the global project results.
- F3 in project mode jumps to a different file, but the new tab has
  no `Search.state` populated, so the find field appears empty and
  match highlights are gone in that tab until the user retypes.
- Switching tabs while a search is active throws away the search
  for the new tab unless it had been previously typed in there.
- "Active match" in the current file is often off-screen because the
  prompt's cursor-move-to-match logic doesn't reliably target the
  match nearest the user's pre-search cursor in the new tab.

The right framing: query is **global**, matches are **per-buffer**.
Project mode is just a bit on the global query that affects (a) what
the Search messages tab renders and (b) whether F3 / Shift+F3 walks
across files. The active match always lives in the per-buffer match
list and gets remembered per-tab.

## Data model

### Search module

Split the existing `Search.state` into two records:

```ocaml
(* Global: what we're searching for. One instance lives in
   Editor_context. *)
type query_state = {
  query : string;
  flags : flags;
  replacement : string;
  focus : focus;
}

(* Per-buffer: the matches of the current query in THIS buffer, plus
   the cursor (active match) the user has navigated to within them. *)
type buffer_matches = {
  matches : match_ array;
  mutable current : int;        (* -1 when none / not yet visited *)
  saved_cursor : pos;           (* cursor in this buffer when ^F was
                                   last opened; used by ESC rollback *)
}
```

New public functions:

```ocaml
val empty_query : query_state
val recompute_buffer_matches :
  query_state -> Buffer.t -> anchor:pos -> buffer_matches
(* Build a buffer_matches for [buf] using the current query. [anchor]
   picks the initial [current] — usually the buffer's pre-search
   cursor, or the previous current's position when re-computing
   after an edit. *)
```

The `next` / `prev` helpers on `buffer_matches` are unchanged in
spirit but operate on the new record.

`Search.state` and `update_query` / `update_after_edit` / `set_flags`
/ etc. go away. The new caller side composes: edit the
`query_state`, then call `recompute_buffer_matches` on the active
tab's buffer.

### Active match coherence across recomputes

Recompute happens often (every keystroke in Find, every buffer edit,
flags toggle). The rule for picking the new `current` after a
recompute is **anchor by position, not by index**:

- If the previous `buffer_matches` had `current >= 0`, the anchor is
  the `start_` of that match.
- Otherwise the anchor is the tab's `saved_cursor`.

After recompute, `current` becomes the index of the first match
whose `start_ >= anchor` (wrapping to 0 if none after it). Net
effect on common workflows:

- User is on match 5 (line 100). User types another character that
  prunes matches 1 and 2. The same location (line 100) is still a
  match — now numbered 3. Cursor stays at line 100; the prompt's
  counter changes to `3/N`.
- User is on match 5 (line 100). The refinement kills *that* match
  too. New `current` is the next match at or after line 100.
  Cursor and counter jump forward.
- User had no current (`-1`). New `current` anchors off
  `saved_cursor`, same as today's `update_query` path.

This is the existing `update_after_edit` semantics, applied
uniformly to all recomputes — not just buffer edits. The previous
`update_query` re-anchored to `saved_cursor` instead, which thrashed
the cursor back to the start of the search every time you typed.
The new behaviour is "stick to where you're looking".

### Editor_context

```ocaml
type t = {
  ...
  (* The single source of truth for the search prompt. None = no
     active search. Survives across tab switches. *)
  mutable search_query : Search.query_state option;
  (* Generation counter — bumped on every query/flags change so
     stale per-tab match arrays know to recompute. *)
  mutable search_query_gen : int;
  (* Search scope: when [project_mode], F3 / Shift+F3 walks across
     files via [project_search]; the Search messages tab renders the
     full project_search.results merged with open tabs' live matches.
     When false, F3 stays in the current tab and the Search tab
     shows only the active tab's matches. *)
  mutable project_mode : bool;
  project_search : Project_search.t;
  (* ESC-rollback session: see "ESC semantics" below. *)
  mutable search_session : search_session option;
  ...
}

and search_session = {
  origin_tab_id : int;
  (* Cursor positions to restore on ESC, keyed by tab id. Each entry
     is the cursor at the moment we *first* touched that tab during
     this prompt session (i.e. when ^F was pressed in the origin tab,
     or when F3 jumped to a new tab). *)
  mutable saved_cursors : (int * Search.pos) list;
}
```

### Tab

```ocaml
mutable search_matches : Search.buffer_matches option;
(* matches against ctx.search_query, or None if not computed yet. *)
mutable search_matches_gen : int option;
(* Generation [ctx.search_query_gen] this was last computed against.
   Mismatch = stale. *)
```

### Project_search

Unchanged. Continues to scan files asynchronously and produce a
`Search_results.t` over (project-relative) paths.

## Invariants and refresh policy

**Lazy per-tab match recompute.** A small helper in
`Editor_context` (or a new module) becomes the single accessor:

```ocaml
val tab_matches : t -> Tab.t -> Search.buffer_matches option
```

```ocaml
let tab_matches ctx tab =
  match ctx.search_query with
  | None -> None
  | Some q ->
    if tab.search_matches_gen = Some ctx.search_query_gen
    then tab.search_matches
    else begin
      let anchor = match tab.search_matches with
        | Some old when Array.length old.matches > 0
                        && old.current >= 0 ->
          old.matches.(old.current).start_
        | _ -> Buffer.cursor tab.buf |> pos_of_tuple
      in
      let m = Search.recompute_buffer_matches q tab.buf ~anchor in
      tab.search_matches <- Some m;
      tab.search_matches_gen <- Some ctx.search_query_gen;
      Some m
    end
```

Single code path — every consumer goes through `tab_matches`. No
"set the stale bit" code scattered around; the staleness is implicit
in the generation mismatch.

**When does the global gen bump?** Anywhere the prompt mutates
`search_query`: typing in Find / Replace, Alt+C, Alt+R, Alt+P (the
project_mode bit doesn't actually need to bump matches — its effect
is on stepping/rendering, not the matcher input — but a single
"any prompt change → bump" rule is simpler than carving out which
fields invalidate).

**Buffer edits invalidate too.** Today `Tab.search_state` already
refreshes via `Buffer.revision` mismatch. Same pattern: track
`search_matches_buf_revision`; if it doesn't match the buffer's
current revision, recompute. The check becomes "EITHER gen mismatch
OR buffer-revision mismatch → recompute".

**Project_search.t lifecycle.** Started when `project_mode` flips
on (or the query changes while it's on). Cancelled when
`project_mode` flips off or when ESC clears the search.

**When are non-active open tabs scanned?** Lazily, via the same
`tab_matches` accessor. In single-file mode only the active tab is
ever asked, so the others stay un-computed. In project mode the
Search messages tab's render path iterates all open tabs (to
substitute live matches into the merged stream — see below), which
forces a `tab_matches` call on each. Cached results are reused while
the generation and buffer revision are stable, so steady-state cost
is one O(1) lookup per open tab per render. The first frame after a
query change does the full recompute across open tabs; on typical
projects that's microseconds per file.

**Stable global ordering.** The order of files in the merged stream
must NOT change when the user opens or closes a tab. Concretely: the
order is `project_search.results.files` (which is fixed by
`File_listing.enumerate` for a given filesystem state — unaffected by
tab open/close). The merge rule for a given path:

1. If the path appears in `project_search.results` AND is currently
   open as a tab, the entry is replaced by the tab's live
   `buffer_matches` (so unsaved edits show in results).
2. If the path is in project results but not open, use the project
   entry as-is.
3. If a path is open as a tab but NOT in project results (scratch
   buffer, file outside the project root), it's appended to the end
   of the stream in tab-creation order. Tab close removes its entry;
   tab reopen appends again (so reopening DOES move it to the end,
   but only for these "outside the project" tabs — the common case
   is unaffected).

Net effect: opening or closing a project-listed file doesn't shuffle
its position; the user's "after this match comes that match" mental
model survives.

## UX details

### Typing in the find field

Same in both modes: the matcher runs on the **active tab's buffer**,
and the cursor jumps to the next match. The cursor never crosses
file boundaries from a keystroke. In project mode, `project_search`
runs in parallel against other files, populating the Search messages
tab; the prompt's behavior for the user typing is identical.

The counter:

- Single-file mode: `M/N` where N = active tab matches, M = current+1.
- Project mode: `M/N · G/T` — the current-file pair *plus* the
  global pair, separated by a middle dot. N is the active tab's
  match count, M = current+1; T is total across the project, G =
  global index of the active match = `(sum of fm_matches lengths of
  files appearing before the active path in project_search.results)
  + (active tab current + 1)`. The middle-dot separator is U+00B7.
  Local context always visible; the global pair reads as
  supplementary.

### Cross-file stepping (F3 / Shift+F3)

- Single-file: walks the active tab's `buffer_matches` with wrap.
- Project: walks the merged stream "all matches in scan order":
  open tabs' live matches first (for files in the project), then
  closed-file matches from `project_search.results`. Across-file
  steps switch tabs (opening the file if necessary).

When entering a new tab via F3, the destination tab's
`buffer_matches` is recomputed lazily on access (same path as on
any tab switch), so highlights and the prompt counter stay
consistent.

### Tab switching (manual click / `^P`)

Switching tabs while a search is active is normal: the new tab's
`buffer_matches` is lazily recomputed against the current query, the
cursor stays wherever the new tab's `current` (or `saved_cursor`)
puts it. No special action.

### ESC: rollback semantics

ESC is a global "abandon" — restores all state touched by this
prompt session.

When `^F` is pressed:

- Close any existing session.
- Open a new `search_session`:
  - `origin_tab_id = active tab id`
  - `saved_cursors = [(active_tab_id, current_cursor)]`

When the prompt is open and the user lands on a new tab via F3 or
mouse-click on a Search-tab row:

- Before moving the cursor in the destination tab, append
  `(dest_tab_id, dest_tab_current_cursor)` to `saved_cursors` if not
  already present.

When ESC is pressed:

- Iterate `saved_cursors`, restoring each tab's cursor.
- Switch back to `origin_tab_id`.
- `Buffer.move_to` does not affect tab focus, so this is just a list
  iteration plus one switch.
- Drop `search_query`, `search_matches` on all tabs, the session,
  and cancel `project_search`.
- Tabs that were newly opened during the session (via F3 crossing
  into a file that wasn't open) stay open. Their match arrays are
  thrown away with the search.

When Enter / any non-ESC close is pressed:

- Drop the session (no rollback needed; the user accepted their new
  position).
- Keep `search_query` and the per-tab `search_matches` — F3 outside
  the prompt continues to work.

### Auto-pop of the Search messages tab

Unchanged from current: the first time any matches exist (single or
project mode), `Msg_pane.activate_unless_terminal Search` fires. The
removal-on-clear behavior also unchanged.

### What is the "active match"

There's exactly one active match in the model at any given time, and
it lives in the active tab's `buffer_matches.current`. Concretely:

- **Active match defined**: the active tab has matches AND
  `current >= 0` AND `current < length matches`. The active match is
  `(active_tab_path, current)`.
- **No active match**: the active tab has no matches (typically:
  the current file simply doesn't contain the query). Globally also
  no active match in this case — even in project mode where other
  files have matches.

In the second case, the Search messages tab renders ALL match rows
as non-active (no `▸`, no reverse-video). The user sees the matches
exist in other files; F3 lets them step over and the active match
appears once they land on a tab that has one.

### Keep the active match visible in the Search tab

Same instinct as "ensure cursor visible" in the script pane: when
the active match changes, the Search messages tab scrolls to bring
that row into view if it's off-screen.

Triggers (any of these changes the active match):
- Typing in the Find field (cursor jumps to nearest match in
  current file, so `current` moves).
- F3 / Shift+F3 / replace-current (next/prev within current tab or
  across files).
- Tab switch that lands on a tab with matches (its previous
  `current` resumes, which may differ from where the user last
  looked).
- Click on a Search-tab row.

Mechanism: `Search_tab.render` already returns `(lines,
active_row)`. The render path stores the previous `active_row` and,
when it changes, adjusts the Search tab's scroll the same way
`Build_errors` does for the Errors tab:

```ocaml
if new_active_row <> last_active_row && new_active_row <> None then begin
  match new_active_row with
  | Some ar ->
    let (rows, _) = Render.pane_dims r Render.PMessages in
    if ar < tab.scroll then tab.scroll <- ar
    else if ar >= tab.scroll + rows then
      tab.scroll <- max 0 (ar - rows + 1)
  | None -> ()
end

## Architecture by module

| File | Status | Purpose |
|------|--------|---------|
| `lib/search.ml/.mli` | refactor | Split `state` into `query_state` + `buffer_matches`. Public surface mostly new; old `state` and its setters are gone. |
| `lib/tab.ml/.mli` | modified | Drop `search`/`search_revision`. Add `search_matches`/`search_matches_gen`/`search_matches_buf_revision`. |
| `lib/editor_context.ml/.mli` | modified | Add `search_query`, `search_query_gen`, `search_session`. Drop `search` snapshot field (its readers move to a new `tab_matches`-style accessor). |
| `lib/editor/modals.ml` | rewrite of search-prompt section | All prompt mutations now touch `ctx.search_query`. `dispatched_advance` walks tab matches in single mode, merged stream in project mode. `logical_escape` performs the rollback. |
| `lib/editor/editor.ml` | minor | F3/Shift+F3 still dispatch through `Modals.dispatched_advance`. ^F open now creates a fresh `search_session`. |
| `lib/view.ml` | modified | Prompt rendering reads `ctx.search_query`. Counter logic branches on `project_mode`. The script-pane highlight rendering still pulls from the active tab's `buffer_matches` (via the new accessor). |
| `lib/project_search.ml` | unchanged | Same as today. |
| `lib/search_results.ml` | minor | The `Search_results.advance` API may shift to take "open-tab matches" too, so cross-file walking can prefer live (open-buffer) matches over disk-read ones. Open question below. |
| `lib/search_tab.ml` | minor | In single-file mode, takes only the active tab's `buffer_matches` to render. In project mode, the merged stream. |
| `test/test_search.ml` | rewrite | New types, new behaviour to test. |
| `test/test_search_results.ml` | minor | Adapt to any `Search_results.advance` signature change. |

## Implementation order

1. **Phase 1** — `Search` module refactor + tests. No callers touched
   yet — the new types and helpers exist alongside the old `state`.
   This phase compiles but doesn't ship behavioral changes.
2. **Phase 2** — Migrate `Tab.t` to `search_matches`, and
   `Editor_context.t` to `search_query` + `search_query_gen` + new
   accessor. Delete the old `Search.state`-based API. Touches view.ml
   (prompt rendering, script-pane highlights) and modals.ml's
   single-file prompt handling. Project mode temporarily broken or
   stubbed out; the single-file UX is restored first.
3. **Phase 3** — Re-wire project mode against the new model. The
   merged-stream F3 dispatch lands here; counter logic lands here.
4. **Phase 4** — ESC rollback. `search_session` accumulates touched
   tabs; ESC restores. This is largely a new feature on top of the
   refactored model; doable in a small commit.

Total: 4 commits. Phases 1+2 are the bulk of the change; Phases 3+4
are mostly additive.

## Open questions

- **`Search_results.advance` API.** Currently it advances over
  `t.files` only (project_search results). After the refactor we
  want the dispatcher to walk a merged stream: open-tab live matches
  *plus* closed-file project matches. Two options: (a) keep
  `Search_results` purely "closed files" and have the merge live in
  `modals.ml`, splicing in open-tab matches at the right positions;
  (b) make `Search_results.advance` accept an "override" map of
  path → live matches. I'd lean (a) — the merge is a one-time-per-
  step computation in the dispatcher; `Search_results` stays a pure
  value type for closed files.

- **Saved-cursor key.** I'm using `tab_id : int` so the rollback
  survives reorderings and renames. If a tab is *closed* mid-session
  (unlikely but possible), the entry becomes unreferenceable — we'd
  silently drop it on ESC. Document this as fine; the user
  presumably knows they closed the tab.

- **What about open-buffer file content in project_search.** Today
  the project scanner reads from disk, so unsaved edits in open
  tabs aren't reflected in the project results. After the refactor,
  tabs' live `buffer_matches` already exist, and the merged-stream
  dispatcher can prefer them for any path that maps to an open tab.
  Net effect: project results correctly include unsaved edits. The
  scanner can skip open-tab paths entirely to save work.

- **Re-opening a closed tab between ^F and ESC.** If a tab existed
  with a saved cursor at the time of ^F, was closed, then re-opened
  by F3, the new tab gets a new id, so the rollback list won't
  match. Probably fine — closing a tab via ^W is an explicit user
  action and we shouldn't fight it on ESC. Mention this in the
  rollback doc-comment.

- **Search history.** Out of scope; not changing here. A separate
  later refactor could persist query history on `Editor_context`.
