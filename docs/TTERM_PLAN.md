# `tterm` — terminal-only sibling binary

## Motivation

The messages-pane terminal subsystem is already self-contained: `Terminal`
spawns and drives PTYs, `Msg_pane` owns the global sub-tab strip, `Compose`
handles xcompose, and the `term_focused` branch of `Editor.handle_event`
(`lib/editor/editor.ml:150`) defines the small set of keybindings that
intercept a terminal-focused world. Bolted together, those four pieces
*are* a terminal multiplexer hiding inside rocqtui.

`tterm` exposes that multiplexer as a standalone binary — no Rocq
session, no script pane, no file tree, no MCP server. The deliverable
is a tabbed-terminal program that reuses rocqtui's PTY/vterm/render/
compose stack verbatim.

## Goals

- A binary `tterm` that launches into a single shell tab with the
  messages-pane sub-tab strip at top and a status bar at bottom.
- `^T` opens a new terminal tab; `^W` closes the current one (and the
  whole program when the last tab is closed); `^Q` quits.
- Copy via `^Y` (matches rocqtui's terminal-focused convention so
  `^C` reaches the shell); paste via the terminal's bracketed-paste
  path.
- `--xcompose` works exactly as in rocqtui — composed text feeds the
  active terminal.
- Status bar shows: active terminal title (left), scrollback indicator
  when scrolled (right), xcompose pending sequence when active.

## Non-goals (v1)

- Split panes (no horizontal/vertical splits).
- Detach/attach (no daemon, no tmux-style sessions).
- Configurable keybindings beyond what rocqtui already provides.
- MCP server.
- File tree, script pane, goals pane.
- `^P` pane cycling, `F1` help — keep the surface minimal.

## Architecture

```
                    ┌──────────────────────────────┐
   bin/tterm.ml ───►│ small main loop:             │
                    │   select on stdin+term FDs   │
                    │   drain input → Terminal_input│
                    │   render via View_terminal   │
                    └──────┬───────────────────────┘
                           │
   shared with rocqtui:    ▼
   ┌─────────────────────────────────────────────────┐
   │ Terminal_input (NEW, extracted from Editor)     │
   │ Msg_pane                                        │
   │ Terminal / Pty / vterm                          │
   │ Compose                                         │
   │ Render / Input / Keymatch / Keys / Modal        │
   │ Clipboard                                       │
   └─────────────────────────────────────────────────┘
```

Three principles:

1. **No mode flag.** Terminal-only is not a switch inside `bin/main.ml`;
   it is a different binary that wires up a strict subset of `lib/`.
2. **Same code paths, two callers.** Anything that's already correct
   for "terminal focused in rocqtui" is correct for tterm. Extract,
   share, don't fork.
3. **Caller decides what exists.** `Msg_pane` today creates the Rocq
   tab on first load (`lib/msg_pane.ml:32`). Lift that out: `bin/main.ml`
   ensures it explicitly, `bin/tterm.ml` doesn't.

## File-by-file changes

### Modifications to `lib/`

#### `lib/msg_pane.ml`

Drop the implicit Rocq tab.

- `let global = { tabs = [make_tab Rocq]; active = 0; history = [] }`
  → `let global = { tabs = []; active = 0; history = [] }`
- `active_tab`'s fallback `make_tab Rocq` becomes a defensive
  `failwith` or returns an `option`. Callers always `ensure` before
  reading.
- `pop_active_internal`'s "fall back to Rocq" becomes "fall back to
  the first existing tab, or no-op if none." Cleaner anyway — Rocq
  was a domain-specific fallback embedded in a generic mechanism.

`bin/main.ml` adds one line at startup:

```ocaml
ignore (Msg_pane.ensure Msg_pane.Rocq)
```

tterm starts with `Pty.open_tab` immediately, so a Terminal sub-tab
exists before any render or input drain.

#### `lib/editor/editor.ml`

Extract the `term_focused` branch (currently lines 150–201) into a
new module. The remaining `handle_event` calls into it:

```ocaml
if term_focused && not is_mouse_event then
  Terminal_input.handle_keypress ctx ev (active_term ()) r
else
  (* existing non-terminal global keys *)
```

The extracted module is the single source of truth for "what keys
rocqtui intercepts while a terminal is in focus." rocqtui and tterm
both use it; behavior cannot drift.

### New `lib/` modules

#### `lib/terminal_input.ml(i)`

```ocaml
(** Keybindings that rocqtui intercepts while a terminal is focused.
    Anything not in this list passes through to the terminal. Used
    by both [Editor.handle_event] (when the messages pane is in
    Terminal sub-tab) and by [bin/tterm.ml] (always). *)

type result =
  | Quit
  | Close_term        (* destroy the active terminal *)
  | Open_term         (* spawn a new one *)
  | Copy_selection
  | Continue          (* handled, no further action *)
  | Pass_to_term      (* not intercepted; caller forwards *)

val handle :
  Editor_context.t ->
  Input.event ->
  Terminal.t option ->
  Render.t ->
  result
```

Internally: the same matches as today (`Keys.quit`, `Keys.close_tab`,
`Keys.cycle_pane`, `Keys.copy`, `Keys.open_terminal`,
`Keys.open_claude`, ESC compose-start). For tterm, `Keys.cycle_pane`
and `Keys.build_menu` / `Keys.help` / `Keys.open_claude` won't make
sense, but they're harmless — tterm just doesn't act on `Cycle_pane`
results (it has nowhere to cycle to). Cleaner: gate them behind
`?include_rocqtui_bindings:bool` parameter, default true, and tterm
passes false.

#### `lib/view_terminal.ml(i)`

```ocaml
(** Render driver for the terminal-only binary: sub-tab strip at top,
    active terminal content full-width, status bar at bottom. *)

val render_all : Render.t -> unit
```

~50 lines. Reuses:
- `Render.draw_tab_bar` for the sub-tab strip (terminal titles).
- `Terminal.render` for the active tab's content (same call as
  `lib/view.ml:383`).
- A new `update_status` that fills the status bar with the
  terminal-only content described below.

The pane-rect layout collapses: no `PScript`, no `PGoals`, no
`PMinimap`. `PMessages` is the whole grid minus the tab strip and
status bar. Either:
- Reuse `Render`'s existing layout knobs (a new "no-script mode" in
  `Render.set_*` calls), OR
- Compute the messages rect inline in `View_terminal` and skip
  `Render.pane_rect` for terminal mode entirely.

The second is cleaner — fewer `Render` mode bits — and adds
~10 lines of geometry.

### `bin/tterm.ml` (new)

Estimated ~150 lines. Skeleton:

```ocaml
open Rocqtui_lib

let () =
  let xcompose = ref false in
  Array.iter (fun a ->
    if a = "--xcompose" || a = "-xcompose" then xcompose := true
  ) Sys.argv;

  Sys.set_signal Sys.sigint Sys.Signal_ignore;
  Sys.set_signal Sys.sigtstp Sys.Signal_ignore;
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  Term.init ();
  let r = Render.create () in
  Theme.apply Theme.default;

  (* A stub editor context. Most fields are nominally per-tab/
     per-buffer in rocqtui; tterm fills them with sensible defaults
     so the shared compose/terminal_input code can run unchanged. *)
  let ctx = Editor_context.create
    ~switch_tab:(fun _ -> ())
    ~switch_to_tab_id:(fun _ -> ())
    ~open_files:(fun () -> [])
    ~tabs:(fun () -> [])
    () in
  if !xcompose then Editor.init_compose ctx;
  ctx.focus <- FMessages;

  Terminal.set_clipboard_hook (fun text ->
    ctx.clipboard <- text;
    Clipboard.copy_to_system text);

  (* Open the initial terminal. *)
  let cwd = Sys.getcwd () in
  let term = Terminal.create ~cwd ~cmd:None ~env:[||] in
  Msg_pane.ensure (Msg_pane.Terminal term) |> ignore;
  Msg_pane.activate (Msg_pane.Terminal term);

  let running = ref true in
  let stdin_fd = Unix.stdin in

  View_terminal.render_all r;
  Render.present r;

  while !running do
    let term_fds = Terminal.fds () in
    let ready =
      Main_loop.select_with_watches
        (stdin_fd :: List.map fst term_fds)
        0.1
    in
    (* Poll terminals *)
    List.iter (fun (fd, t) ->
      if List.mem fd ready then
        if Terminal.poll t then Render_need.request ()
    ) term_fds;
    List.iter (fun (_, t) ->
      let pty = Terminal.pty t in
      if Vterm_lib.Pty.has_buffered pty then Vterm_lib.Pty.flush_write pty
    ) term_fds;

    Msg_pane.sync_terminals ();
    if Msg_pane.state ()).tabs = [] then running := false;

    if Term.check_resize () then begin
      Render.resize r;
      Render_need.request_full ()
    end;

    if List.mem stdin_fd ready then begin
      let rec drain () =
        match Input.read_event ~timeout:0.0 stdin_fd with
        | None -> ()
        | Some Input.Resize ->
          Render.resize r;
          Render_need.request_full ();
          drain ()
        | Some ev ->
          let active = match Msg_pane.active_kind () with
            | Msg_pane.Terminal t -> Some t
            | _ -> None
          in
          (match Terminal_input.handle ~include_rocqtui_bindings:false
                   ctx ev active r with
           | Terminal_input.Quit -> running := false
           | Terminal_input.Close_term ->
             (match active with
              | Some t -> Terminal.destroy t
              | None -> ())
           | Terminal_input.Open_term ->
             let t = Terminal.create ~cwd:(Sys.getcwd ())
                       ~cmd:None ~env:[||] in
             Msg_pane.ensure (Msg_pane.Terminal t) |> ignore;
             Msg_pane.activate (Msg_pane.Terminal t)
           | Terminal_input.Copy_selection -> ()  (* handled inside *)
           | Terminal_input.Continue -> ()
           | Terminal_input.Pass_to_term ->
             (match active with
              | Some t -> Pty.forward_event t ev
              | None -> ()));
          Render_need.request ();
          if !running then drain ()
      in
      drain ()
    end;

    (match Render_need.take () with
     | Render_need.No -> ()
     | Render_need.Yes -> View_terminal.render_all r; Render.present r
     | Render_need.Full ->
       View_terminal.render_all r; Render.present ~force:true r)
  done;

  List.iter Terminal.destroy (Terminal.all ());
  Term.teardown ()
```

(Exact signatures of `Pty.forward_event` / `Terminal_input.handle`
get pinned down during implementation.)

### `bin/dune`

Add a second executable stanza:

```dune
(executable
 (name tterm)
 (public_name tterm)
 (package rocqtui)
 (libraries rocqtui_lib unix))
```

Or split into two `dune` files if the existing `(executable …)` form
doesn't allow multiple stanzas — quick check during implementation.

### `rocqtui.opam`

`tterm` ships under the same opam package. No new dependencies.

## Status bar contents

Three slots, all already cheap to compute:

| Slot   | Content                                                  |
|--------|----------------------------------------------------------|
| Left   | Active terminal title (`Terminal.title`)                 |
| Center | XCompose pending sequence (`View.format_compose_status`) |
| Right  | Scrollback indicator (when scrolled) + `[i/n]` position  |

When no terminal is active (e.g. last one closed but program hasn't
exited yet — shouldn't happen in v1's "last close exits" semantics,
but defensively): empty status line.

## Behaviors

- **Mouse:** clicks on the sub-tab strip switch active terminal
  (already implemented in `Render` / `View`). Drags / scroll wheel
  inside the terminal pane forward to the terminal as today.
- **Resize:** every terminal resized to current messages-pane dims
  on each frame (already in `View.render_messages:374`).
- **Last terminal closed:** program exits. Implemented by checking
  `Msg_pane.state().tabs = []` after `sync_terminals` (see skeleton).
- **^C:** never intercepted (no Rocq session to interrupt) — always
  reaches the active shell.
- **Tab bar:** always shown (even with one tab), since it's the only
  affordance for spawning more.

## Tab switching: mouse only

No keyboard binding for cycling tabs. Two mouse affordances:

1. **Click a sub-tab in the top strip** → activate it. Existing handler
   at `lib/editor/mouse.ml:174` already does this for `PTabBar`; tterm
   reuses the pattern but calls `Msg_pane.activate` instead of
   `ctx.switch_tab`.
2. **Scroll wheel over the top strip** → cycle to prev/next sub-tab.
   New behavior. Implementation:
   - Add `Msg_pane.activate_prev` / `Msg_pane.activate_next` (one-liners
     that compute `(active ± 1) mod n` and call `activate` with the
     resulting kind).
   - tterm's inline mouse handler dispatches `Input.Mouse` events
     with `button = WheelUp/WheelDown` and `pane = PTabBar` to those.
   - Not added to rocqtui's existing mouse handler — rocqtui's top
     bar is file tabs, not sub-tabs; behavior would differ. If rocqtui
     wants the same affordance later, lift it then.

Mouse handling in tterm is small enough to live inline in `bin/tterm.ml`
(maybe 30 lines): click on tab strip → switch, wheel on tab strip →
cycle, click in terminal pane → already nothing to do (only one focus
target), wheel/drag in terminal pane → forward to terminal via
`Pty.forward_event` (same as rocqtui's terminal-pane mouse path). No
need to extract a `Terminal_mouse` module yet.

## Host window title

The host terminal's window title is set to the active terminal's title.
rocqtui doesn't currently set the host title, so this is fresh code:
emit `ESC ] 0 ; <title> ESC \` (OSC 0) to stdout whenever the active
sub-tab changes or `Terminal.title` of the active tab changes. Cheap to
poll once per render. ~5 lines either inline in `bin/tterm.ml` or as a
small `Render.set_window_title : string -> unit` helper (latter is more
self-documenting; pick during implementation).

## Editor_context stubbing

For v1, `bin/tterm.ml` instantiates `Editor_context.t` with no-op
closures for the script/Rocq fields (`switch_tab`, `open_files`, `tabs`,
etc.). `Compose` and `Terminal_input` only read `compose`, `clipboard`,
`modal`, `focus` — the subset that's meaningful here. Refactoring
`Editor_context` into "small" + "full" records is deferred; revisit if
a third consumer appears.

## Test plan

- `dune build` succeeds; `bin/tterm.exe` produced.
- Launch tterm, observe shell prompt; type commands, see output.
- `^T` spawns a second shell; sub-tab strip shows two titles.
- Click each sub-tab → switches active terminal.
- `^W` on each closes it; closing the last exits the program.
- `^C` reaches the shell (interrupts a `sleep 30`).
- `^Y` after a mouse selection copies to the system clipboard.
- `--xcompose`: ESC starts compose, multi-key sequences produce
  unicode characters typed into the shell.
- Window resize redraws correctly; long shell output scrolls; the
  scrollback indicator appears when scrolled up.
- No `dune runtest` regressions in rocqtui (shared `lib/` changes
  must not break the existing binary).

## Out-of-scope follow-ups

- A small e2e test harness for tterm (analogous to `test/e2e/`).
- A `--cmd` flag to start with a specific command instead of `$SHELL`.
- Theme support (`-theme`) — currently hardcoded to `Theme.default`;
  trivial to add but no urgent need.
- Per-terminal title customization (rename tab, etc.).
