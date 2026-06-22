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

(** Test if a keycode matches a binding. *)
val match_key : int -> binding -> bool

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
val step_to_start : binding
val step_to_end : binding
val toggle_hyps : binding
val toggle_gutter : binding
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
val search : binding
val search_next : binding
val search_prev : binding
val search_toggle_case : binding
val search_toggle_regex : binding
val search_field_toggle : binding
val search_replace_one : binding
val search_replace_all : binding
val search_toggle_project : binding
val next_error : binding
val prev_error : binding
val cut : binding
val paste : binding
val help : binding
val minimap : binding
val theme_menu : binding
val reload : binding
val build_menu : binding
val refresh_screen : binding
val toggle_file_tree : binding

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
val open_terminal : binding
val open_claude : binding
val split_vertical : binding
val split_horizontal : binding

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
