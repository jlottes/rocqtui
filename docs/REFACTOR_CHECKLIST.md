# Refactoring Checklist

Progress tracker for REFACTOR.md items, in priority order.

## H. Render Scheduling ✅
- [x] Define `render_need` type in a module (not inline int)
- [x] Replace `needs_render : int ref` with proper type
- [x] Clean up `request_render` / `request_full_render` helpers

## E. Extract File Manager ✅
- [x] Create `file_manager.ml` module
- [x] Move file watching setup from main.ml
- [x] Move reload heuristics (verified region check, disk_changed)
- [x] Move `reload_tab` (rewind session + reload + re-watch)
- [x] Define `file_event` type (Reloaded, DiskChanged, VerifiedAffected)
- [x] main.ml calls `File_manager.poll` and handles events
- Note: prompt logic stays in main.ml (will move with Modal Manager)

## F. Dependency Injection for Callbacks ✅
- [x] Define `Editor_context.t` record type
- [x] Replace `set_tab_bar_click_handler` with `ctx.switch_tab`
- [x] Replace `set_open_files_fn` with `ctx.open_files`
- [x] Replace `set_status_extra` with `ctx.status_extra`
- [x] Replace `set_init_error` with `ctx.init_error`
- [x] Replace `set_current_theme` with `ctx.theme_name`
- [x] Pass context to `handle_event` and `render_all`
- [x] Remove all `set_*` functions from editor.mli

## I. Tab Manager Enhancement ✅
- [x] Add `Tab.open_or_switch` (create tab or switch to existing)
- [x] Add `Tab.switch_to_id` (switch by tab ID)
- [x] Move project args lookup into `open_or_switch`
- [x] Simplify main.ml's Open_file handler (30→10 lines)
- [x] Simplify main.ml's Jump_back handler (25→12 lines)
- Note: file watcher + tab bar enable stay in main.ml (per-action)

## B. Modal Manager ✅
- [x] Define `Modal.kind` variant (Help, QueryMenu, OptionsMenu, ThemeMenu, BuildMenu, FilePicker)
- [x] Create `modal.ml` with stack (push/pop/toggle/dismiss)
- [x] Add `Modal.t` to `Editor_context.t`
- [x] Replace 5 boolean refs with Modal.is_open/push/pop/toggle
- [x] Replace help_scroll ref with Modal.Help mutable field
- [x] Update all modal checks in render_all and handle_event
- Note: event dispatch still in editor.ml (handlers not extracted to separate files yet — that's item C)

## G. Prompts as Modals ✅
- [x] Define `Prompt` modal variant with message + handler callback
- [x] Define `prompt_result`: Handled, Dismissed, Ignored
- [x] Convert "unsaved changes on quit" prompt
- [x] Convert "unsaved changes on close tab" prompt
- [x] Convert "save conflict" prompt (disk_changed)
- [x] Convert "reload confirm" prompt
- [x] Remove `prompt_unsaved`, `read_blocking_event`, `ctrl_w_ev`, `ctrl_x_ev`
- [x] handle_event dispatches to Prompt handler, re-processes on Dismissed

## A. App State Record ✅
- [x] Move editor.ml globals to Editor_context.t:
  clipboard, compose, dragging, jump_stack, jump_target
- [x] Move drag_mode and jump_point types to Editor_context
- [x] Thread through handle_event, render_all, init_compose, take_jump_target
- [x] Remove 5 bare refs from editor.ml (now zero)
- [x] Move Render.overlay_ref into Render.t (no more global ref)
- [x] Move File_picker.state into Modal.FilePicker (no more global ref)
- Remaining module-level refs (acceptable — module-internal state):
  - build.ml active (singleton build process)
  - keys.ml kitty_enabled (terminal capability)
  - theme.ml current_attrs (active theme)
  - render_need.ml state (render scheduling)
  - term.ml termios/sigwinch (terminal singleton)
  - main_loop.ml watches (Spawn.Async infrastructure)
  - tab.ml next_id (counter)
  - input.ml debug_log (debug infrastructure)

## C. Split editor.ml ✅
- [x] Extract rendering into `view.ml` (render_script, render_goals,
  render_messages, render_help, render_all, update_status, etc.)
- [x] Move modal helpers, pane selection helpers, compose display to view.ml
- [x] editor.ml: 1765→1153 lines (input handling only)
- [x] view.ml: 612 lines (all rendering)
- [x] main.ml calls View.render_all, editor.ml calls View helpers
- Note: further splitting (handler.ml, mouse.ml) possible but not urgent

## C2. Further editor.ml split ✅
See [`EDITOR_SPLIT.md`](EDITOR_SPLIT.md) for the detailed plan.
Broke the ~1629-line `editor.ml` into a `lib/editor/` namespace using
`(include_subdirs qualified)`. editor.ml: 1629 → 521 lines, with 9
focused submodules (action, block, geom, jump, keymatch, modals,
mouse, pty, script).

## D. Event-Driven Architecture (optional)
- [ ] Define unified `event` type (input, file, session, build, mcp, timer)
- [ ] Create event queue
- [ ] Define `command` type for state changes
- [ ] Refactor main loop: select → enqueue → dispatch → render
- [ ] Make dispatch testable (pure function from event to commands)
