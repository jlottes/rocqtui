# Rocqtui Refactoring Brainstorm

Captured after the ncurses → Grid/Render/Term/Input migration, with a
large working codebase (~5000 lines of OCaml across 20+ modules).

## Current Pain Points

### 1. Monolithic main.ml (~460 lines)

The main loop mixes:
- Terminal lifecycle (init/teardown)
- Tab creation and management
- File watching + reload heuristics
- Build subprocess polling
- MCP server integration
- Session polling
- Input event reading and routing
- Render scheduling (needs_render 0/1/2)
- Modal prompt sub-loops (unsaved changes, save conflict, reload confirm)
- Tab bar rendering with display name computation

Each concern interacts with multiple subsystems. Hard to understand
control flow, hard to test, hard to extend.

### 2. Global mutable state everywhere

Scattered refs across modules:

| Module | Refs |
|--------|------|
| editor.ml | clipboard, compose_state, dragging, in_help_mode, in_query_mode, in_options_mode, in_theme_mode, in_build_mode, help_scroll, jump_stack, jump_target, init_error_msg, status_extra, current_theme_name, tab_bar_click_handler, open_files_fn |
| build.ml | active |
| file_picker.ml | state |
| keys.ml | kitty_enabled |
| theme.ml | current_attrs |
| render.ml | overlay_ref |

None are encapsulated. All are initialized ad-hoc. Hard to test.
Hard to reason about initialization order.

### 3. Modal dialog chaos

Five boolean refs for modals plus File_picker's own state ref.
Each modal re-implements event handling in handle_event.
Only one overlay at a time (render.ml's global overlay_ref).
No modal stack or composition.

### 4. Callback pattern for cross-module communication

Editor.ml uses callback refs set by main.ml:
- `set_tab_bar_click_handler` — switch tabs on tab bar click
- `set_open_files_fn` — file picker gets list of open files

These can be None, making them fragile. They couple main.ml and
editor.ml without a clear interface.

### 5. Prompt sub-loops duplicate event handling

main.ml has three prompt dialogs (unsaved changes, save conflict,
reload confirm) that each implement their own blocking event loop.
Duplicated logic for reading events, saving, displaying status.

### 6. editor.ml is too large (~1800 lines)

Combines rendering, input handling, mouse management, modal dispatch,
clipboard, compose, jump stack, and syntax highlighting coordination.

---

## Refactoring Ideas

### A. App State Record

Consolidate all mutable state into one record:

```ocaml
type t = {
  render : Render.t;
  tabs : Tab.manager;
  mcp : Mcp_server.t;
  watcher : File_watch.t;
  mutable clipboard : string;
  mutable compose : Compose.t option;
  mutable modal : modal option;
  mutable jump_stack : jump_point list;
  mutable dragging : drag_mode;
  mutable theme_name : string;
  mutable needs_render : render_need;
  mutable running : bool;
}
```

Thread through functions instead of globals. Benefits: testable,
snapshotable, clear initialization.

**Trade-off**: Adds a parameter to many functions. Could use a
module-level ref to a single `app` value as compromise.

### B. Modal Manager

Replace the five boolean refs with a variant + stack:

```ocaml
type modal =
  | Help of { mutable scroll : int }
  | QueryMenu
  | OptionsMenu
  | ThemeMenu
  | BuildMenu
  | FilePicker of File_picker.t
  | Prompt of prompt_state

type t = { mutable stack : modal list }

val handle_event : t -> Input.event -> modal_action
val render : t -> Render.t -> unit
val push : t -> modal -> unit
val pop : t -> unit
```

The prompt sub-loops in main.ml become just another modal:
push a `Prompt` modal, return to the main event loop, the prompt
modal handles its own keys. No more blocking sub-loops.

**Trade-off**: Prompts currently block and return a result inline.
Making them async requires restructuring the callers (e.g., Quit
action becomes "push quit-confirm prompt, handle confirmation
asynchronously").

### C. Separate Rendering from Input Handling

Split editor.ml into:
- `view.ml` — pure rendering: takes tab state, draws into Render.t
- `handler.ml` — input handling: takes event + state, returns action
- `editor.ml` — coordinator / thin wrapper

Benefits: rendering is testable (give it state, check grid cells),
input handling is testable (give it events, check returned actions).

**Trade-off**: More files, more interfaces. But each is focused.

### D. Event-Driven Architecture

Replace the imperative main loop with an event queue:

```ocaml
type event =
  | InputEvent of Input.event
  | FileChanged of string
  | SessionUpdated of int  (* tab id *)
  | BuildOutput of string
  | MCPRequest of ...
  | Timer

val dispatch : app_state -> event -> action list
```

The main loop becomes: select → enqueue events → dispatch → render.

**Trade-off**: Big architectural change. May be over-engineering
for a single-threaded TUI. But makes testing and debugging easier.

### E. Extract File Manager

Move file watching + reload logic out of main.ml:

```ocaml
module File_manager : sig
  type t
  val create : unit -> t
  val add_watch : t -> string -> unit
  val poll : t -> file_event list
end

type file_event =
  | Reloaded of string
  | NeedsReload of { path: string; verified_affected: bool }
  | DiskChanged of string
```

Main loop just calls `File_manager.poll` and handles the events.

**Trade-off**: Minimal. Clear win.

### F. Dependency Injection for Callbacks

Replace callback refs with an explicit context:

```ocaml
type editor_context = {
  switch_tab : int -> unit;
  open_files : unit -> string list;
  request_render : unit -> unit;
  request_full_render : unit -> unit;
}
```

Passed as a parameter to `handle_event`. No more `set_*_handler`
registration.

**Trade-off**: Adds a parameter. But makes dependencies explicit.

### G. Prompts as Modals (not sub-loops)

Currently main.ml has:
```ocaml
let handle_quit () =
  Display.set_status "Unsaved changes! ^X again...";
  let ch2 = blocking_read () in
  if ch2 = ^X then running := false
  else ...
```

This blocks the main loop. Replace with:
```ocaml
let handle_quit () =
  push_modal (Prompt {
    message = "Unsaved changes! ^X again...";
    on_confirm = (fun () -> running := false);
    confirm_key = Keys.quit;
  })
```

The prompt renders in the status bar. The main loop continues.
When the user presses ^X, the prompt's on_confirm fires.
Any other key dismisses the prompt.

**Trade-off**: Quit is no longer synchronous — the caller can't
wait for the result. But this matches how real TUI frameworks work.

### H. Render Scheduling Cleanup

Replace `needs_render : int ref` with a proper type:

```ocaml
type render_need = NoRender | Render | FullRender
```

And put it in app_state. Any code that wants to trigger a render
calls `app.request_render ()` or `app.request_full_render ()`.

Currently almost done — the `type ... in` trick doesn't work in
OCaml, so we use ints. Moving to a proper type in a module fixes this.

**Trade-off**: Trivial change, clear win.

### I. Tab Manager Enhancement

Move tab-related logic from main.ml into Tab:

```ocaml
val open_file : manager -> string -> args:string list -> t
  (* creates tab or switches to existing one *)
val open_or_switch : manager -> string -> t
val close_active_with_prompt : manager -> close_action
  (* returns NeedsSave | Closed | LastTab *)
```

main.ml currently does file existence checking, project args
lookup, tab creation, display bar enabling, and file watching
inline. All of this belongs in Tab (or a TabManager module).

**Trade-off**: Tab module grows. But main.ml shrinks significantly.

---

## Suggested Priority Order

1. **H. Render scheduling** — trivial, define the type properly
2. **E. Extract File Manager** — clear win, moderate effort
3. **F. Dependency injection** — replace callback refs
4. **I. Tab Manager enhancement** — move logic out of main.ml
5. **B. Modal Manager** — biggest architectural improvement
6. **G. Prompts as modals** — depends on B
7. **A. App State record** — consolidate globals
8. **C. Split editor.ml** — depends on A and B
9. **D. Event-driven** — optional, biggest change

## Non-Goals

- **Don't over-abstract**: This is a single-threaded TUI app. We don't
  need a full ECS, event bus, or dependency injection framework.
- **Don't make it "pure functional"**: Mutable state is fine for UI.
  The goal is to make it *organized* mutable state, not eliminate it.
- **Don't break working features**: Each refactoring step should
  compile and pass tests. No big-bang rewrites.

## Principles

- **One reason to change**: Each module should have one responsibility.
- **Explicit dependencies**: No global state; pass what you need.
- **Composable modals**: Any modal can be pushed/popped without
  special-casing in the main loop.
- **Testable by construction**: Pure rendering, explicit state.
- **Small commits**: Each refactoring step is independently useful.
