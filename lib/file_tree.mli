(** File-tree panel widget. Persistent left-side navigator. Shares file
    enumeration with [File_picker] via [File_listing] but owns its own
    tree-walk, expansion state, selection, scroll, and filter state. *)

type t

(** Create a new file-tree state. The widget enumerates immediately;
    state persists across editor sessions in memory only (no on-disk
    persistence in v1). *)
val create : project_dir:string -> project_file:string -> t

(** The project file this tree was built against. Use to detect when
    the tree needs to be rebuilt for a different project. *)
val project_file : t -> string

(** Re-enumerate files from disk and rebuild visible lines. *)
val refresh : t -> unit

type action =
  | TreeContinue         (** key consumed by the panel, no further action *)
  | TreeOpen of string   (** absolute file path to open *)
  | TreeUnhandled        (** panel did not claim this key; let global handlers
                             (e.g. ^O, ^Q, ^P, F8) run *)

(** Handle a key press. [ch] is an ncurses-style int code; visible row
    count is derived internally from [Render.pane_dims]. *)
val handle_key : t -> Render.t -> int -> action

(** Handle a mouse click at absolute terminal coordinate [y]. *)
val handle_click : t -> Render.t -> y:int -> action

(** Handle a mouse scroll. Direction > 0 scrolls down, < 0 up. *)
val handle_scroll : t -> Render.t -> int -> unit

(** Render into the [PFileTree] pane. [open_files] is used for the
    open-file marker; [focused] highlights the header. *)
val render : t -> Render.t ->
  open_files:string list -> focused:bool -> unit
