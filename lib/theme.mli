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

(** Initialize all curses color pairs from a theme. Call after Display.init. *)
val apply : t -> unit
