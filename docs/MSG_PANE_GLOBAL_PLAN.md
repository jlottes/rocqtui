# Globalize the message-pane tab strip

## Motivation

The message pane's sub-tab list ("Rocq", "Build", "Errors", "Terminal …")
is currently per-file: each `Tab.t` owns a fresh `msg_tabs` (`lib/tab.ml:174`),
and `View.update_msg_tabs` (`lib/view.ml:282`) repopulates the active
file's list from globals (`Build.output()`, `Build_errors.all()`,
`Terminal.all()`) on every frame. Inactive files retain stale tabs;
switching files makes the bordered tab strip jump as the per-file list
gets rebuilt; and to keep terminal focus surviving file switches we
maintain a `sticky_terminal` ref (`lib/tab.ml:109`) that re-points the
active index after sync.

The conceptual fix: only the **Rocq** tab is per-file (its content
comes from the active file's `Session.msgs`). Everything else —
Build, Errors, Terminal — is global. So the **tab strip itself**
should be global. The Rocq tab stays in a fixed position; what
changes when you switch files is just *the content rendered inside
the Rocq tab*, plus a small chunk of per-file state (scroll, pane
selection).

Goals:

- The bordered message-pane tab strip does not change shape when
  the user switches between file tabs.
- "Build" / "Errors" / "Terminal …" tabs are owned globally; their
  scroll position, selection, and contents are preserved across
  file switches.
- The Rocq tab is also a fixed position in the strip, but its
  content is `Session.messages (active_file)` and its scroll /
  selection are per-file.
- `mt_active` (which sub-tab is active) is **global** — switching
  files keeps you on the same sub-tab. (Confirmed with user.)
- `sticky_terminal` goes away.
- The auto-switch policy (which actions change the active sub-tab)
  is reformulated; see [Auto-switch policy](#auto-switch-policy).

## Auto-switch policy

The new model attributes auto-switch decisions to the **action**
that triggered them, not to content arrival. `View.update_msg_tabs`
becomes purely passive (keeps the tab list and tab content in sync
with global state, never changes `active`); explicit
`Msg_pane.activate` calls live at user-action handlers.

**User-initiated actions** (^Q stands in for any query-producing
hotkey — ^Q opens the query menu, ^A is `about`, ^D is
`print_query`; all three render results into the Rocq tab and
behave identically for auto-switch):

| Active tab | Step OK | Step error | ^Q/^A/^D | F5 | F9 | ^T | ^W on term |
|---|---|---|---|---|---|---|---|
| Rocq | stay | stay | stay (no-op) | → Build | → Errors | → Term | n/a |
| Build | stay | → Rocq | → Rocq | stay | → Errors | → Term | n/a |
| Errors | stay | → Rocq | → Rocq | → Build | stay | → Term | n/a |
| Terminal | stay | stay | → Rocq | **stay** | → Errors | → new Term | → MRU† |

† **^W on terminal** doesn't hard-code Rocq. It pops the
most-recently-used (MRU) sub-tab off the activation history (Rocq
as fallback if history is exhausted). E.g., if you went Rocq →
F9-Errors → ^T-Terminal, then ^W returns to Errors, not Rocq.
See [MRU history](#mru-history-and-pop_active).

**MCP-initiated** step / query / anything: **never switches**.

**Background events** (build-output line streaming in, build
finishing, polled Rocq messages from a previously-initiated step):
**never switch**. Once content arrives, the active tab stays put.

**Note: terminal-focused intercept list.** When a terminal is the
focused pane, only a small allowlist of rocqtui keybinds is
intercepted (`^X`, `^W`, `^P`, `^S`, `F5`, `F1`, `^Y`, `^T`, `F6`,
`ESC`); everything else is forwarded to the terminal. So in
practice the Terminal row only has reachable cells for `F5`, `^T`,
and `^W` — `Alt+Down/Up`, `^Q`, `^A`, `^D`, `F9`, `Shift+F9` cannot
fire while a terminal is focused (those keystrokes go to the
terminal). The policy entries for those cells are still spelled
out in the table and implemented at the handlers, in case the
intercept list changes later. **Do not** extend the intercept
list to capture F9/^Q/^A/^D as part of this refactor — keep
forwarding those to the terminal.

Rationales:
- Step success has no display intent; don't yank focus.
- Step error wants to be seen, but not at the cost of disrupting
  a Claude/shell session — Terminal is the only sticky carve-out.
- F5's purpose is dual (run a build vs. watch a build). Same
  carve-out: stay on Terminal so a "rebuild deps and keep chatting"
  flow isn't disrupted.
- ^Q's only purpose is to display query output, F9's only purpose
  is to navigate to an error, ^T's only purpose is to use the new
  terminal — these override the Terminal carve-out.

Behavior changes vs. today (worth verifying after migration):
1. **Step success from Build/Errors:** today flips to Rocq when
   new messages arrive; new rule stays.
2. **Build streaming / build completion:** today auto-activates
   Build whenever lines arrive while running; new rule only
   switches at the F5 trigger.
3. **MCP-initiated step/query:** today behaves like a user step
   (subject to the terminal guard); new rule never switches.

## Current shape (for reference)

`lib/tab.ml:41-53`:

```ocaml
type msg_tab = {
  mt_name : string;
  mutable mt_lines : Styled.line list;
  mutable mt_scroll : int;
  mt_sel : pane_selection;
  mutable mt_lines_cache : Styled.line list;
  mt_terminal : Terminal.t option;
}

type msg_tabs = {
  mutable mt_tabs : msg_tab list;
  mutable mt_active : int;
}
```

Every `Tab.t` has `msg : msg_tabs` (`lib/tab.ml:174`). Producers:

- `View.update_msg_tabs` (`lib/view.ml:282`) — on the active file
  only, ensures Rocq/Build/Errors tabs exist with current content.
- `Tab.sync_terminals` (`lib/tab.ml:116`) — adds/removes terminal
  sub-tabs to mirror `Terminal.all()`; uses `sticky_terminal` to
  preserve active terminal across file switches.
- Manual scroll resets in `lib/editor/editor.ml:248,255,262`
  (step ops) and `lib/editor/editor.ml:464` (F9 → activate Errors)
  and `lib/editor/pty.ml:13` (^T opens new terminal, switches to
  it).

Consumers (will need updating):

- `lib/view.ml:344` `render_messages` — reads `tab.msg`, dispatches
  on `mt_terminal` for terminal vs text rendering.
- `lib/view.ml:760` — message-pane border draw (tab labels +
  active index).
- `lib/editor/mouse.ml` (~14 sites) — clicks on tab labels, on
  pane content, on selection.
- `lib/editor/editor.ml` (multiple sites) — keyboard handling,
  copy, terminal-close cleanup.
- `lib/editor/modals.ml`, `lib/editor/geom.ml` — read active tab
  for layout / modal context.

## Proposed shape

### Variant for tab kind

```ocaml
type kind =
  | Rocq
  | Build
  | Errors
  | Terminal of Terminal.t
```

### Global registry: new module `lib/msg_pane.ml`

```ocaml
type tab = {
  kind : kind;
  mutable lines : Styled.line list;        (* Build/Errors only;
                                              Rocq pulls from active
                                              file each frame *)
  mutable scroll : int;                    (* Build/Errors only *)
  sel : Tab.pane_selection;                (* Build/Errors only *)
  mutable lines_cache : Styled.line list;  (* Build/Errors only *)
}

type t = {
  mutable tabs : tab list;
  mutable active : int;
  mutable history : kind list;       (* MRU stack of previously active
                                        kinds; current active not
                                        included; deduped *)
}

val state : unit -> t                (* global singleton *)
val active_tab : unit -> tab
val ensure : kind -> tab             (* idempotent insert *)
val remove : kind -> unit            (* also drops kind from history *)
val activate : kind -> unit          (* pushes previous active to history *)
val pop_active : unit -> unit        (* current active vanished; pop MRU *)
val find : kind -> (int * tab) option

val display_name : tab -> string

val sync_terminals : unit -> unit    (* replaces Tab.sync_terminals;
                                        calls pop_active if the active
                                        Terminal was destroyed *)
```

The Rocq tab is **always** the first entry; `ensure Rocq` is a
no-op after first creation. `Build`/`Errors` come and go based on
producer state. `Terminal _` tabs are appended in the order
`Terminal.all()` returns. The active index is global.

### MRU history and pop_active

`activate kind`:

1. If current active kind == `kind`, no-op.
2. Otherwise: prepend the current active kind to `history` (after
   removing any prior occurrence of either it or `kind` from the
   list — each kind appears at most once); set active to `kind`.

`pop_active ()` (called when the active tab is going away):

1. Walk `history` in MRU order, find the first kind that still
   exists as a tab.
2. If found: remove it from `history`, set active to it.
3. If history is empty / exhausted: fall back to `Rocq` (which
   always exists).

`remove kind` also filters `kind` out of `history` so a stale
entry can't resurface (e.g., a removed Errors tab shouldn't pop
back from history later).

Equality on `kind = Terminal of Terminal.t` is by physical
identity (`==`), since two terminals with the same title are
distinct tabs.

### Per-file Rocq pane state on `Tab.t`

`lib/tab.ml`:

```ocaml
type rocq_msg_state = {
  mutable rms_scroll : int;
  rms_sel : pane_selection;
  mutable rms_lines_cache : Styled.line list;
}

(* in record `t`: *)
  msg : msg_tabs;          (* removed *)
  rocq_msg : rocq_msg_state;  (* added *)
```

`fresh_msg_tab` / `fresh_msg_tabs` are deleted. `active_msg_tab`,
`ensure_msg_tab`, `activate_msg_tab`, `remove_msg_tab`,
`find_msg_tab`, `msg_tab_display_name`, `sync_terminals`,
`set_sticky_terminal`, `get_sticky_terminal`, and `sticky_terminal`
itself are all removed from `Tab` — replaced by the corresponding
operations on `Msg_pane`.

### View becomes passive

`lib/view.ml` rewrite of `update_msg_tabs` (~30 lines):

- Always `Msg_pane.ensure Rocq`.
- Compute `rocq_lines` from active file's `Session.messages` (or
  `[]` if no session). The Rocq tab's lines come from the active
  file each frame; scroll/sel come from `tab.rocq_msg`.
- Build: ensure tab when `Build.output()` non-empty or
  `Build.is_running()`; otherwise leave existing.
- Errors: ensure tab when `Build_errors.all()` non-empty, remove
  when empty.
- **No `Msg_pane.activate` calls.** `update_msg_tabs` never changes
  the active sub-tab; that is the job of action handlers. The
  `active_is_terminal` guard (`view.ml:294-298`) goes away — there
  is nothing here to guard.

`render_messages`:

- Pull active tab from `Msg_pane.active_tab ()`.
- For `Rocq`: render lines = active session's messages, with scroll
  / sel / cache from the current file's `rocq_msg` state.
- For `Build` | `Errors`: render from the global tab's own state.
- For `Terminal t`: same as today, draws the terminal.

### Auto-switch lives at action handlers

Each user-initiated action that should switch the sub-tab calls
`Msg_pane.activate <kind>` directly, with the Terminal carve-out
applied at the call site:

```ocaml
let activate_unless_terminal kind =
  match (Msg_pane.active_tab ()).kind with
  | Terminal _ -> ()
  | _ -> Msg_pane.activate kind
```

| Action | Call |
|---|---|
| F5 build start | `activate_unless_terminal Build` |
| User step error (post-poll) | `activate_unless_terminal Rocq` |
| ^Q / ^A / ^D query result | `Msg_pane.activate Rocq` |
| F9 next/prev error | `Msg_pane.activate Errors` |
| ^T new terminal | `Msg_pane.activate (Terminal t)` |
| ^W on focused terminal (after `Terminal.destroy`) | `Msg_pane.sync_terminals (); Msg_pane.pop_active ()` |

User step *success* makes no call. MCP-initiated step/query make
no call. Build line streaming and build completion make no call.

### Distinguishing user vs. MCP step

The step-error switch is the only auto-switch that fires
asynchronously (after a poll completes). It needs to know whether
the in-flight step was user-initiated.

Approach: add `mutable last_step_initiator : [`User | `Mcp] option`
to `Session.t`, set when a step starts, cleared when the step
settles (`is_busy` returns false and target is reached or stuck).
The settling logic lives in `Session.poll` (or a tiny helper called
from there). On clear: if initiator was `User` and there's an
error (`err_range <> None` or last message is an error), the editor
poll path observes this and runs `activate_unless_terminal Rocq`.

To keep the policy out of `Session`, expose
`Session.consume_user_step_result : t -> [`Ok | `Error] option`
that returns `Some` once when a user step settles and `None`
otherwise. The caller in `lib/editor/editor.ml`'s poll loop reads
it and dispatches.

User step initiators are set in `editor.ml` at the
Alt+Down/Up/Go-to-cursor handlers, immediately before invoking
`Session.step_forward` / `Session.step_backward` /
`Session.go_to_offset`. MCP step initiators are set in
`bridge/rocqtui_mcp.ml` (or wherever MCP routes to Session). Both
sides go through the same Session APIs but tag the initiator
beforehand.

Query (^Q) is synchronous — `Session.query` returns when done, so
the caller in `editor.ml`'s ^Q handler can call `Msg_pane.activate
Rocq` directly without an initiator flag.

### Sticky terminal goes away

Because `Msg_pane.active` is global, an active terminal stays
active when files switch — there's no list to repopulate. The
`sticky_terminal` ref and `set_sticky_terminal` / `get_sticky_terminal`
helpers (and their lone external caller in `lib/editor/editor.ml`
and the click handler in `lib/editor/mouse.ml:175,177`) are deleted.

### Errors-tab auto-snap stays in `View`

`errors_last_active : int option ref` (`lib/view.ml:279`) keeps
working unchanged — it tracks the global `Build_errors.current_index`
and snaps the *scroll* of the Errors tab to the active entry. This
is independent of which sub-tab is active; F9 itself calls
`Msg_pane.activate Errors` from the editor handler.

## Call-site migrations

Mostly mechanical: `tab.msg.mt_active` → `(Msg_pane.state ()).active`,
`Tab.active_msg_tab tab.msg` → `Msg_pane.active_tab ()`,
`Tab.ensure_msg_tab tab.msg "Build"` → `Msg_pane.ensure Build`, etc.

Two cases need care:

1. **Rocq tab scroll resets**, `lib/editor/editor.ml:248,255,262`
   (Alt+Down/Up, Go-to-cursor):
   ```ocaml
   tab.goals_scroll <- 0;
   (Tab.ensure_msg_tab tab.msg "Rocq").mt_scroll <- 0;
   ```
   becomes:
   ```ocaml
   tab.goals_scroll <- 0;
   tab.rocq_msg.rms_scroll <- 0;
   ```
   (Per-file Rocq state lives on the file's `Tab.t`, not on the
   global Rocq tab.)

2. **Terminal-close cleanup**, `lib/editor/editor.ml:144-156`:
   ```ocaml
   Terminal.destroy term;
   Tab.set_sticky_terminal None;
   tab.msg.mt_active <- 0;
   Tab.sync_terminals tab.msg;
   Tab.activate_msg_tab tab.msg "Rocq";
   ```
   becomes:
   ```ocaml
   Terminal.destroy term;
   Msg_pane.sync_terminals ();   (* prunes the destroyed terminal *)
   Msg_pane.pop_active ()        (* MRU fallback; Rocq if empty *)
   ```
   No more sticky bookkeeping.

3. **^T new terminal**, `lib/editor/pty.ml:12-13`:
   ```ocaml
   Tab.sync_terminals tab.msg;
   tab.msg.mt_active <- List.length tab.msg.mt_tabs - 1;
   ```
   becomes:
   ```ocaml
   Msg_pane.sync_terminals ();
   Msg_pane.activate (Terminal _term);
   ```

4. **F5 build start**, currently in the build-menu handler in
   `lib/editor/modals.ml` / `lib/editor/editor.ml`: after kicking
   off the build, call `activate_unless_terminal Build`. (Today
   the switch happens reactively in `update_msg_tabs` via
   `Build.is_running()`.)

5. **Query hotkeys** (^Q query menu, ^A `about`, ^D `print_query`):
   after the corresponding `Session.query` returns, call
   `Msg_pane.activate Rocq` unconditionally. (Per the policy table,
   query hotkeys override the Terminal carve-out, since their only
   purpose is to display a result.)

6. **F9 / Shift+F9**, currently in `lib/editor/editor.ml:464`
   (`activate_msg_tab tab.msg "Errors"`): becomes
   `Msg_pane.activate Errors`. Already explicit; just a rename.

7. **User step initiator tagging**, around the
   `Session.step_forward` / `Session.step_backward` /
   `Session.go_to_offset` calls in `lib/editor/editor.ml`: set
   `sess.last_step_initiator <- Some `User` immediately before.

8. **Editor poll loop step-result handling**, in the per-frame
   poll in `lib/editor/editor.ml` (next to `Tab.poll_all`): after
   polling, call `Session.consume_user_step_result` for the active
   tab's session; on `Some `Error`, run
   `activate_unless_terminal Rocq`.

9. **MCP step initiator tagging**, in
   `bridge/rocqtui_mcp.ml` (or whichever module routes MCP-step
   requests to Session): set
   `sess.last_step_initiator <- Some `Mcp` before invoking the
   Session step API. `consume_user_step_result` returns `None` for
   MCP-tagged steps, so no auto-switch happens.

10. **Mouse click on tab strip**, `lib/editor/mouse.ml:168-177`:
    The list of clickable labels comes from
    `Msg_pane.state().tabs`; click sets `Msg_pane.state().active`.
    The `set_sticky_terminal` calls disappear.

## Module layout

New: `lib/msg_pane.ml` + `lib/msg_pane.mli`. Owns the `kind` and
`tab` types and the global state.

Modified:

- `lib/tab.ml` / `lib/tab.mli`: drop `msg_tab`, `msg_tabs`, all the
  helpers and the sticky-terminal ref. Add `rocq_msg_state` and the
  `rocq_msg` field on `t`.
- `lib/view.ml`: `update_msg_tabs`, `render_messages`, message-pane
  border rendering.
- `lib/editor/{editor,mouse,modals,geom,pty}.ml`: rewire to
  `Msg_pane` API.

`lib/styled.ml` and `lib/render.ml` unchanged.

## Edge cases

- **No session yet** (e.g., file failed to open or loading): Rocq
  tab renders as empty. Same as today (`session = None` branch in
  `update_msg_tabs`).
- **Switching to a file whose Rocq pane was scrolled**: the new
  file's `tab.rocq_msg.rms_scroll` is restored — better than today,
  where it was kept on the per-file `msg_tab` but lost on
  `update_msg_tabs` if `mt_lines` changed (the `if rocq_lines <>
  rocq.mt_lines` branch). Per-file restoration becomes natural.
- **Background file emits Rocq messages** (e.g., MCP step on a
  non-active file): the global Rocq tab's content is keyed to the
  *active* file's session, so background-file messages don't show
  up until you switch to that file. They are still preserved in
  that file's `Session.msgs`. No auto-switch (MCP-initiated; even
  if it were user-initiated, it's a different file and we don't
  surface its messages until the file is brought forward).
- **Errors tab removal when `Build_errors.all() = []`**: today, only
  the active file's Errors tab is removed; other files retain a
  stale entry until they re-activate. With a global pane, the
  removal is immediate and global. If Errors was the active tab
  at removal, `update_msg_tabs` calls `Msg_pane.pop_active ()` to
  fall back to the MRU previous tab. Improvement.
- **User starts F5 build, then manually switches to Rocq, then
  build streams output**: today, every line that arrives while
  `Build.is_running()` re-activates Build. New rule: the F5 trigger
  switched once; subsequent line streaming is a background event
  and does not switch back. The user keeps the tab they chose.
- **Multi-file workflow with terminal focused**: today, opening
  another file deactivates the terminal sub-tab in the new file's
  list (sticky-terminal restores it). With a global pane there's
  no list to deactivate; the terminal stays active. No special
  guard needed.
- **F9 from a focused terminal**: per the table, F9 switches to
  Errors. The handler also currently switches `tab.focused_pane`
  back to `Script` in some paths — verify the F9 path leaves
  `focused_pane` untouched (we want pane focus on `Messages` so the
  user can scroll Errors immediately).

## Migration order

1. **Add `Msg_pane`** module (with the new types and globals)
   alongside the existing `msg_tabs` machinery, but unused. Build
   passes.
2. **Re-implement `View.update_msg_tabs` and `render_messages`** to
   write to `Msg_pane`, while still maintaining `tab.msg` so other
   read-sites keep working. (Two-headed during migration.) In this
   step, also strip auto-switch logic from `update_msg_tabs` —
   leave it purely passive.
3. **Wire user-action auto-switch calls** at the appropriate
   handlers: F5 → Build, ^Q → Rocq, F9 → Errors, ^T → new Terminal,
   ^W on terminal → Rocq. Each uses
   `activate_unless_terminal` where the policy table says so.
4. **Add user/MCP step initiator tagging** in `Session.t`,
   `Session.consume_user_step_result`, and the editor poll loop
   that triggers `activate_unless_terminal Rocq` on user step
   error. Tag MCP step entry points as `Mcp`.
5. **Rewire read-sites** in `editor/{editor,mouse,modals,geom,pty}.ml`
   to read from `Msg_pane`. Run e2e + manual smoke after each file.
6. **Delete** the per-file `msg : msg_tabs`, `msg_tab`, `msg_tabs`,
   `sticky_terminal`, and the helpers from `Tab`. Add
   `rocq_msg_state` / `rocq_msg` field. Fix Rocq-scroll-reset
   call-sites (`lib/editor/editor.ml:248,255,262`).
7. **Verify**: `dune build`, `dune runtest`, `dune build @e2e`.
   Manual checklist below.

Each step keeps the project building and runnable. Step 6 is the
breaking commit.

## Tests

E2E: existing tests don't exercise the message-pane tab strip
directly, but smoke tests run the renderer; any crash on missing
`tab.msg` will surface there.

New unit test `test/test_msg_pane.ml` (matches the style of
`test_build_errors`):

- `ensure` is idempotent.
- `remove Errors` works when Errors is active and not active;
  active index is clamped; Errors is dropped from history.
- `sync_terminals` adds new and removes destroyed terminals;
  preserves active index when the active terminal still exists.
- `activate` push-and-dedup: activating the same kind twice does
  not duplicate it in history; activating Rocq → Build → Rocq
  leaves history = [Build].
- `pop_active`: with history = [Errors; Rocq], pop yields Errors;
  with empty history, pop yields Rocq fallback.
- Activating a `Terminal t` then destroying `t` and calling
  `pop_active` lands on the MRU previous kind (or Rocq if none).

Auto-switch policy is harder to unit-test in isolation (it lives
across action handlers + `Session.consume_user_step_result`), so
relegate to e2e or the manual checklist. If we add an MCP test
that steps and then asserts something about the pane, it must
verify *no switch* occurred.

Manual checklist (covers both globalization and auto-switch policy):

Globalization
- [ ] Open file A, ^T opens terminal, switch to file B → terminal
      is still the active sub-tab.
- [ ] In file A, scroll Rocq tab; switch to B; switch back → A's
      Rocq scroll is preserved.
- [ ] Trigger build → Build sub-tab appears; switching files keeps
      Build present.
- [ ] Click tab labels in the message-pane border: switches
      `active` globally; another file shows the same active tab.

Auto-switch table
- [ ] On Rocq, Alt+Down through clean code: stays on Rocq.
- [ ] On Build (after F5), Alt+Down through clean code: stays on
      Build (today this flips to Rocq — verify it no longer does).
- [ ] On Build, Alt+Down hits an error: switches to Rocq.
- [ ] On Errors, Alt+Down hits an error: switches to Rocq.
- [ ] On Terminal, Alt+Down hits an error: stays on Terminal.
- [ ] On Terminal, F5 (build): stays on Terminal.
- [ ] On Rocq, F5: switches to Build.
- [ ] On Terminal, ^Q query: keystroke goes to terminal (not
      intercepted); active tab stays. (Aspirational policy entry,
      currently unreachable.)
- [ ] On Terminal, F9: keystroke goes to terminal (not
      intercepted); active tab stays. (Aspirational, unreachable.)
- [ ] After F5 build starts, manually switch to Rocq while build
      still streaming: stays on Rocq (today flips back to Build).
- [ ] MCP step (via Claude or `dune build @e2e` MCP tests): does
      not change the active sub-tab regardless of result.
- [ ] ^W on focused terminal destroys it; pane reverts to MRU
      previous tab (e.g., Errors if you had F9'd before ^T).
- [ ] Build_errors clears while Errors is active: pane reverts to
      MRU previous tab.
