(** Braille minimap rendering for the script pane. *)

(** Width of the minimap in terminal columns. *)
val width : int

(** Compute source lines per braille cell to fit within available rows. *)
val y_per_cell : num_lines:int -> available_rows:int -> int

type cell = {
  braille : string;
  color : int;
}

type row = cell array

(** Render the minimap for the full file.
    [ypc] is lines per cell, [cols] is braille columns to render. *)
val render :
  lines:string array ->
  num_lines:int ->
  verified_end:int ->
  pending_end:int ->
  error_range:(int * int) option ->
  ypc:int ->
  cols:int ->
  row array

(** Draw the minimap into a curses window.
    Draws the separator column at [sep_col] with rounded viewport brackets,
    and the braille cells starting at [col_offset] with reverse video
    for the viewport region. *)
val draw :
  Curses.window ->
  sep_col:int ->
  col_offset:int ->
  win_rows:int ->
  minimap_rows:int ->
  scroll:int ->
  visible_lines:int ->
  ypc:int ->
  border_attr:int ->
  row array ->
  unit
