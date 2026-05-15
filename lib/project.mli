(** Reading and editing _RocqProject / _CoqProject files.

    Callers obtain a [t] via [read], [find], or [find_for] and read out
    the fields they need. The line-by-line structure is preserved only
    inside [toggle_member]. *)

(** Conventional project-file names, in search priority order. *)
val filenames : string list

(** A -R or -Q directive resolved into absolute paths. *)
type load_path = {
  implicit : bool;          (** -R = true, -Q = false *)
  physical_dir : string;    (** absolute *)
  logical_prefix : string;
}

(** A parsed project file. Immutable snapshot of what was on disk at
    [read] time. *)
type t = {
  path : string;              (** absolute path to the project file *)
  project_dir : string;       (** directory containing it *)
  load_paths : load_path list;
  listed_files : string list; (** absolute paths, uncommented entries only *)
  args : string list;         (** args ready to pass to coqidetop *)
}

(** Parse a project file at [path]. *)
val read : string -> t

(** Walk upward from [dir] looking for a project file. Returns the
    parsed project, or [None] if no project file was found above [dir]. *)
val find : string -> t option

(** Search cwd first, then the directory of [filename] (if given and
    different from cwd). *)
val find_for : ?filename:string -> unit -> t option

(** All .v files reachable through any of the project's load paths,
    sorted and de-duplicated. Walks the filesystem on each call. *)
val all_v_files : t -> string list

(** Resolve a dotted module name (e.g. ["Foo.Bar.Baz"]) to a .v file
    path under one of the project's load paths. *)
val resolve_module : t -> string -> string option

(** Membership of a project-relative path in the project file. *)
type membership = [`Active | `Commented | `Absent]

val membership : t -> rel:string -> membership

type toggle_outcome = [`Added | `Removed]

(** Toggle membership of [rel] (a project-relative path) and persist to
    disk. Returns the freshly re-read project alongside the outcome:
    [`Added] for [`Absent]/[`Commented] -> active, [`Removed] for
    [`Active] -> commented.

    - [`Active]   → comment the existing line (`# rel`).
    - [`Commented] → uncomment the existing line.
    - [`Absent]   → insert a new line at sorted position among .v file
      lines (before the first .v line whose rel sorts greater; else
      after the last .v line; else at end of file).

    The toggled line is re-emitted in canonical form
    (`# rel` / `rel`); all other lines round-trip verbatim. *)
val toggle_member : t -> rel:string -> t * toggle_outcome
