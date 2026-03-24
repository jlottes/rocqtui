(** Printing options management via the XML protocol. *)

type entry = {
  key : char;
  label : string;
  opt_names : string list list;
  mutable enabled : bool;
}

val entries : entry list

val toggle : entry -> unit

val to_set_options : unit -> (string list * Interface.option_value) list
