(** File picker dialog — modal overlay showing project files in a tree. *)

type action =
  | PickerContinue
  | PickerClose
  | PickerOpen of string  (** file path to open *)

(** Whether the picker is currently open. *)
val is_open : unit -> bool

(** Open the picker dialog. *)
val open_picker :
  project_dir:string ->
  project_file:string ->
  open_files:string list ->
  unit

(** Close the picker dialog. *)
val close : unit -> unit

(** Handle a key press. Returns the action to take. *)
val handle_key : int -> int -> action

(** Handle a mouse click at (y, x) in screen coordinates.
    Needs box geometry for hit testing. *)
val handle_click :
  y:int -> x:int ->
  box_top:int -> box_left:int -> box_width:int ->
  visible_rows:int -> action

(** Handle mouse scroll (direction: positive=down, negative=up). *)
val handle_scroll : int -> int -> unit

(** Render the picker as an overlay into the grid. *)
val render : Render.t -> unit

(** Get box geometry: (top, left, width, height, visible_rows). *)
val box_geometry : Render.t -> int * int * int * int * int
