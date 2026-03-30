(** Render scheduling: No, Yes (diff), or Full (emit all cells). *)

type t = No | Yes | Full

(** Request a normal (diff) render. No-op if already Yes or Full. *)
val request : unit -> unit

(** Request a full render. Overrides any previous request. *)
val request_full : unit -> unit

(** Take and reset the current render need. *)
val take : unit -> t
