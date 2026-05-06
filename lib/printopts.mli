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

(** Render the current option states as a list of [Set Printing X.] /
    [Unset Printing X.] vernac sentences. Used to bake printing options
    into a transient document state before issuing a query (see
    {!Session.query}); the cached state at the query's [at:] determines
    its rendering, and SetOptions/inline-Set in a single phrase do not
    affect it.

    Bool overrides in [override] take precedence over the corresponding
    entry's stored value. Override entries whose option name is unknown
    are appended at the end. *)
val to_vernac_sentences :
  ?override:(string list * Interface.option_value) list ->
  unit -> string list

(** Same idea as {!to_set_options} but with per-call overrides applied. *)
val to_set_options_with :
  (string list * Interface.option_value) list ->
  (string list * Interface.option_value) list
