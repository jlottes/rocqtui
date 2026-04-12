(** Embedded terminal: vterm + PTY, managed as global message sub-tabs. *)

type t

val create : ?cmd:string -> ?args:string list -> ?env:(string * string) list
  -> ?cwd:string -> w:int -> h:int -> unit -> t
(** Spawn a terminal. Defaults to [$SHELL], [TERM=glterm].
    [cwd] sets the child's working directory (default: inherit).
    Adds to the global terminal list. *)

val destroy : t -> unit
(** Close PTY, free vterm, remove from global list. *)

val all : unit -> t list
(** All live terminals. *)

val fds : unit -> (Unix.file_descr * t) list
(** PTY fds for non-closed terminals (for use with select). *)

val poll : t -> bool
(** Read available PTY data, feed to vterm. Returns true if display changed. *)

val resize : t -> w:int -> h:int -> unit
(** Resize vterm and PTY. *)

val render : t -> Grid.t -> row:int -> col:int -> width:int -> height:int -> unit
(** Render terminal display into a grid region. *)

val title : t -> string
(** Display title (from OSC 2, with exit status if closed). *)

val is_closed : t -> bool

(** Terminal state access for input routing. *)

val vterm : t -> Vterm_lib.Vterm_api.t
val pty : t -> Vterm_lib.Pty.t
val reported_buttons : t -> int
val set_reported_buttons : t -> int -> unit

val set_clipboard_hook : (string -> unit) -> unit
(** Set callback invoked when a child sends OSC 52 clipboard data. *)
