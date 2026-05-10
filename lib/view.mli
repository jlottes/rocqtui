(** View: rendering functions for the editor UI. *)

(** Modal helpers — access ctx.modal *)
val is_help : Editor_context.t -> bool
val is_options : Editor_context.t -> bool
val is_query : Editor_context.t -> bool
val is_theme : Editor_context.t -> bool
val is_build : Editor_context.t -> bool
val get_picker : Editor_context.t -> File_picker.t option

val get_help_scroll : Editor_context.t -> int
val set_help_scroll : Editor_context.t -> int -> unit

(** Pane selection helpers. *)
val clear_pane_selection : Tab.pane_selection -> unit
val pane_selection_text : Tab.pane_selection -> Styled.line list -> string option

(** Format a key code as a readable character. *)
val key_to_string : int -> string

(** Format compose mode status line. *)
val format_compose_status : Render.t -> Compose.t -> string

(** Help screen lines (precomputed). *)
val help_lines : string list

(** Width of the script-pane line-number gutter for a given buffer.
    Returns 0 when [Config.show_line_numbers] is false. *)
val gutter_width : Buffer.t -> int

(** Render the active tab (main entry point). *)
val render_all : Editor_context.t -> Render.t -> Tab.t -> unit
