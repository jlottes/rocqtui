# Replace — Design

Status: design draft. No code yet. Builds on the search feature already shipped
(see [`SEARCH_PLAN.md`](SEARCH_PLAN.md)). The earlier doc's "Replace (Phase 2)"
sketch is superseded by this one: we are going with a two-field panel rather
than emacs-style query-replace, after weighing discoverability against keybind
density.

## Goals

- Add replace alongside search, sharing the same matcher and match list.
- **Two-field panel** UX — Find and Replace fields visible simultaneously, with
  focus toggled by Tab. No separate "replace mode" to enter.
- Persistent like search today: highlights survive prompt close, state lives on
  `Tab.t`.
- **No SIGWINCH / reflow** of embedded terminals when the panel opens or closes.
- Respect `Region_buffer` invariants — replacements that would touch the
  verified or pending region are silently skipped, surfaced in the final count.
- Reuse the existing search prompt's compose, smart-case, and regex behavior.

## UX

When the user presses `^F`, the bottom of the screen grows to a two-row panel:

```
Find:    foo█                              3/12  [aa] [..]
Replace: bar                                                   ^J:Repl  ^H:All
```

- Top row is the **Find field**, bottom row is the **Replace field**. The
  trailing area on the top row keeps the existing search indicators (match
  counter, case toggle `[aa]`/`[Aa]`, regex toggle `[..]`/`[.*]`, compose `[c:…]`).
  The bottom row shows the replace actions as a key hint.
- Focus indicator: the focused field's caret is shown; the other field shows a
  static caret-less text.
- Buffer highlights, current-match styling, scroll-to-match — all unchanged
  from search today.

### Key bindings inside the panel

| Key | Effect |
|-----|--------|
| Tab | Toggle focus between Find and Replace fields. |
| Printable / Backspace / compose | Edit the focused field. (Edits in Find re-run the matcher, like today. Edits in Replace just update the staged text — no buffer change.) |
| F3 / Shift+F3 | Next / previous match (same as today, either field). |
| Alt+C / Alt+R | Toggle case / regex (same as today). |
| Enter | Accept: close panel, leave search active. Matches current search behavior. |
| ESC (or ESC ESC in compose mode) | Cancel — restore cursor to saved position, clear search. Same as today. |
| `^J` | Replace **current** match (the highlighted one), advance to next. Stays in panel. |
| `^H` | Replace **all** remaining matches in one shot. Stays in panel; updates counter to reflect new match list. |
| Mouse click in either field | Move focus to that field (and within the field, position the caret if we want — v1 can ignore intra-field caret). |

Notes on the chord choices:

- `^J` is line-feed; on raw terminals it is the same byte as Enter, but in
  Kitty mode (our default in dev) it is reported as a distinct event. To keep
  raw-terminal users functional we'll also accept `Alt+Enter` as a synonym.
- `^H` is backspace on most terminals; same Kitty caveat. We'll alias to
  `Shift+Alt+Enter` (or similar) for raw terminals. Final aliases to be settled
  during implementation — they live in `lib/keys.ml`.
- Tab is currently unused inside the search prompt, so the binding is free.

### Replace-current and replace-all behavior

- **Replace current** (`^J`):
  1. Take the current match (`Search.current_match`), build `start`/`old_end`
     byte offsets, and call `Region_buffer.try_replace ~start ~old_end text`.
  2. On `Applied`: matcher re-runs via `update_after_edit` (existing buffer-edit
     observer path). The "current" pointer naturally lands on the next match
     because the edit anchor logic in `Search.edit_anchor` falls back to the
     saved cursor / advances past the edit. We may need a small refinement so
     that after a replace, "current" specifically lands on the *next* match
     rather than re-selecting the (possibly still-matching) replacement text.
     Simplest: after `Applied`, explicitly call `Search.next` once.
  3. On `Rejected _`: the match overlaps the verified or pending region. Skip
     to the next match and increment a "skipped" counter shown in the status
     after replace-all completes. For replace-current we just advance silently
     (or flash a status hint).
- **Replace all** (`^H`):
  Iterate the match list **from the end** so positions ahead of the replacement
  remain valid as edits happen. Track `(replaced, skipped)`. On completion,
  show in the status line, e.g., `Replaced 5 occurrences (2 skipped — verified
  region)`. The match list is recomputed at the end and the cursor is parked at
  the position of the last replacement (or unchanged if zero replacements).

### Regex replacement

In regex mode, replacement strings may contain `$1`, `$2`, … back-references and
`$&` for the whole match. Implemented via `Re.replace` (literal mode just escapes
the text). Literal `$` in replacement requires `$$`. v1 supports only these; no
case-conversion (`\U`, `\L`), no conditionals. If the syntax turns out to
surprise users, we can grow it.

Edge case: an empty regex match (e.g., `a*` matching the empty string between
characters) would cause replace-all to infinitely loop without a guard. `Re.replace`
already handles this; if we hand-roll the replace-all loop we have to advance
past any zero-width match. Use `Re.replace` for replace-all; only use match-by-
match `try_replace` for replace-current.

## Architecture

### Phase 1 — Multi-row status overlay (standalone infrastructure)

This phase ships on its own, before any replace logic. It's a generally-useful
primitive — the find/replace panel is the first user, but the same hook is what
we'd reach for if any future modal wants more than one line of bottom-bar real
estate.

**Design**: paint the panel over the bottom row(s) of the messages pane
*without* changing pane rects. The messages pane keeps its current height,
embedded terminals never get `TIOCSWINSZ` / SIGWINCH, child processes don't
reflow.

Mechanics:

1. Add a mutable `panel_rows : int` (default 0) to `Render.t`.
2. New API:
   - `set_panel_rows : t -> int -> unit`
   - `set_status_line : t -> row_from_bottom:int -> string -> unit`
     — `row_from_bottom = 0` is the existing status row (same as `set_status`),
     `1` is the row above, etc. Writes directly to grid row `term_h - 1 -
     row_from_bottom` using the status attribute.
3. `pane_at` becomes:
   ```ocaml
   else if y >= t.term_h - 1 - t.panel_rows then PStatus
   ```
   So clicks on the covered rows hit PStatus while the panel is up, falling
   through to messages otherwise.
4. `compute_layout` is **unchanged**. No pane heights move.
5. Render order is preserved (`render_messages` runs before `update_status`),
   so painting the panel last naturally wins the cells.

What this **doesn't** do:

- Doesn't shrink any pane. The bottom row of `PMessages` is still drawn each
  frame; the panel just covers it. When the panel closes, the next frame paints
  messages content back into that row.
- Doesn't generate any vterm resize. `Terminal.resize` is called from
  `render_messages` with the *real* messages rect each frame, which hasn't
  changed, so it no-ops.
- Doesn't move the script pane.

Cosmetic cost: while the panel is open, the bottom row of the active messages
tab (Rocq messages, Build, Errors, or an embedded terminal) is hidden. Accept;
the panel is short-lived in practice.

Tests: extend `test/test_render.ml` (or add one) for the hit-test and the row
painting. No e2e harness change needed.

### Phase 2 — Search state extensions

Extend `lib/search.ml/.mli`:

- Add to `state`:
  - `replacement : string` (default `""`)
  - `focus : [ `Find | `Replace ]` (default `` `Find ``)
- New helpers:
  - `set_replacement : state -> string -> state` (no recompute)
  - `set_focus : state -> [ `Find | `Replace ] -> state`
- For computing the substituted text of a single match (used by replace-current
  in regex mode):
  - `val substitute : query:string -> flags:flags -> replacement:string ->
       matched:string -> string`
    — Literal mode: returns `replacement` unchanged. Regex mode: runs `Re.replace_string`
    or equivalent on the matched text.

The bulk of replace logic does **not** live in `Search`. `Search` stays a pure
matcher + state-of-the-prompt module. The actual buffer edits live in the
dispatcher (Phase 4) because they have to interact with `Region_buffer`.

### Phase 3 — Renderer

In `lib/view.ml`:

- `render_search_bar` becomes `render_search_panel`. It calls
  `Render.set_panel_rows r 1` when invoked, paints:
  - Row from bottom 1 (top of panel): `Find: <query>  <counter>  <toggles>  <compose>`
  - Row from bottom 0 (existing status row): `Replace: <text>     <key hints>`
- When `update_status` is invoked and the top modal is no longer
  `SearchPrompt`, call `Render.set_panel_rows r 0` so the panel goes away.
  Cleaner: have the caller of the matched-on `Some Modal.SearchPrompt` arm
  always set rows to 1, and the fallthrough arm set it to 0.
- Caret rendering: the focused field's caret position is computed from the
  query/replacement length. `Render.place_cursor` already exists.

### Phase 4 — Dispatcher

In `lib/editor/modals.ml`, `handle_search_prompt`:

- Pull current `focus` from the search state; route printable / backspace /
  compose to either Find or Replace based on it.
- Add cases for Tab, `^J` / Alt+Enter, `^H` / Shift+Alt+Enter:
  - Tab: `set_focus` to the other field.
  - Replace current: see "Replace-current and replace-all behavior" above.
  - Replace all: iterate match list end-to-start, calling
    `Region_buffer.try_replace` for each; count Applied vs Rejected; update
    status hint with the result.
- The existing search compose / smart-case / regex / next-prev / Enter / ESC
  cases stay unchanged in semantics; they just need to be aware that the
  printable-character path targets the focused field.

### Phase 5 — Help & polish

- `lib/keys.ml` `generate_help`: add a "Replace" subsection (or extend
  "Search") listing Tab, `^J`, `^H`, and the alt aliases.
- `CLAUDE.md` keybindings table: add three rows (Tab, replace current, replace
  all).
- README / status hint refresh.

## State ownership

Replace state piggybacks on `Search.state` (on `Tab.t`). No separate "replace
in progress" mode. Search alone still works exactly as today — users who never
touch the Replace field never see any new behavior except that the panel is
now two lines while the prompt is open. Once the prompt closes, the panel
collapses and the bottom looks identical to the search experience today.

This means the Replace field's contents *persist* across prompt close/reopen
on the same tab, the same way the query does. Likely useful (re-applying the
same replacement on a different range of the same file). Trivial to clear if
we change our mind.

## Out of scope for this work

- Replace across multiple files / tabs.
- Multi-line replacements (regex `\n` will technically work for substitution
  but query is still single-line; see SEARCH_PLAN).
- Case-preserving replace (`\U`, `\L`).
- An incremental "preview every match's replacement inline" highlight. v1 only
  highlights the match range, not the after-replacement text.
- Undo/redo grouping of a replace-all into one undo step. v1 produces one undo
  entry per replacement; users can hit undo repeatedly. Grouping is a sensible
  follow-up but requires changes in `Region_buffer` / `Buffer.Unsafe`.

## Implementation order

1. **Phase 1 alone** — multi-row status overlay, ship as a single commit. No
   user-visible change.
2. **Phases 2–4 together** — the replace feature itself, ships as one commit
   (or two if Phase 2 turns out to be sizeable enough to test in isolation).
3. **Phase 5** — help text and docs, can land in the same commit as 2–4 if
   small.
