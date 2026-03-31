(** Editor context: dependencies injected from main.ml. *)

type t = {
  switch_tab : int -> unit;       (** switch to tab at screen x *)
  open_files : unit -> string list; (** get list of open file paths *)
  mutable status_extra : string;  (** extra status text (e.g. MCP spinner) *)
  mutable init_error : string;    (** error message if session init failed *)
  mutable theme_name : string;    (** current theme name *)
}

val create :
  switch_tab:(int -> unit) ->
  open_files:(unit -> string list) ->
  unit -> t
