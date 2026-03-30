(** Centralized key binding registry. *)

type context =
  | Global | Script | GoalsMessages
  | QueryMenu | BuildMenu | ThemeMenu | OptionsMenu
  | HelpScreen | FilePicker

type binding = {
  name : string;
  codes : int list;
  kitty_codes : (int * int) list;
  display : string;
  context : context;
  description : string;
}

type kitty_key = {
  kk_keycode : int;
  kk_modifier : int;
}

(** Test if a keycode matches a binding. *)
val match_key : int -> binding -> bool

(** Test if a Kitty protocol key matches a binding. *)
val match_kitty_key : kitty_key -> binding -> bool

(** Global bindings *)
val quit : binding
val close_tab : binding
val save : binding
val jump_back : binding
val open_file : binding
val interrupt : binding
val step_forward : binding
val step_backward : binding
val go_to_cursor : binding
val toggle_hyps : binding
val options_menu : binding
val query_menu : binding
val cycle_pane : binding
val jump_to_def : binding
val about : binding
val print_query : binding
val copy : binding
val undo : binding
val redo : binding
val new_tab : binding
val prev_tab : binding
val next_tab : binding
val cut : binding
val paste : binding
val help : binding
val minimap : binding
val theme_menu : binding
val reload : binding
val build_menu : binding
val refresh_screen : binding

(** Query submenu *)
val query_about : binding
val query_check : binding
val query_print : binding
val query_coercions : binding
val query_locate : binding
val query_proof : binding
val query_existentials : binding

(** Build submenu *)
val build_file : binding
val build_deps : binding
val build_all : binding
val build_cursor : binding
val build_clean : binding
val build_cancel : binding

(** Binding groups for help/status generation *)
val navigation_bindings : binding list
val editing_bindings : binding list
val query_bindings : binding list
val display_bindings : binding list
val tab_bindings : binding list

(** Generate "^S:Save ^W:Close ..." hint string. *)
val hint_string : binding list -> string

(** Generate the full help screen text from bindings. *)
val generate_help : unit -> string

(** Kitty keyboard protocol *)
val enable_kitty : unit -> unit
val disable_kitty : unit -> unit
val is_kitty_enabled : unit -> bool
val kitty_enable_seq : string
val kitty_disable_seq : string
val parse_csi_u : string -> kitty_key option

(** A complete key event (may consume multiple getch calls). *)
type key_event =
  | RawKey of int
  | KittyKey of kitty_key
  | Paste of string
  | Escape

(** Match a key event against a binding. *)
val match_event : key_event -> binding -> bool

(** Extract raw keycode from event (for printable char checks etc). *)
val raw_key_of_event : key_event -> int option

(** Check if event is a mouse event. *)
val is_mouse_event : key_event -> bool

(** Check if event is a resize event. *)
val is_resize_event : key_event -> bool

(** Read one complete key event from the terminal.
    [peek timeout] reads with timeout (-1 on timeout).
    [block ()] blocks until available.
    [getch ()] non-blocking read (-1 if nothing). *)
val read_key_event :
  peek:(float -> int) ->
  block:(unit -> int) ->
  getch:(unit -> int) ->
  unit -> key_event option
