(** Screen ↔ buffer/pane coordinate conversion. *)

(** Convert a screen (x, y) to a script buffer (line, byte_col).
    Returns [None] when the coordinates are outside the script pane. *)
val screen_to_buffer_pos :
  Render.t -> Buffer.t -> x:int -> y:int -> (int * int) option

(** Convert a screen (x, y) to (line, byte_col) inside a right-side pane.
    Returns [None] when outside the pane or past the cached lines. *)
val screen_to_pane_pos :
  Tab.t -> Render.t ->
  x:int -> y:int -> [`Goals | `Messages] -> (int * int) option
