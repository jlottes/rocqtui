(** File-tree panel widget. Persistent left-side navigator. Supports
    two views over the same project: [VTree] (filesystem hierarchy
    with expandable directories) and [VDepOrder] (flat dependency-
    ordered list with closure-based dimming). *)

type t

(** Per-open-file status flags rendered as glyphs in the panel. *)
type file_status = {
  modified : bool;       (** Buffer has unsaved changes ("*") *)
  disk_changed : bool;   (** Underlying file changed on disk ("⟳") *)
}

type view = VTree | VDepOrder

(** Create a new file-tree state. Starts in [VTree] view. The widget
    enumerates the filesystem immediately; the dependency graph is
    injected later via [set_dep_graph] (the dep view shows
    "computing…" until then). *)
val create : project_dir:string -> project_file:string -> t

(** The project file this tree was built against. *)
val project_file : t -> string

(** Current view. *)
val view : t -> view

(** Toggle between [VTree] and [VDepOrder]. *)
val cycle_view : t -> unit

(** Re-enumerate files from disk and rebuild visible lines (current
    view only). *)
val refresh : t -> unit

(** Filter mode active. The editor uses this to know whether to leave
    "." as filter input or intercept it for [reveal]. *)
val in_filter : t -> bool

(** Snap selection to [path] in the current view. Clears the filter,
    expands ancestor directories (tree view), no-ops if [path] is not
    under the project root. *)
val reveal : t -> path:string -> unit

(** Replace the dependency graph used by the dep view. [running]
    indicates whether a [rocq dep] subprocess is in flight — the
    panel header shows "computing…" while true. Cheap to call every
    frame; only rebuilds dep_lines when [graph] actually changes. *)
val set_dep_graph : t ->
  graph:Dep_graph.t option -> running:bool -> unit

type action =
  | TreeContinue
  | TreeOpen of string
  | TreeToggleProject of string
      (** Project-relative path. Tree view, on a non-directory entry, [p]
          requests a [_RocqProject] membership toggle for that file. *)
  | TreeUnhandled

val handle_key : t -> Render.t -> int -> action
val handle_click : t -> Render.t -> y:int -> action
val handle_scroll : t -> Render.t -> int -> unit

val render : t -> Render.t ->
  open_files:(string * file_status) list ->
  focused:bool -> unit
