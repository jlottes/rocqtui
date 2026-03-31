(** File picker dialog — modal overlay showing project files in a tree.
    State is held in Modal.FilePicker, not a global ref. *)

type t

type action =
  | PickerContinue
  | PickerClose
  | PickerOpen of string  (** file path to open *)

(** Create a file picker state. Push as Modal.FilePicker to activate. *)
val create :
  project_dir:string ->
  project_file:string ->
  open_files:string list ->
  t

(** Handle a key press. *)
val handle_key : t -> int -> int -> action

(** Handle a mouse click. *)
val handle_click : t ->
  y:int -> x:int ->
  box_top:int -> box_left:int -> box_width:int ->
  visible_rows:int -> action

(** Handle mouse scroll. *)
val handle_scroll : t -> int -> int -> unit

(** Render the picker as an overlay. *)
val render : t -> Render.t -> unit

(** Get box geometry: (top, left, width, height, visible_rows). *)
val box_geometry : unit -> int * int * int * int * int
