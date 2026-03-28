(** Parse _RocqProject / _CoqProject files for coqidetop arguments. *)

(** Search for a project file in the cwd, then the file's directory and
    parents. Returns the directory containing the project file and the
    list of arguments to pass to coqidetop. *)
val find_args : string option -> string option * string list

(** Load path entry from -R/-Q flags. *)
type load_path_entry = {
  physical_dir : string;
  logical_prefix : string;
  implicit : bool;  (** -R = true, -Q = false *)
}

(** Search for a project file starting from [dir] and upward.
    Returns [(project_dir, project_file_path)] or None. *)
val find_project_file : string -> (string * string) option

(** Parse load path entries (-R/-Q) from a project file. *)
val load_paths : string -> load_path_entry list

(** List .v files explicitly listed in a project file (absolute paths). *)
val listed_files : string -> string list

(** Recursively find all .v files under a directory. *)
val find_v_files : string -> string list

(** Get all .v files reachable through load path entries. *)
val all_v_files : load_path_entry list -> string list

(** Resolve a dotted module name (e.g. "Foo.Bar.Baz") to a .v file path. *)
val resolve_module : load_path_entry list -> string -> string option
