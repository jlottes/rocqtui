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

(** Re-parse [output] (Build.output ()) into the cached entry list,
    resolving relative paths against [project_dir]. Cheap if the input
    list is identical to what we last parsed. Resets the F9 cursor when
    the output changes. *)
val refresh : project_dir:string -> string list -> unit

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

(** Drop all entries and the current index. *)
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
