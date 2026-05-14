# Dependency-order view — Design

Status: design draft. No code yet. Adds an alternate "view" to the
file-tree panel that lists `.v` files in topological dependency
order, with files outside the selected file's dependency closure
dimmed. Builds on the existing panel ([`FILE_TREE_PLAN.md`](FILE_TREE_PLAN.md)).

## Goals

- A second presentation of the same project's files: instead of the
  filesystem tree, a flat list sorted topologically by `Require`
  / load-path dependencies. Toggle between the views with a single
  key.
- **Selection-driven dimming**: when a file is selected in the list,
  files outside its dependency closure are dim. This makes the panel
  a navigable answer to "what's in scope for this proof?" without
  leaving it. (Pair with the existing `.` key to first snap selection
  to the active tab.)
- **Non-blocking dependency computation**. `rocq dep` is shell-out
  latency on real projects (multi-second on the affine repo). It runs
  asynchronously via the existing select-loop pattern; the panel
  shows "computing…" until the graph is ready, then re-renders.
- Modest infrastructure: don't over-generalize. Two views today,
  third one (git status) is a likely follow-up and will inform any
  abstraction worth pulling out. Until then, a `type view` variant is
  enough.

## UX

`F8` continues to toggle the panel as today. Inside the panel a new
key cycles the view:

```
┌─ Files (deps) ───────┐
│ ▸ interfaces/eq.v    │
│ ▸ orders/preorder.v  │
│ ▸ groups/setoid.v    │   <- ancestors of selected file (bright)
│ • orders/lattices.v  │   <- selected file (reverse video)
│ ▸ orders/locales.v   │   <- descendants of selected (bright)
│ ▸ algebra/ring.v     │   <- not in closure (dim)
│ ▸ topology/topology.v│   <- not in closure (dim)
└──────────────────────┘
```

- The list is a flat sequence in `tsort` order, dependencies first.
- Indent disappears — the filesystem hierarchy isn't meaningful in
  this view. Each line is just the file's project-relative path
  (e.g. `orders/lattices.v`).
- The dirty / disk-changed indicators from the tree view carry over
  unchanged (so a "*" file is still visibly modified).
- The currently-selected line's *transitive closure both directions*
  (ancestors + descendants) is drawn at normal brightness; everything
  else is dim. The selected line itself is reverse-video as today.
- While the graph is being computed (initial show, or after a
  ProjectChanged invalidation), the header shows `Files (deps,
  computing…)` and the list is empty (or, if a previous graph is
  cached, that graph is used until the new one arrives).

### Key bindings in the dep view

| Key | Effect |
|-----|--------|
| Up / Down / PgUp / PgDn / Home / End | Move selection (same as tree view). Dimming updates as selection moves. |
| Enter | Open the selected file. |
| `.` | Snap selection to the active tab's file (same as tree view). |
| `/` | Filter — same substring-on-rel-path behavior. Dimming applies on top of filter (filter narrows the list; closure dims within what's visible). |
| `^T` | Becomes a no-op in dep view (mode/scope are not user-tunable here — toposort is inherently across all reachable `.v`). Could later cycle the dimming policy (ancestors-only, descendants-only, both). |
| `v` | Cycle view: Tree → DepOrder → Tree. Future views slot in here. |
| `F8` | Toggle panel (closes regardless of view). |
| `^P` | Standard pane cycle. |
| Esc | Exit filter mode if active. |

### Dimming semantics

The "in-closure" set for selected file `f` is computed as:

```
closure(f) =
  ancestors(f)      U   { all v such that there exists path v -> ... -> f }
  descendants(f)    U   { all v such that there exists path f -> ... -> v }
  { f }
```

Both directions because each is a different question:

- **Ancestors**: "what does this file depend on?" — what gets loaded
  when you open `f`.
- **Descendants**: "what depends on this file?" — impact analysis if
  you edit `f`.

Files outside `closure(f)` render with the existing `dim_attr` (the
same attribute used today for non-project files in All mode).

If `f` is not in the graph (e.g., a new file the watcher saw but
`rocq dep` hasn't been re-run for yet), no closure is computed — all
files render at normal brightness.

## Architecture

### Phase 1 — `lib/dep_graph.ml`: graph data + closure queries

Pure module. No I/O, no subprocesses. Given the output of `rocq dep`
(or a pre-parsed edge list), exposes the graph and the closure
operation.

```ocaml
type t

(** Parse the Makefile-style output of `rocq dep -f _RocqProject`.
    Edges run from dependency to dependent. *)
val of_rocq_dep_output : string -> t

(** Project-relative .v file paths in topological order. *)
val toposort : t -> string list

(** All .v files in [g] reachable from [f] following edges in either
    direction — i.e., union of ancestors and descendants, plus [f].
    Returns an empty set if [f] is not a node. *)
val closure_bidirectional : t -> string -> string list

(** Just ancestors (left-of in toposort) or just descendants. Used if
    we later expose a "dimming policy" toggle. *)
val ancestors : t -> string -> string list
val descendants : t -> string -> string list
```

Internal representation: `(string, string list) Hashtbl.t` for the
forward edges and a parallel reverse-edge table. Toposort via Kahn's
algorithm — deterministic ordering by reading order of `rocq dep`'s
output makes the result reproducible. Tests in `test/test_dep_graph.ml`
covering: linear chain, diamond, isolated node, cycle (should be
detected and tolerated — emit what's possible).

The output of `rocq dep` is Makefile rules like:

```
groups/setoid.vo groups/setoid.glob ...: groups/setoid.v interfaces/eq.vo orders/preorder.vo
```

We extract pairs `(dep.vo, target.vo)` (excluding `target.vo` from
its own dependency list) and convert `.vo` → `.v` once on the way out.
The `affine/tools/toposort.sh` script is the reference implementation
for the parser, written in awk; we port it to OCaml.

### Phase 2 — `lib/dep_runner.ml`: async `rocq dep` subprocess

Mirrors `lib/build.ml`'s pattern. Spawns `rocq dep -f <project_file>`,
reads stdout non-blocking, parses on EOF, stores the resulting
`Dep_graph.t`.

```ocaml
type t

(** Create. No subprocess spawned yet. *)
val create : unit -> t

(** Start (or restart) a computation against [project_file]. If one
    is already running, kills it and starts fresh — only the latest
    request matters. *)
val refresh : t -> project_file:string -> unit

(** fd to add to the main-loop [select]. None when no subprocess is
    running. *)
val watch_fd : t -> Unix.file_descr option

(** Drain available data; on EOF parse + update [graph]. Returns
    [true] if [graph] changed and the panel should re-render. *)
val poll : t -> bool

(** Latest successfully-parsed graph, or [None] if we've never
    completed a computation. *)
val graph : t -> Dep_graph.t option

(** True while a subprocess is in flight (panel shows "computing…"). *)
val running : t -> bool
```

A single in-flight subprocess at a time is enough — if the project
changes while one is running, we kill and restart. No queueing.

Integration in `bin/main.ml`: add `Dep_runner.watch_fd` to the select
set; call `Dep_runner.poll` alongside `File_manager.poll`. When
`File_manager.ProjectChanged` fires, also kick off `Dep_runner.refresh`.

### Phase 3 — `File_tree` view variant

Add to `File_tree.t`:

```ocaml
type view = VTree | VDepOrder
```

Plus state:

```ocaml
mutable view : view;
mutable dep_graph : Dep_graph.t option;  (* injected from outside *)
mutable dep_lines : line array;          (* cached toposort order *)
```

`File_tree.render` branches on `view`:

- `VTree`: existing path, unchanged.
- `VDepOrder`: render `dep_lines` (flat, depth=0, no expand glyphs).
  If `dep_graph = None`, render a centered "Computing…" placeholder.

`File_tree.handle_key` accepts a new code for view-cycle (the editor
dispatcher translates `v` to it). All other panel-internal keys are
unchanged.

Selection movement in `VDepOrder` is over `dep_lines`, not `lines`.
The widget keeps the two index-spaces separate so switching views
doesn't lose your selection in the other.

A new external setter:

```ocaml
val set_dep_graph : t -> Dep_graph.t option -> unit
```

Called by `view.ml` each frame (cheap option-replace). When the
graph changes, `File_tree` rebuilds `dep_lines` and recomputes the
closure for the current selection.

### Phase 4 — Selection-driven dimming

When the panel is in `VDepOrder` and a `Dep_graph.t` is available:

1. Compute `closure = Dep_graph.closure_bidirectional g selected_path`
   when the selection changes (or after a graph update).
2. Cache the result on `File_tree.t` until the selection moves
   again.
3. In the render loop, when drawing each line, check membership in
   the cached closure set. Inside-closure lines use `normal_attr` (or
   `bold_attr` for selected/dirs); outside-closure lines use
   `dim_attr`.

Closure cache invalidation: any selection move, any view switch, any
graph update.

For `VTree`, no dimming change — the tree-view behavior is
unaffected. (Future work: optionally apply the same dimming in the
tree view too. Not in v1.)

### Phase 5 — Wiring

- `lib/keys.ml`: a new `cycle_panel_view` binding for `v`. In-panel
  context only — globally `v` is unbound, but we route it via
  `File_tree.handle_key` when the panel is focused.
- `lib/editor/editor.ml`: when the panel is focused and the event is
  `v` (outside filter mode), call `File_tree.cycle_view ft`.
- `lib/view.ml`: each render call to `File_tree.render` also passes
  the latest `Dep_runner.graph dr` via `set_dep_graph`. Cheap when
  unchanged.
- `bin/main.ml`: create `Dep_runner.t` alongside `File_manager.t`;
  add `watch_fd` to the select set; route the initial show of the
  panel (or first toggle to `VDepOrder`) to trigger a `refresh`. On
  `File_manager.ProjectChanged`, call `refresh` again.
- `lib/file_tree.ml`'s `set_dep_graph` propagates `running` state too
  (or that's queried separately) so the header can show "computing…".

## Module map summary

| File | Status | Purpose |
|------|--------|---------|
| `lib/dep_graph.ml` | new | Pure: parse `rocq dep` output, expose toposort + closure queries. |
| `lib/dep_runner.ml` | new | Async: spawn `rocq dep`, drain non-blocking, store latest graph. |
| `lib/file_tree.ml` | modified | New `view` variant, new render branch, dep_lines cache, dimming. |
| `lib/keys.ml` | modified | `cycle_panel_view` binding for `v`. |
| `lib/editor/editor.ml` | modified | Route `v` to `File_tree.cycle_view`. |
| `lib/view.ml` | modified | Pass `Dep_runner.graph` into `File_tree.render`. |
| `bin/main.ml` | modified | Create `Dep_runner`, watch its fd, drive `refresh` on project change. |
| `test/test_dep_graph.ml` | new | Unit tests for the parser, toposort, closure. |

## State ownership

- `Dep_runner.t` lives in `main.ml` alongside `File_manager.t`. Both
  are "owns a subprocess + an fd, polled by the main loop" services.
- `Dep_graph.t` is a value, not a singleton — `Dep_runner` owns the
  latest one and exposes it via `graph`. `File_tree` caches a
  reference for its render loop; it never mutates.
- View state (`view`, `dep_lines`, current closure) lives on
  `File_tree.t` — same lifetime as the panel.

## Out of scope for this work

- A general "view registry" abstraction. Two views, hardcoded.
  Pluggability when a third lands.
- Git status as a view. Plan to revisit after this lands; same
  pattern.
- Cross-file content search as a view. That's a filter extension,
  not a view.
- Dimming policy toggles (ancestors-only / descendants-only). v1
  always shows the bidirectional closure. Adding `^T` to cycle later
  is trivial.
- On-disk persistence of the parsed graph. Re-parsing is fast once
  `rocq dep` has run; the slow part is the subprocess.
- Dependency-edge visualization (e.g., showing which import comes
  from which line). The view is per-file, not per-edge.
- Reverting/changing the dim policy when no closure is computable
  (file not in graph). v1 just shows everything bright in that case.

## Implementation order

1. **Phase 1** — `Dep_graph` module + tests. Pure code, no UI. One
   commit. Verifiable in isolation via tests.
2. **Phase 2** — `Dep_runner` + integration into the main-loop
   select. One commit. No UI yet; can verify with a temporary status
   line that prints "deps computed in Xms".
3. **Phase 3 + 4** — `File_tree.view`, dep render path, dimming. One
   commit. End-to-end manually testable: press `v`, see the list;
   move selection, see dimming change.
4. **Phase 5** — final wiring polish: ProjectChanged → refresh, panel
   header "computing…", docs. Same commit as 3 unless 3 grows.

## Open questions

Reasonable defaults proposed; worth a sanity-check before each
phase.

- **View cycle key.** Proposal: `v` (lowercase, mnemonic). Free
  outside filter mode. Alternative: Tab (currently unbound in the
  panel). I'd lean `v` because Tab feels like "completion" elsewhere.
- **`^T` in dep view.** Proposal: no-op for now, with a clear path
  to repurposing it as "cycle dimming policy" later.
- **What to show during compute on first run.** Proposal: header
  reads `Files (deps, computing…)`, body is empty. Alternative:
  spinner glyph. I think a quiet placeholder is fine — the panel is
  rarely the user's first stop, and re-renders happen on every
  keystroke anyway.
- **What if selection is on a file not in the dep graph.** Proposal:
  no dimming applied — all files at normal brightness, so it's
  visually obvious that "this file isn't tracked yet". Re-runs on the
  next `ProjectChanged` (or `rocq dep` invalidation) should populate
  it.
- **Caching across project switches.** If user toggles F8 off, opens
  a file in a different project, toggles F8 back on, we re-initialize
  `File_tree` for the new project (already does). The dep_runner's
  graph from the old project is stale; refresh on the project change.
- **What happens to dimming when a file is added (ProjectChanged but
  before re-run completes).** The cached graph is from before the
  add; the new file isn't in it. Show all-bright until the next
  successful compute, then dimming snaps to the new closure.
