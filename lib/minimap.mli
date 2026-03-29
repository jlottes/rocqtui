(** Braille minimap rendering for the script pane. *)

(** Width of the minimap in terminal columns. *)
val width : int

(** Compute source lines per braille cell to fit within available rows. *)
val y_per_cell : num_lines:int -> available_rows:int -> int

type region_status = RDefault | RVerified | RProcessing | RError

type cell = {
  braille : string;
  color : int;
  status : region_status;
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

(** Draw the minimap into a Grid.t.
    [base_row]/[base_col] is the pane origin on the grid.
    Draws the separator column at [sep_col] with rounded viewport brackets,
    and the braille cells starting at [col_offset] with reverse video
    for the viewport region. *)
val draw :
  Grid.t ->
  base_row:int ->
  base_col:int ->
  sep_col:int ->
  col_offset:int ->
  win_rows:int ->
  minimap_rows:int ->
  scroll:int ->
  visible_lines:int ->
  ypc:int ->
  border_attr:Grid.attr ->
  row array ->
  unit
