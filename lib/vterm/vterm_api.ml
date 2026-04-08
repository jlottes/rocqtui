(* OCaml interface to the vterm terminal emulator library.
   Wraps the C stubs with type-safe OCaml functions. *)

type t  (* opaque, backed by C custom block *)

(* Color and attribute types matching Grid.color / Grid.attr layout
   exactly so the C stubs can construct them directly. *)
type color =
  | Default
  | Basic of int
  | Color256 of int
  | TrueColor of int * int * int

type attr = {
  fg : color;
  bg : color;
  bold : bool;
  dim : bool;
  reverse : bool;
  underline : bool;
}

type sync_result = {
  feedback : bytes option;
  title : string option;
  mouse_changed : bool;
  clipboard : string option;
}

type cursor_info = {
  x : int;
  y : int;
  w : int;
}

(* Row cell: text, width, attr, selected, cursor *)
type row_cell = {
  text : string;
  width : int;
  attr : attr;
  selected : bool;
  cursor : bool;
}

(* === Lifecycle === *)

external create : backlog:int -> fwdlog:int -> w:int -> h:int
  -> wrap_mode:int -> t
  = "caml_vterm_create"

external destroy : t -> unit = "caml_vterm_destroy"

(* === Data flow === *)

external proc : t -> bytes -> off:int -> len:int -> unit
  = "caml_vterm_proc"

external sync : t -> sync_result = "caml_vterm_sync"

(* === Resize === *)

external resize : t -> w:int -> h:int -> unit = "caml_vterm_resize"

(* === Display === *)

external prepare_rows : t -> int = "caml_vterm_prepare_rows"

external get_row_raw : t -> int
  -> (string * int * attr * bool * bool) array
  = "caml_vterm_get_row"

external get_row_sentinel : t -> int -> (attr * int) option
  = "caml_vterm_get_row_sentinel"

let get_row t y =
  let raw = get_row_raw t y in
  Array.map (fun (text, width, attr, selected, cursor) ->
    { text; width; attr; selected; cursor }
  ) raw

(* === Scroll === *)

external scroll : t -> int -> bool = "caml_vterm_scroll"
external scroll_to_end : t -> bool -> bool = "caml_vterm_scroll_to_end"

(* === Selection === *)

external hit_test : t -> row:int -> col:int -> int * int
  = "caml_vterm_hit_test"

external sel_start : t -> line:int -> col:int -> unit
  = "caml_vterm_sel_start"

external sel_extend : t -> line:int -> col:int -> unit
  = "caml_vterm_sel_extend"

external sel_word : t -> line:int -> col:int -> unit
  = "caml_vterm_sel_word"

external sel_text : t -> string option = "caml_vterm_sel_text"
external has_selection : t -> bool = "caml_vterm_has_selection"

(* === State queries === *)

external mouse_mode : t -> int = "caml_vterm_mouse_mode"
external mouse_flags : t -> int = "caml_vterm_mouse_flags"
external kitty_flags : t -> int = "caml_vterm_kitty_flags"
external term_mode : t -> int = "caml_vterm_term_mode"
external alt_screen : t -> bool = "caml_vterm_alt_screen"
external bracketed_paste : t -> bool = "caml_vterm_bracketed_paste"

external cursor : t -> (int * int * int) option = "caml_vterm_cursor"

let cursor_info t =
  match cursor t with
  | None -> None
  | Some (x, y, w) -> Some { x; y; w }

external width : t -> int = "caml_vterm_width"
external height : t -> int = "caml_vterm_height"

external set_wrap_mode : t -> int -> bool = "caml_vterm_set_wrap_mode"

(* === Key encoding === *)

external keyseq : keysym:int -> modifiers:int -> mode:int
  -> event_type:int -> string option
  = "caml_keyseq_lookup"

external kitty_keyseq : keysym:int -> base_keysym:int -> modifiers:int
  -> mode:int -> kitty_flags:int -> event_type:int
  -> text:string -> string option
  = "caml_kitty_keyseq_lookup_bc" "caml_kitty_keyseq_lookup_nat"

(* === Mouse encoding === *)

external mouseseq : button:int -> modifiers:int -> cx:int -> cy:int
  -> ev:int -> mode:int -> flags:int -> string
  = "caml_mouseseq_bc" "caml_mouseseq_nat"

(* === Constants === *)

(* Mouse modes *)
let mouse_mode_off  = 0
let mouse_mode_x10  = 1
let mouse_mode_norm = 2
let mouse_mode_btn  = 3
let mouse_mode_any  = 4

(* Mouse flags *)
let mouse_sgr        = 0x01
let mouse_focus      = 0x02
let mouse_alt_scroll = 0x04

(* Mouse events *)
let mouse_ev_press   = 0
let mouse_ev_release = 1
let mouse_ev_motion  = 2

(* Terminal modes *)
let mode_app_keypad  = 0x01
let mode_app_cursor  = 0x02
let mode_meta        = 0x04

(* Modifier bitmask (for key/mouse encoding) *)
let mod_shift = 1
let mod_alt   = 2
let mod_ctrl  = 4
