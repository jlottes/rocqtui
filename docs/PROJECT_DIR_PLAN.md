# Single global project dir

## Motivation

Today, "what is the project?" is re-derived independently by several
subsystems, each from its own anchor. The anchors disagree, which
produces three concrete inconsistencies the user has hit:

1. **Save-as on a new tab** (`bin/main.ml:591`) called `Project.find_for ()`
   from cwd and silently fell back to `Sys.getcwd ()`. Launching rocqtui
   from `~/rocq/rocqtui` and opening a new tab to save into the affine
   project ended up anchored at `~/rocq/rocqtui` and prompted to create
   directories that already exist in affine.

2. **File picker (^O) and file tree (F8)** (`lib/editor/editor.ml:191-203`,
   `:341-360`) anchor at `Buffer.filename buf` of the active tab, then
   `Filename.dirname`, then `Project.find` walks up. On a new/blank tab,
   that's cwd. If cwd has no project, both show "No _RocqProject found."
   and silently refuse to open.

3. **File tree doesn't refresh on tab switch.** It's created against
   the project of whichever tab was active when F8 was first pressed,
   and stays there. Switching to a tab in a different project still
   shows the original tree.

The underlying cause is the same: every code path that needs a project
re-runs its own search with its own anchor. There is no single source of
truth, so they can disagree, and there is nothing to invalidate when the
context changes.

The current full set of project re-derivations:

| Site | Anchor used today |
|---|---|
| `bin/main.ml:6` build_initial_state — per-file rocq args | each filename arg |
| `bin/main.ml:144` refresh_dep_runner_for_dir | passed in |
| `bin/main.ml:591` save-as new tab | cwd, then nothing (silent fallback to cwd) |
| `lib/editor/editor.ml:191` ^O picker | active tab's filename, else cwd |
| `lib/editor/editor.ml:341` F8 file tree | active tab's filename, else cwd |
| `lib/editor/modals.ml:100` project_dir_of_buf — build menu | active tab's filename's dir |
| `lib/editor/modals.ml:281` rename prompt (F8 tree) | file_tree's stored project |
| `lib/editor/modals.ml:569` resolve_in_project — rename/save-as commit | passed in via modal state |

The motivation for a single global project is that **rocqtui is already
one-project-per-session in practice**. The file tree, project search,
build menu, `_RocqProject` toggling, and the MCP socket symlink all
assume one project. The mixed-project case (tabs from two different
projects in one rocqtui) is half-broken today: only one project's tree
is visible, only one's `_RocqProject` is searchable, and the build menu
uses whichever happens to be active.

## Proposed model

One `Editor_context.project : Project.t option` set at init time and not
mutated by tab operations.

- All subsystems that need the project read `ctx.project`.
- File tree, file picker, save-as, rename, build menu, project search
  all consult the same value.
- Switching tabs is purely a buffer/session switch; project does not
  change.
- The file tree, once created, is bound to the one project. Tab
  switches don't need to invalidate it.

`Project.find_for` and `Project.find` are still useful internally but
become an init-time concern, not a per-action one. The picker and tree
no longer have a "what if there's no project" failure path — if there's
no project, those features are unavailable until one exists (and we
offer to create one at startup).

## Init-time resolution

```
rocqtui [args...] [paths...]
```

Each non-flag positional `paths` is classified by `Sys.is_directory`.

1. **First directory arg, if any** → project_dir is that directory.
   File args following are opened as tabs. If the dir has no
   `_RocqProject`, prompt at startup (see below). If no file args were
   given, open with no tabs and show the file tree immediately.

2. **Otherwise, first file arg, if any** →
   `Project.find_for ~filename:f ()`. If a project is found, use it.
   If not, project_dir is `Filename.dirname f`, and we prompt.

3. **Otherwise (no positional args)** → `Project.find_for ()` from cwd.
   If found, use it; if not, project_dir is `Sys.getcwd ()`, and we
   prompt.

Rules of thumb:

- At most one directory arg. If more than one, error out — there's no
  sensible interpretation under a single-project model.
- All file args must live under the resolved project_dir. If any file
  arg is outside (after resolving symlinks via the existing
  `Tab.canonical_path`), warn at startup but still open the tab.
  Save-as and ^O still anchor at the project; the out-of-project tab is
  editable but rocqtui can't reason about its placement.
- The `args` field of the project (`-R`/`-Q` flags) is passed to every
  tab's Rocq session, not per-file. This changes today's behavior for
  mixed-project sessions; that case is being deprecated anyway.

## Missing _RocqProject startup prompt

When init resolution lands on a directory that has no `_RocqProject`
(cases 1b, 2b, 3b above), show a modal prompt:

```
No _RocqProject found in <dir>. Create one? [Enter to create, ESC to skip]
```

- **Enter / save key** → create `<dir>/_RocqProject` with a sensible
  default (just `-Q . Top` or similar — see open question below), reload
  the project, proceed.
- **ESC** → no project. The editor is still operable: tabs can be
  opened directly by path, save works on tabs that have filenames, ^S
  on a new tab uses `<dir>` as the anchor for save-as. File picker, file
  tree, project search, build menu, and `_RocqProject` toggling show
  "No project — press F? to create one" or similar in their status
  messages.

This prompt is non-blocking from the perspective of the render loop —
it's a `Modal.Prompt`, like the existing rename/save-as confirm flows.
The editor starts with the prompt on top of whatever initial layout the
positional args produced (tabs + maybe tree).

Open question: should ESK persist a "I don't want to be asked again"
hint for this session, or re-prompt on every ^S that needs a project?
Default: per-session dismiss is fine; re-prompt next launch.

## File-by-file changes

### Add `Editor_context.project`

`lib/editor_context.ml` gains a `mutable project : Project.t option`
field (mutable because the startup prompt can transition None → Some
when the user confirms creation). Constructor takes the initial value.

The existing `set_project_dir` callback in `Editor_context.t` keeps
its job (clears build errors, retargets the file watcher, retargets the
dep runner) but now it's only called once at init (and once more if the
user accepts the "create _RocqProject?" prompt).

### Replace `current_project_dir` ref in `bin/main.ml`

`bin/main.ml:143` (`let current_project_dir = ref None`) becomes
`ctx.project`. All readers (`refresh_build_status`, the build-output
parsers at `:400` and `:442`) read `ctx.project`. The setter wires up
the same side effects.

### CLI parser

`bin/main.ml:82-108` learns to split positionals into "first directory"
and "files". Resolution logic moves into a new helper
`resolve_initial_project` that returns either:

- `Some Project.t` — found and loaded
- `None, prompt_dir` — needs the missing-project prompt

`build_initial_state` shrinks: it no longer collects per-file project
dirs, and it uses the single resolved project's `args` for every tab.

### File picker (^O)

`lib/editor/editor.ml:190-205` becomes:

```ocaml
match ctx.project with
| None -> Render.set_status r "No project. Create one to use the picker."
| Some p ->
  let fp = File_picker.create
    ~project_dir:p.project_dir ~project_file:p.path
    ~open_files:(...) in
  Modal.push ctx.modal (Modal.FilePicker fp)
```

The `Filename.dirname buf` / `Sys.getcwd ()` anchor dance goes away.

### File tree (F8)

`lib/editor/editor.ml:340-360` similar collapse. `File_tree.create` is
called once and cached on `ctx.file_tree`; subsequent F8 just toggles
visibility (and snaps to current file as before). The
`need_new = ... project_file ft <> p.path` check at `:351` is dead:
the project doesn't change.

This also fixes #3 from the motivation list: switching tabs doesn't
invalidate the tree, because the tree was never project-per-tab in the
first place — we just stop pretending it could be.

### Save-as

`bin/main.ml:587-610` reduces to:

```ocaml
| None ->
  let project_dir = match ctx.project with
    | Some p -> p.project_dir
    | None -> Sys.getcwd ()  (* anchor here; save creates files in cwd *)
  in
  Modal.push ctx.modal (Modal.SaveAsPrompt {
    tab_id = tab.id; project_dir; extension = ".v";
    field = Text_field.create ();
  })
```

The fallback-to-open-tabs hack added in the previous fix
(`bin/main.ml:600-611`) is removed.

### Build menu

`lib/editor/modals.ml:100-104` (`project_dir_of_buf`) deletes. Build
menu reads `ctx.project`. Build entries are unavailable when there's
no project (status: "No project").

### Rename

`lib/editor/modals.ml:281-292` (rename initiated from file tree)
already has the project in hand via the tree. Same for the rename
commit at `:651`. These are read from `ctx.project` instead of being
plumbed through `rp.project_file` and `rp.project_dir`.

The modal state `Modal.rename_state` and `Modal.save_as_state` lose
their `project_dir` and `project_file` fields. Their handlers re-read
from `ctx.project` at commit time (with a defensive None check).

### MCP socket symlinks

`bin/main.ml:207` currently calls
`Mcp_server.create_project_symlink mcp` per project dir collected from
file args. Becomes a single call against `ctx.project.project_dir`
when one is set.

### Project search, dep runner

Already centrally driven (`bin/main.ml:144-148`, `:217-218`). No
changes beyond reading from `ctx.project` instead of the local ref.

## What stays the same

- `Project.find` / `Project.find_for` keep their signatures. They are
  still the source of truth for the upward-walk algorithm and the
  `_RocqProject` parser. They're just called fewer times.
- `Project.t` keeps its shape.
- Tab semantics, file watch semantics, build error parsing.

## Non-goals

- No support for opening files from outside the project as a
  first-class workflow. (You can still pass them on the command line;
  they open as tabs, save works, but the picker/tree/build are tied
  to the project.)
- No project switcher (change project mid-session). If the user wants
  a different project, that's a relaunch. Could be added later behind
  the same setter the startup prompt uses, but not in this plan.

## Open questions

- **What's in a fresh `_RocqProject`?** Minimal viable content is one
  line, e.g. `-Q . Top` or just an empty file. Empty file is fine — it
  parses as "no flags, no listed files" which is what an empty project
  is. Recommend empty.
- **Should the missing-project prompt be on by default, or behind a
  flag?** Current proposal: on by default. Easy to dismiss with ESC.
  Worth revisiting if it becomes noisy for the "I just want to scratch
  in a buffer" case.
- **Directory arg that doesn't exist?** Error and exit, like
  `rocqtui some-nonexistent.v` would. Don't silently treat it as cwd.
- **Out-of-project file args** — warn? silently allow? Recommend warn
  at startup ("foo.v is outside <project>") and otherwise allow.
