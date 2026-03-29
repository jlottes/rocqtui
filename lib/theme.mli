(** Color theme system with 256-color support. *)

type color = int  (** ncurses color number: 0-7 basic, 0-255 extended *)

type t = {
  name : string;

  (* Editor background: -1 for terminal default *)
  bg : color;

  (* Syntax highlighting foreground colors *)
  keyword_fg : color;
  tactic_fg : color;
  comment_fg : color;
  string_fg : color;
  bullet_fg : color;
  number_fg : color;
  default_fg : color;

  (* Verified region *)
  verified_bg : color;
  verified_fg : color;  (** default text in verified region *)

  (* Error region *)
  error_bg : color;
  error_fg : color;

  (* Processing region *)
  processing_bg : color;
  processing_fg : color;

  (* Status bar *)
  status_bg : color;
  status_fg : color;

  (* Borders *)
  border_fg : color;

  (* Selection *)
  selection_bg : color;
  selection_fg : color;
}

(** List of available theme names. *)
val available : string list

(** Get a theme by name. Returns the default theme if not found. *)
val find : string -> t

(** The default theme. *)
val default : t

(** Color pair for selection highlight. *)
val pair_selection : int

(** Grid.attr equivalents for the current theme. *)
type grid_attrs = {
  ga_keyword : Grid.attr;
  ga_tactic : Grid.attr;
  ga_comment : Grid.attr;
  ga_string : Grid.attr;
  ga_bullet : Grid.attr;
  ga_number : Grid.attr;
  ga_default : Grid.attr;
  ga_keyword_v : Grid.attr;
  ga_tactic_v : Grid.attr;
  ga_comment_v : Grid.attr;
  ga_string_v : Grid.attr;
  ga_bullet_v : Grid.attr;
  ga_number_v : Grid.attr;
  ga_default_v : Grid.attr;
  ga_keyword_p : Grid.attr;
  ga_tactic_p : Grid.attr;
  ga_comment_p : Grid.attr;
  ga_string_p : Grid.attr;
  ga_bullet_p : Grid.attr;
  ga_number_p : Grid.attr;
  ga_default_p : Grid.attr;
  ga_verified : Grid.attr;
  ga_processing : Grid.attr;
  ga_error : Grid.attr;
  ga_status : Grid.attr;
  ga_border : Grid.attr;
  ga_selection : Grid.attr;
  ga_tab_active : Grid.attr;
  ga_tab_inactive : Grid.attr;
}

(** Get the current theme's Grid.attr values. *)
val attrs : unit -> grid_attrs

(** Initialize all curses color pairs from a theme. Also updates Grid attrs. *)
val apply : t -> unit
