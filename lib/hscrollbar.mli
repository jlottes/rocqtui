(** Horizontal scrollbar for the script pane.

    Shown on the pane's bottom visible row when the view is
    horizontally scrolled or a line on the current screen runs off
    the right edge. Owns the column<->track geometry so rendering
    (thumb placement) and mouse handling (click / drag inversion)
    can't drift apart. State ([hscroll]) stays in {!Buffer}. *)

type t = {
  hscroll : int;  (** current horizontal scroll, in buffer columns *)
  cells : int;    (** track width in cells (= content columns) *)
  total : int;    (** total scrollable width, in buffer columns *)
}

(** Pure constructor; [total = max max_w (hscroll + content_cols)]. *)
val make : hscroll:int -> max_w:int -> content_cols:int -> t

(** Geometry from a buffer's current state. [rows] is the number of
    pane rows scanned for the widest visible line. *)
val of_buffer : Buffer.t -> rows:int -> content_cols:int -> t

(** Whether the scrollbar should be shown: the view is scrolled, or
    some visible line is wider than [content_cols]. Always false for
    panes shorter than 3 rows. *)
val wanted : Buffer.t -> rows:int -> content_cols:int -> bool

(** Thumb extent [(start, end)] in track eighth-cells
    ([0 .. cells * 8]). At least one cell wide. *)
val thumb : t -> int * int

(** hscroll that centers the thumb on track cell [track_x], clamped
    to the valid range. Inverse of {!thumb} for mouse click / drag. *)
val hscroll_of_click : t -> track_x:int -> int

(** hscroll after paging half a screen in direction [dir] (-1 / +1),
    clamped. *)
val page : t -> dir:int -> int

(** Draw the scrollbar row. [row]/[col] is the pane origin on the
    grid, [gw] the gutter width, [width] the full pane width (the
    bg tint covers it all; the track occupies [gw .. width-1]).
    Thumb edges render at 1/8-cell precision: left-fill eighth
    blocks directly on the right edge, and in reverse video on the
    left edge (ink becomes track bg, remainder thumb fg). End
    triangles appear only when more content lies that way. *)
val draw :
  Grid.t -> row:int -> col:int -> gw:int -> width:int ->
  track_attr:Grid.attr -> thumb_attr:Grid.attr -> t -> unit
