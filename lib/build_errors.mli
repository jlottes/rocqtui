(** Parsed errors and warnings extracted from build output. *)

type severity = Error | Warning

type entry = {
  file : string;            (** Absolute path. *)
  line : int;               (** 1-based, as printed by rocq. *)
  col_start : int;          (** 0-based byte column. *)
  col_end : int;
  severity : severity;
  message : string;          (** Trimmed; may contain '\n'. *)
  output_row_start : int;   (** 0-based row index in build output (header line). *)
  output_row_end : int;     (** Inclusive — last row consumed. *)
}

(** Re-parse [output] (Build.output ()) and update the per-file slot
    table, resolving relative paths against [project_dir]. Files
    mentioned in the new parse have their slot replaced; files NOT
    mentioned keep their prior slot — a new build does not blow away
    errors from previous builds for files it hasn't reached yet. The
    F9 cursor is preserved across re-parses by identity match. Cheap
    if the input is identical to what we last parsed. *)
val refresh : project_dir:string -> string list -> unit

(** Walk every slot and drop those whose file's .vo has advanced past
    the mtime stamped on the slot — a successful rebuild has happened
    and the prior errors are no longer current. Returns true if any
    slot was dropped. Call this on .vo inotify events and on build
    finish. *)
val recheck_vo : unit -> bool

val all : unit -> entry list

(** Entries whose [file] equals [path] (string equality on absolute path). *)
val for_file : string -> entry list

(** Highest-severity marker for a given (file, 1-based line), or None. *)
val severity_for_line : file:string -> line:int -> severity option

(** Entry whose output row range covers [row] (0-based). *)
val lookup_by_output_row : int -> entry option

(** Index in [all ()] of the currently active entry, if any. *)
val current_index : unit -> int option

(** Move the cursor and return the new active entry. Wraps. Returns None
    when there are no entries. *)
val advance : forward:bool -> entry option

(** Set the current index by entry identity (typically used after click). *)
val set_current : entry -> unit

(** Drop every slot and the current index. Use on project switch or
    explicit reset — there is no longer any automatic clear-on-build,
    so this is the only "wipe everything" path. *)
val clear : unit -> unit

(** Project-relative .v paths of files with at least one [Error] entry
    in the current parse. Excludes warning-only files. *)
val error_files : project_dir:string -> string list

(** Render the Errors-tab body. The active entry (if any) is expanded
    with its full message; others are one-line. Updates an internal
    [row → entry] map used by [lookup_errors_tab_row]. Also returns the
    body row of the active entry's header (for auto-scroll), if any. *)
val render_errors_tab :
  project_dir:string -> Styled.line list * int option

(** Entry that occupies [row] (0-based) in the body returned by
    [render_errors_tab]. Returns None for a row outside the rendered
    body. *)
val lookup_errors_tab_row : int -> entry option
