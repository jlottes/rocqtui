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

## I. Tab Manager Enhancement
- [ ] Add `Tab.open_or_switch` (create tab or switch to existing)
- [ ] Move project args lookup into Tab module
- [ ] Move file watcher registration into Tab module (or File_manager)
- [ ] Move display bar enable/disable into Tab module
- [ ] Simplify main.ml's Open_file / Jump_back handlers

## B. Modal Manager
- [ ] Define `modal` variant type (Help, QueryMenu, OptionsMenu, etc.)
- [ ] Create `modal_manager.ml` with stack
- [ ] Extract help screen state and handlers from editor.ml
- [ ] Extract query menu state and handlers
- [ ] Extract options menu state and handlers
- [ ] Extract theme menu state and handlers
- [ ] Extract build menu state and handlers
- [ ] Integrate file_picker as a modal
- [ ] Replace `Render.overlay_ref` with modal manager rendering
- [ ] Update `handle_event` to dispatch to modal manager

## G. Prompts as Modals
- [ ] Define `Prompt` modal variant with message, confirm_key, callbacks
- [ ] Convert "unsaved changes on quit" prompt
- [ ] Convert "unsaved changes on close tab" prompt
- [ ] Convert "save conflict" prompt (disk_changed)
- [ ] Convert "reload confirm" prompt
- [ ] Remove `prompt_unsaved` and `read_blocking_event` from main.ml

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
