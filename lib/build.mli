(** Async build subprocess management. *)

(** Whether a build is currently running. *)
val is_running : unit -> bool

(** Description of the current build (e.g. "make theory/groups.vo"). *)
val description : unit -> string option

(** Get the fd to watch in select, or None. *)
val watch_fd : unit -> Unix.file_descr option

(** Read available output. Returns true if new lines were added. *)
val poll : unit -> bool

(** Get output lines in order (oldest first). *)
val output : unit -> string list

(** Cancel the running build. *)
val cancel : unit -> unit

(** Clear finished build state. *)
val clear : unit -> unit

(** Build a specific .v file via make. Returns false if busy. *)
val build_file : project_dir:string -> string -> bool

(** Build all via make. Returns false if busy. *)
val build_all : project_dir:string -> bool

(** Derive the .vo make target from a .v path. *)
val vo_target : project_dir:string -> string -> string

(** Build dependencies of a .v file (not the file itself). Returns false if busy. *)
val build_deps : project_dir:string -> string -> bool

(** Run make clean. Returns false if busy. *)
val build_clean : project_dir:string -> bool
