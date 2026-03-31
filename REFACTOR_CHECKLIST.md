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

## A. App State Record
- [ ] Define `App_state.t` record
- [ ] Move editor.ml globals (clipboard, compose, dragging, jump_stack, etc.)
- [ ] Move build.ml global (active)
- [ ] Move keys.ml global (kitty_enabled)
- [ ] Move theme.ml global (current_attrs)
- [ ] Thread App_state through handle_event and render_all
- [ ] Remove bare refs from modules

## C. Split editor.ml
- [ ] Extract rendering into `view.ml` (render_script, render_goals, etc.)
- [ ] Extract input handling into `handler.ml` (handle_event dispatch)
- [ ] Extract mouse handling (drag, selection, hit testing)
- [ ] Keep editor.ml as thin coordinator
- [ ] Update interfaces

## D. Event-Driven Architecture (optional)
- [ ] Define unified `event` type (input, file, session, build, mcp, timer)
- [ ] Create event queue
- [ ] Define `command` type for state changes
- [ ] Refactor main loop: select → enqueue → dispatch → render
- [ ] Make dispatch testable (pure function from event to commands)
