(** File enumeration shared between the modal File_picker and the panel
    File_tree. Returns a sorted tree of entries; consumers handle
    rendering, selection, expansion state, and input. *)

type mode = Project | All

type entry = {
  full_path : string;   (** absolute path; "" for directory nodes *)
  rel_path : string;    (** project-relative; dirs include a trailing "/" *)
  name : string;        (** display segment; dirs include a trailing "/" *)
  is_dir : bool;
  in_project : bool;    (** listed in _RocqProject (always true for dirs) *)
}

type node =
  | Dir of entry * node list
  | File of entry

(** Enumerate files for the given mode and build a sorted tree.
    Directories come first within each level, then files; both alphabetical.
    Project mode lists only files in _RocqProject; All mode walks every
    .v file reachable via the project's load paths. *)
val enumerate :
  project_dir:string ->
  project_file:string ->
  mode:mode ->
  node list
