(** Async build subprocess management. *)

(** Whether a build is currently running. *)
val is_running : unit -> bool

(** Generation counter, bumped each time a new build is [start]ed.
    Stable while the same build runs and after it finishes — only
    changes when a fresh build replaces it. *)
val generation : unit -> int

(** Description of the current build (e.g. "make theory/groups.vo"). *)
val description : unit -> string option

(** Project dir of the current build (the CWD of the make subprocess). *)
val project_dir : unit -> string option

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

(** True while a build is running, or while the post-build result
    indicator is still visible. The main loop uses this to keep
    requesting renders so the spinner animates and the indicator
    times out cleanly. *)
val needs_repaint : unit -> bool

(** Status-bar indicator: spinner + description while running,
    ✓/✗ briefly after finish, empty otherwise. *)
val status_indicator : unit -> string
