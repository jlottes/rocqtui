(* Editor configuration values. Central place for tunables that are
   not keybindings (see keys.ml for those). *)

(* Number of spaces used for a single indentation level. Used by Tab /
   Shift+Tab in the script pane and by auto-indent on newline. *)
let indent_width = ref 2

(* Show line-number gutter in the script pane. Toggled with Alt+L. *)
let show_line_numbers = ref true
