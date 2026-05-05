# Search & Replace — Design

Status: design draft. No code yet.

## Goals

- Incremental search: highlight as you type, jump to first match.
- Persistent search state: highlights and navigation survive leaving the
  prompt (Chrome/VSCode-style, not vim's transient `/`).
- Case sensitivity with a smart-case default and an explicit toggle.
- Regex support via `Re`, toggleable.
- Replace as a follow-up phase, sharing the matcher.

## UX model

Hybrid of Chrome's find bar and emacs `isearch`. The **search prompt** is a
modal that takes input. The **search state** lives on the tab and persists
across focus changes, edits, and tab switches.

Two top-level states:

- *Inactive* — no query, no highlights, no match list.
- *Active* — query persists, matches highlighted across the visible buffer,
  current match styled differently. Sub-state *prompt-open* means the user
  is actively editing the query; *prompt-closed* means just the highlights
  plus navigation keys.

## State machine

| From | Key | To | Effect |
|------|-----|-----|--------|
| Inactive | `^F` | Active, prompt open | Empty query; save cursor for cancel-restore. |
| Active, prompt closed | `^F` | Active, prompt open | Pre-fill query, select-all so typing replaces. |
| Prompt open | Enter | Active, prompt closed | Keep current match position. |
| Prompt open | `^G` | Inactive | Cancel — restore cursor to pre-search position, clear highlights. |
| Active, prompt closed | F3 | Active, prompt closed | Jump to next match. |
| Active, prompt closed | Shift+F3 | Active, prompt closed | Jump to previous match. |

ESC is reserved for xcompose and is not used here.

`^G` is bound globally to "toggle hypotheses" in `lib/keys.ml`, but inside
the prompt the modal handler intercepts input before global dispatch, so
`^G` can serve as the prompt's cancel key without conflict. There is no
dedicated outside-prompt key to clear an active search — to clear, press
`^F` to re-open the prompt and `^G` to cancel. Two keystrokes for an
infrequent operation; not worth shifting another binding to make it one.

## Keybindings

- `^F` — open or re-open search prompt.
- `^G` — cancel inside the prompt only (modal-local; the global
  `toggle_hyps` binding is unaffected when the prompt isn't open).
- F3 / Shift+F3 — next / previous match (only meaningful when search is
  active).
- F7 — theme picker (moved from F3 to free up F3 for search navigation).

Inside the prompt:

- Enter — accept; close prompt, leave search active.
- Alt+C — toggle case sensitivity (smart-case ↔ forced sensitive).
- Alt+R — toggle regex mode.
- Standard text editing: backspace, arrow keys, `^A` / `^E` if we want them.

## Prompt display

Bottom-bar format:

```
Search: foo█  3/27  [aA] [.*]
```

- `3/27` — current / total match counter. `0/0` when nothing matches.
- `[aA]` indicator lit when case-sensitive, dim when smart-case.
- `[.*]` indicator lit when regex mode is on, dim otherwise.

The prompt is **blocking**: while it is open, keystrokes go to the prompt,
not to the buffer. Lift this later if non-blocking typing-while-navigating
turns out to be useful.

## Compose mode in the prompt

The xcompose key (ESC, when launched with `--xcompose`) must work inside
the search prompt. Composed characters land in the query and live re-search
picks them up like any other keystroke. This is required, not optional —
searching for unicode-rich Rocq identifiers is a primary use case.

The existing compose-mode indicator lives in the bottom status bar, which
the search prompt now occupies. To avoid trampling the prompt:

- The prompt keeps the bottom bar. Compose state is shown as an inline
  indicator on the right side of the prompt, after the toggles:

  ```
  Search: alpha█  3/27  [aA] [.*]  [c: \al]
  ```

  When compose is not active the indicator is omitted entirely.
- ESC inside the prompt starts compose; the prompt's input handler
  delegates to the existing compose layer first, which either consumes the
  key (still collecting) or passes it through as a finished character /
  non-compose key.
- ESC ESC cancels compose (existing behavior carried through).
- `^G` cancels the prompt only when compose is not actively collecting; if
  compose is collecting, ^G is just another key in the sequence. To bail
  out fully: ESC ESC, then `^G`.

If the inline indicator turns out to be too cramped (e.g., long compose
sequences), the fallback is to expand the bar to two lines while compose is
active — top line for compose state, bottom line for the prompt. Start with
inline; switch only if needed.

## Smart-case

Case-insensitive by default. If the query contains any uppercase character,
treat the search as case-sensitive automatically. Alt+C forces sensitive
mode (overriding smart-case); pressing it again returns to smart-case.

## Regex mode

Always run through `Re`. In literal mode, escape metacharacters before
constructing the regex. No separate fast path — Rocq source files are small
enough that the perf difference is irrelevant.

Single-line queries only in v1, both literal and regex. Multi-line patterns
are out of scope.

## Highlighting

- All visible matches: subtle background tint.
- Current match: distinct, high-contrast styling (reversed video or a
  stronger background).
- While the prompt is open, the current match follows typing — first match
  at or after the saved cursor.

Off-screen matches don't need to be rendered, but the match list itself is
buffer-wide so the counter and next/prev navigation work without scrolling
constraints.

## Edits while active

Re-run the matcher on every buffer change.

- Match positions are recomputed from the current buffer state.
- "Current match" is tracked by buffer position (line + column of its
  start).
- If the previous current match no longer exists post-edit, snap to the
  first match at or after the cursor.

This is what we want over Chrome's pin-on-Enter behavior: edits in Rocq
files are frequent and the user wants the highlights to stay accurate.

## State ownership

Search state lives on `Tab.t`. Each tab has its own active search; switching
tabs preserves it independently. No global last-query store in v1 — can add
later if "open `^F` in a fresh tab and re-search the same thing" becomes a
frequent need.

## Replace (Phase 2)

Out of scope for the first cut. Sketch for later:

- A new key (TBD; `^H` is conventional but conflicts with backspace on some
  terminals) opens a two-line replace bar: search field + replace field.
- After Enter, prompt per-match: `y` replace, `n` skip, `a` replace all
  remaining, `q` quit. Same flow as emacs `query-replace`.
- Reuses the search state's matcher and match list.

## Implementation plan

Phased so each step builds and runs on its own.

### Phase 0 — F3 → F7 rebind (standalone)

- `lib/keys.ml`: change `theme_menu` codes from `[267]` (F3) to whatever
  F7's code is (likely `[271]`; verify via `Input.read_event` traces).
  Update its `display`.
- `CLAUDE.md`: update the keybindings table row.
- Smoke-test: launch, press F7 → theme picker; F3 → unbound for now.

This ships as one commit. Nothing else depends on it merging first, but
keeping it separate makes the search-feature commit cleaner.

### Phase 1 — `Search` module (pure, no UI)

New `lib/search.ml` / `lib/search.mli`. Pure: no I/O, no buffer mutation.

- `type case_mode = Smart | Sensitive`
- `type flags = { case : case_mode; regex : bool }`
- `type pos = { line : int; col : int }`
- `type match_ = { start : pos; end_ : pos }`
- `type state = { query : string; flags : flags; matches : match_ array;
   current : int;  (* index into matches; -1 if none *)
   saved_cursor : pos }`
- `val empty_flags : flags`
- `val recompute : Buffer.t -> string -> flags -> match_ array`
  (uses `Re` — `Re.Pcre.re` for regex, `Re.str` for literal; honors
  smart-case)
- `val next : state -> state` / `val prev : state -> state`
- `val update_query : state -> Buffer.t -> string -> state`
- `val update_after_edit : state -> Buffer.t -> state`
  (re-runs matcher; preserves `current` by buffer position when possible)

Add unit tests under `test/test_search.ml`.

### Phase 2 — Per-tab state

- `lib/tab.ml/.mli`: add `mutable search : Search.state option` to `Tab.t`.
  `None` means inactive.
- Wherever `Buffer` mutations are committed (likely `Region_buffer` or the
  buffer-change observer path — needs a quick grep): if the active tab has
  `search = Some s`, update via `Search.update_after_edit`.

### Phase 3 — Prompt modal & dispatcher

- `lib/modal.ml/.mli`: add a `SearchPrompt` variant to `kind`. It carries
  no handler closure (unlike `Prompt`) — the dispatcher in
  `Editor.Modals` knows how to handle it directly so it can access tab
  state and the compose engine.
- `lib/editor/modals.ml/.mli`: new `handle_search_prompt` function.
  Input flow per key event:
  1. If compose is `active` or the event is the compose start key (ESC):
     feed to `Compose.feed`. On `Composed s` insert into query and
     re-run matcher; on `Pending` redraw indicator; on `NoMatch` abort
     compose and ignore.
  2. Otherwise match against: Enter (close prompt), `^G` (cancel and
     restore cursor), Alt+C (toggle case), Alt+R (toggle regex), F3 /
     Shift+F3 (next/prev within the prompt), backspace / left / right /
     printable (edit the query).
  3. Anything else: stay in prompt (`Ignored`-style behavior).
- `^F` from the editor's main keymap pushes a `SearchPrompt` modal onto
  the tab's modal stack.

### Phase 4 — Renderer

- Highlight drawing: where the editor renders buffer lines, if the tab
  has an active search, decorate visible match ranges. Current match
  gets a stronger style.
- Bottom-bar prompt rendering: when `SearchPrompt` is the top modal,
  draw the prompt line with query, counter, `[aA]` / `[.*]` indicators,
  and (if compose active) the `[c: …]` indicator on the right. Otherwise
  draw the normal status bar.

### Phase 5 — F3 / Shift+F3 navigation outside prompt

- `lib/keys.ml`: add `search` (`^F`), `search_next` (F3), `search_prev`
  (Shift+F3) bindings. F3 was just freed in Phase 0.
- Editor main key dispatch: when search is active and prompt is closed,
  F3 / Shift+F3 advance through matches, scrolling the viewport to keep
  the current match visible.

### Phase 6 — Help & polish

- `lib/keys.ml` `generate_help`: add a "Search" section listing the
  three bindings and the inside-prompt toggles.
- `CLAUDE.md` keybindings table: add the three rows.

### Out of scope for this work

- Replace (Phase 2 of the broader feature; separate doc / commit later).
- Multi-line patterns.
- A dedicated outside-prompt clear key.
- Cross-tab "last query" memory.

