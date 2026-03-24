(** Parse _RocqProject / _CoqProject files for coqidetop arguments. *)

(** Search for a project file in the cwd, then the file's directory and
    parents. Returns the directory containing the project file and the
    list of arguments to pass to coqidetop. *)
val find_args : string option -> string option * string list
