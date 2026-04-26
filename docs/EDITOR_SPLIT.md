# Editor.ml Split Plan

Follow-up to REFACTOR_CHECKLIST item C. After extracting rendering into
`view.ml`, `editor.ml` is still ~1629 lines and dominated by a single
`handle_event` function of ~1300 lines. This plan breaks it into a
focused namespace under `lib/editor/`.

## Layout

Use `(include_subdirs qualified)` in `lib/dune` so modules in the
subdirectory are accessible as `Editor.Geom`, `Editor.Mouse`, etc. from
outside, and unprefixed (`Geom`, `Mouse`) from siblings inside
`lib/editor/`. Same library — no circular-dep issue with Tab, Buffer,
View, Render, Modal, Keys, Compose, Session.

```
lib/editor/
  editor.ml      — public API (action type, handle_event dispatcher)
  editor.mli
  geom.ml        — screen↔buffer coords
  keymatch.ml    — match_binding, codepoint_of_event
  jump.ml        — jump stack push/pop
  block.ml       — edit-blocking / target rewind
  pty.ml         — open_tab, send_escape, forward_event (PTY routing)
  mouse.ml       — mouse handling
  script.ml      — script-pane keys
  modals.ml      — file picker / build / theme / options / query / help
```

`pty.ml` rather than `terminal.ml` to avoid shadowing the existing
`Lib.Terminal` module from inside `lib/editor/`.

## Source map (current editor.ml → new home)

| Lines       | Content                                              | Destination          |
|-------------|------------------------------------------------------|----------------------|
|    1– 22    | action type, init_compose, take_jump_target          | editor/editor.ml     |
|   25– 37    | jump stack push/pop                                  | editor/jump.ml       |
|   39– 78    | cursor_in_target, edit_blocked, rewind_if_needed     | editor/block.ml      |
|   81– 94    | query_subject, run_query                             | editor/modals.ml     |
|   96–119    | normalize_newlines, insert_string                    | editor/script.ml     |
|  121–167    | screen_to_buffer_pos, screen_to_pane_pos             | editor/geom.ml       |
|  169–193    | pane_select_word (DEAD CODE)                         | delete               |
|  198–283    | match_binding, codepoint_of_event                    | editor/keymatch.ml   |
|  286–318    | open_terminal_tab, send_escape_to_terminal           | editor/pty.ml        |
|  329–373    | compose-mode pre-handling                            | editor/editor.ml     |
|  375–427    | Modal Prompt + file-picker dispatch                  | editor/modals.ml     |
|  430–459    | debug-input logging                                  | editor/editor.ml     |
|  461–822    | global key dispatch (non-mouse)                      | split: editor.ml + modals.ml |
|  822–1131   | mouse handling                                       | editor/mouse.ml      |
|  1135–1313  | paste, jump-to-def, help, minimap, about, copy, etc. | editor/editor.ml     |
|  1315–1488  | handle_pane_scroll, handle_script                    | editor/script.ml     |
|  1500–1617  | Messages-pane terminal forwarding                    | editor/pty.ml        |

## Steps

Each step is one commit. Build + manual smoke-test (`dune exec
bin/main.exe -- <file.v>`) between steps.

### Step 0: prep ✅
- [x] Bump `(lang dune 3.0)` → `(lang dune 3.7)` in `dune-project` (required for `qualified`)
- [x] Add `(env (_ (flags (:standard -w -69))))` in root `dune` to suppress new
      unused-record-field warnings on pre-existing pre-refactor fields
- [x] Add `(include_subdirs qualified)` to `lib/dune`
- [x] Add `(include_subdirs no)` to `lib/vterm/dune` (opt out of parent's qualified mode)
- [x] Move `editor.ml` and `editor.mli` to `lib/editor/`
- [x] Delete dead `pane_select_word`
- editor.ml: 1629 → 1603 lines

### Step 1: pure utilities (lowest risk) ✅
- [x] Extract `lib/editor/geom.ml` — `screen_to_buffer_pos`, `screen_to_pane_pos` (45 lines)
- [x] Extract `lib/editor/keymatch.ml` — `match_binding`, `codepoint_of_event` (85 lines)
- [x] Extract `lib/editor/jump.ml` — `push`, `pop` (renamed from `push_jump`/`pop_jump`) (13 lines)
- [x] Extract `lib/editor/block.ml` — `edit_blocked`, `rewind_if_needed`; `cursor_byte_offset`/`cursor_in_target` kept private (32 lines)
- editor.ml: 1603 → 1410 lines

### Step 2: PTY routing ✅
- [x] Extract `lib/editor/pty.ml` (139 lines):
  - [x] `open_tab : ?cmd:string -> Tab.t -> Render.t -> unit` (was `open_terminal_tab`)
  - [x] `send_escape : Tab.t -> unit` (was `send_escape_to_terminal`)
  - [x] `forward_event : Terminal.t -> Input.event -> unit` (Messages-arm block)
  - Module-private: `encode_utf8`, `input_mod`
- [x] editor.ml's terminal-focused Messages-arm collapses to two lines
- editor.ml: 1410 → 1262 lines

### Step 3: mouse
- [ ] Extract `lib/editor/mouse.ml`:
  - [ ] `handle : Editor_context.t -> Input.mouse_event -> Tab.t -> Render.t -> action`
- [ ] editor.ml's `match ev with Input.Mouse m -> Mouse.handle ctx m tab r` arm

### Step 4: script-pane keys
- [ ] Extract `lib/editor/script.ml`:
  - [ ] Move `insert_string`, `normalize_newlines`
  - [ ] `handle : Editor_context.t -> Input.event -> Tab.t -> Render.t -> action option`
  - [ ] Move `handle_pane_scroll` (used by Goals/Messages too — keep public)

### Step 5: modals
- [ ] Extract `lib/editor/modals.ml`:
  - [ ] `handle_prompt`, `handle_picker`, `handle_build`, `handle_theme`, `handle_options`, `handle_query`, `handle_help`
  - [ ] One `handle_active : Editor_context.t -> Input.event -> Tab.t -> Render.t -> action option` entry point that dispatches based on `Modal.top`
- [ ] Move `query_subject`, `run_query` here

### Step 6: tidy
- [ ] editor.ml reduced to: action type, init/take_jump_target,
      compose pre-handling, top-level dispatch (modals → global → per-pane)
- [ ] Verify all `.mli` files have minimal API surface
- [ ] Update `docs/ARCHITECTURE.md` module map

## Done criteria

- editor.ml ≤ 300 lines
- Each new module ≤ 350 lines
- Each new module's `.mli` ≤ 10 functions
- Manual smoke test: open file, edit, step forward/back, jump to def,
  open terminal, mouse drag border, copy/paste, file picker, build
  menu — all working
- `dune build` clean, no new warnings

## Risks

- No automated tests cover `handle_event`. Validation is manual.
  Keeping each step a single commit makes regressions bisectable.
- Some `else if` arms in `handle_global` have ordering dependencies
  (e.g. Escape arm precedence). The top-level chain stays in
  editor.ml; submodules return `action option` so the dispatcher
  controls precedence.
- After extraction, helpers take 4–6 args (ctx, ev, tab, r, sometimes
  buf/session). This is verbose but makes dependencies explicit.
